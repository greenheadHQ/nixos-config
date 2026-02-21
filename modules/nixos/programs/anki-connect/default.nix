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
  inherit (constants.network) minipcTailscaleIP;

  ankiWithConnect = pkgs.anki.withAddons [
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
  ];
in
{
  config = lib.mkIf cfg.enable {
    # 시스템 사용자
    users.users.anki = {
      isSystemUser = true;
      group = "anki";
      home = "/var/lib/anki";
    };
    users.groups.anki = { };

    # systemd 서비스
    systemd.services.anki-connect = {
      description = "Headless Anki with AnkiConnect API";
      after = [
        "tailscaled.service"
        "network.target"
      ];
      wants = [ "tailscaled.service" ];
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

                            # 프로필 디렉터리 보장
                            if [ ! -d "$PROFILE_DIR" ]; then
                              mkdir -p "$PROFILE_DIR"
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

                            chown -R anki:anki "$ANKI2_DIR"
            ''
          )
        ];
        ExecStart = "${ankiWithConnect}/bin/anki -p ${cfg.profile}";

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
