# modules/nixos/programs/anki-connect/default.nix
# Headless Anki + AnkiConnect API 서버
# QT_QPA_PLATFORM=offscreen으로 GUI 없이 실행
#
# 인증: Tailscale 네트워크 레벨 격리에 의존 (API key 불필요)
# withAddons + withConfig → 설정이 Nix store에 bake됨 (immutable)
{
  config,
  pkgs,
  lib,
  constants,
  ...
}:

let
  cfg = config.homeserver.ankiConnect;
  syncCfg = cfg.sync;
  inherit (constants.network) minipcTailscaleIP;

  syncUrl =
    if syncCfg.url != null then
      syncCfg.url
    else
      "http://${minipcTailscaleIP}:${toString config.homeserver.ankiSync.port}/";
  normalizedSyncUrl = if lib.strings.hasSuffix "/" syncUrl then syncUrl else "${syncUrl}/";

  localSyncServerEnabled = config.homeserver.ankiSync.enable && syncCfg.url == null;

  syncConfigAddon =
    if !syncCfg.enable then
      null
    else
      pkgs.anki-utils.buildAnkiAddon {
        pname = "nixos-sync-config";
        version = "1.0";
        src = pkgs.writeTextDir "__init__.py" ''
          import aqt
          from pathlib import Path
          import traceback

          custom_sync_url = ${builtins.toJSON normalizedSyncUrl}
          sync_username = ${builtins.toJSON syncCfg.username}
          sync_password_file = Path(${builtins.toJSON config.age.secrets.anki-connect-sync-password.path})

          def set_server() -> None:
              pm = aqt.mw.pm

              if custom_sync_url:
                  pm.set_custom_sync_url(custom_sync_url)
              if sync_username:
                  pm.set_sync_username(sync_username)

              # 이미 sync key가 있으면 재로그인하지 않음.
              if pm.profile.get("syncKey"):
                  return

              if not sync_username:
                  print("[anki-connect-sync] sync username is empty")
                  return

              if not sync_password_file.exists():
                  print(f"[anki-connect-sync] sync password file not found: {sync_password_file}")
                  return

              password = sync_password_file.read_text().strip()
              if not password:
                  print("[anki-connect-sync] sync password file is empty")
                  return

              try:
                  auth = aqt.mw.col.sync_login(
                      username=sync_username,
                      password=password,
                      endpoint=pm.sync_endpoint(),
                  )
                  pm.set_sync_key(auth.hkey)
                  pm.set_sync_username(sync_username)
                  pm.set_current_sync_url(None)
                  pm.save()
                  print("[anki-connect-sync] sync auth initialized")
              except Exception as err:
                  print(f"[anki-connect-sync] sync login failed: {err}")
                  traceback.print_exc()

          aqt.gui_hooks.profile_did_open.append(set_server)
        '';
      };

  ankiWithConnect = pkgs.anki.withAddons (
    [
      (pkgs.ankiAddons.anki-connect.withConfig {
        config = {
          webBindAddress = minipcTailscaleIP;
          webBindPort = cfg.port;
          webCorsOriginList = [
            "http://localhost"
            "http://localhost:3000"
            "http://localhost:5173"
            "http://${minipcTailscaleIP}"
          ];
        };
      })
    ]
    ++ lib.optionals (syncConfigAddon != null) [ syncConfigAddon ]
  );
in
{
  imports = [ ./sync.nix ];

  config = lib.mkIf cfg.enable {
    # 시스템 사용자
    users.users.anki = {
      isSystemUser = true;
      group = "anki";
      home = "/var/lib/anki";
    };
    users.groups.anki = { };

    assertions = [
      {
        assertion = !syncCfg.enable || syncCfg.username != "";
        message = "homeserver.ankiConnect.sync.username must not be empty.";
      }
      {
        assertion = !syncCfg.enable || config.homeserver.ankiSync.enable || syncCfg.url != null;
        message = "Enable homeserver.ankiSync or set homeserver.ankiConnect.sync.url when sync is enabled.";
      }
    ];

    # systemd 서비스
    systemd.services.anki-connect = {
      description = "Headless Anki with AnkiConnect API";
      after = [
        "tailscaled.service"
        "network.target"
      ]
      ++ lib.optionals localSyncServerEnabled [ "anki-sync-server.service" ];
      wants = [
        "tailscaled.service"
      ]
      ++ lib.optionals localSyncServerEnabled [ "anki-sync-server.service" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        QT_QPA_PLATFORM = "offscreen";
        # QtWebEngine은 GPU 없는 headless 환경에서 EGL 초기화 실패로 abort됨
        QTWEBENGINE_CHROMIUM_FLAGS = "--disable-gpu";
        HOME = "/var/lib/anki";
        XDG_DATA_HOME = "/var/lib/anki/.local/share";
        XDG_CONFIG_HOME = "/var/lib/anki/.config";
      };

      serviceConfig = {
        Type = "simple";
        User = "anki";
        Group = "anki";
        StateDirectory = "anki";

        # Tailscale IP 할당 대기 → 프로필 디렉터리 보장 → Anki 실행
        ExecStartPre = [
          ("+" + (import ../../lib/tailscale-wait.nix { inherit pkgs; }))
          (
            "+"
            + pkgs.writeShellScript "anki-ensure-profile" ''
                            ANKI2_DIR="/var/lib/anki/.local/share/Anki2"
                            PROFILE_DIR="$ANKI2_DIR/${cfg.profile}"
                            PREFS_DB="$ANKI2_DIR/prefs21.db"
                            BOOTSTRAP_MARKER="$PROFILE_DIR/.bootstrap-from-sync-server.done"
                            SYNC_SERVER_DIR="/var/lib/anki-sync-server/${syncCfg.username}"
                            SYNC_SERVER_COLLECTION="$SYNC_SERVER_DIR/collection.anki2"
                            LOCAL_COLLECTION="$PROFILE_DIR/collection.anki2"

                            # 프로필 디렉터리 보장
                            if [ ! -d "$PROFILE_DIR" ]; then
                              ${pkgs.coreutils}/bin/mkdir -p "$PROFILE_DIR"
                            fi

                            # prefs21.db 초기화 (첫 부팅 시)
                            # Anki 첫 실행 시 언어 선택 다이얼로그가 offscreen 모드에서 blocking되므로
                            # _global + profile 엔트리를 미리 생성하여 firstTime=False로 우회
                            if [ ! -f "$PREFS_DB" ]; then
                              ${pkgs.python3}/bin/python3 -c "
              import sqlite3, pickle, random, time
              db = sqlite3.connect('$PREFS_DB')
              db.execute('CREATE TABLE IF NOT EXISTS profiles (name TEXT PRIMARY KEY COLLATE NOCASE, data BLOB NOT NULL)')
              meta = {'ver': 0, 'updates': True, 'created': int(time.time()), 'id': random.randrange(0, 2**63), 'lastMsg': 0, 'suppressUpdate': False, 'firstRun': False, 'defaultLang': 'en_US'}
              db.execute('INSERT OR REPLACE INTO profiles VALUES (?, ?)', ('_global', pickle.dumps(meta)))
              profile = {'mainWindowGeom': None, 'mainWindowState': None, 'numBackups': 50, 'lastOptimize': int(time.time()), 'searchHistory': [], 'syncKey': None, 'syncMedia': True, 'autoSync': True, 'allowHTML': False, 'importMode': 1, 'lastColour': '#00f', 'stripHTML': True, 'deleteMedia': False}
              db.execute('INSERT OR REPLACE INTO profiles VALUES (?, ?)', ('${cfg.profile}', pickle.dumps(profile)))
                              db.commit()
                              db.close()
                              "
                            fi

                            # 기존 수동 cp 워크어라운드를 대체하기 위한 1회 부트스트랩.
                            # 로컬 컬렉션이 사실상 비어있으면 Sync Server 데이터를 먼저 복사한다.
                            if [ "${lib.boolToString syncCfg.enable}" = "true" ] && \
                               [ "${lib.boolToString syncCfg.bootstrapFromSyncServer}" = "true" ] && \
                               [ ! -f "$BOOTSTRAP_MARKER" ] && \
                               [ -f "$SYNC_SERVER_COLLECTION" ]; then
                              src_size="$(${pkgs.coreutils}/bin/stat -c%s "$SYNC_SERVER_COLLECTION" 2>/dev/null || echo 0)"
                              dst_size="$(${pkgs.coreutils}/bin/stat -c%s "$LOCAL_COLLECTION" 2>/dev/null || echo 0)"
                              min_collection_bytes="${toString syncCfg.bootstrapMinCollectionBytes}"

                              if [ "$src_size" -gt 0 ] && [ "$dst_size" -lt "$min_collection_bytes" ]; then
                                echo "anki-connect bootstrap: copy collection from sync server"
                                if ${pkgs.coreutils}/bin/cp "$SYNC_SERVER_COLLECTION" "$LOCAL_COLLECTION"; then
                                  if [ "${lib.boolToString syncCfg.bootstrapMedia}" = "true" ] && [ -d "$SYNC_SERVER_DIR/media" ]; then
                                    ${pkgs.coreutils}/bin/mkdir -p "$PROFILE_DIR/collection.media"
                                    ${pkgs.rsync}/bin/rsync -a --delete "$SYNC_SERVER_DIR/media/" "$PROFILE_DIR/collection.media/"
                                  fi
                                  ${pkgs.coreutils}/bin/touch "$BOOTSTRAP_MARKER"
                                else
                                  echo "anki-connect bootstrap: failed to copy collection from sync server" >&2
                                fi
                              elif [ "$dst_size" -ge "$min_collection_bytes" ]; then
                                echo "anki-connect bootstrap: local collection already initialized, skipping"
                                ${pkgs.coreutils}/bin/touch "$BOOTSTRAP_MARKER"
                              fi
                            fi

                            ${pkgs.coreutils}/bin/chown -R anki:anki "$ANKI2_DIR"
            ''
          )
        ];
        ExecStart = "${ankiWithConnect}/bin/anki -p ${cfg.profile}";
        ExecStartPost = lib.optionals (syncCfg.enable && syncCfg.onStart) [
          "+${pkgs.systemd}/bin/systemctl --no-block start anki-connect-sync.service"
        ];

        Restart = "on-failure";
        RestartSec = 10;
        MemoryMax = "512M";

        # 보안 강화
        NoNewPrivileges = true;
        ProtectHome = true;
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
      };
    };
  };
}
