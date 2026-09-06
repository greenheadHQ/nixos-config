# modules/nixos/programs/anki-host/default.nix
# headless Anki 인스턴스 (offscreen Qt) + loopback AnkiConnect + anki_host_sync 헬퍼 애드온
#
# === Change Intent Record ===
# v1 (PR #62 → 철거 PR #863, commit 61dadbe1): headless Anki + AnkiConnect를 Tailscale IP에
#   바인딩해 awesome-anki 컨테이너가 쓰게 했고, 자체 Anki Sync Server와 짝을 이뤘다.
#   2026-05-30 "AnkiWeb 동기화로 충분, 실제로 안 쓴다"는 근거로 세 서비스를 함께 철거했다.
# v2 (이번, #1306 / plan 030): 철거 결정 중 **AnkiConnect 부분만** 되돌린다.
#   - 근거: 여러 기기의 AI 클라이언트(ChatGPT Chat은 클라우드 전용)가 카드를 다루려면
#     Mac이 꺼져도 살아 있는 AnkiConnect 호스트가 필요하다. 동기화 자체는 공식 AnkiWeb으로
#     충분하다는 v1의 판단은 유지하므로 자체 sync server는 복원하지 않는다.
#   - 대안 1: Mac에 bridge만 두기 → Mac이 꺼지면 불가. 기각.
#   - 대안 2: 클라우드 VM → 학습 데이터 외부 반출·비용. 기각.
#   - 선택: MiniPC 인스턴스. AnkiConnect는 127.0.0.1 전용(API 키 없음 — Nix store에 bake하면
#     평문 노출되므로 같은 호스트의 서비스만 접근한다는 v1 판단을 계승), 프로필별 인스턴스
#     (격리 검증 `lab`, 운영 `main`), AnkiWeb 로그인·sync는 헬퍼 애드온이 API를 직접 호출한다
#     (AnkiConnect `sync` 액션은 GUI 다이얼로그 경로라 headless에서 멈춘다).
#   - trade-off: 인스턴스마다 anki 프로세스(메모리 상한 1G)와 프로필 사본이 생긴다.
#     overlay 없이 캐시된 nixpkgs 패키지만 쓴다 (과거 doInstallCheck overlay가 Hydra 캐시를
#     죽여 MiniPC가 매 배포마다 소스 빌드로 과열된 이력, PR #183).
{
  config,
  pkgs,
  lib,
  constants,
  ...
}:

let
  cfg = config.homeserver.ankiHost;
  user = cfg.user;
  stateRoot = constants.paths.ankiHostState;
  enabledInstances = lib.filterAttrs (_: inst: inst.enable) cfg.instances;
  ankiwebCredPath = config.age.secrets.anki-ankiweb.path;

  # AnkiWeb 로그인·sync·스냅샷·복구점 헬퍼 — 인스턴스 공용(설정은 env로 받는다)
  syncAddon = pkgs.anki-utils.buildAnkiAddon {
    pname = "anki_host_sync";
    version = "1.0.0";
    src = ./sync-addon;
  };

  # 인스턴스별 AnkiConnect 포트만 다르므로 anki 패키지 자체는 캐시된 그대로이고
  # symlinkJoin + 작은 애드온 derivation만 인스턴스 수만큼 생긴다.
  ankiFor =
    inst:
    pkgs.anki.withAddons [
      (pkgs.ankiAddons.anki-connect.withConfig {
        config = {
          apiKey = null;
          apiLogPath = null;
          webBindAddress = "127.0.0.1";
          webBindPort = inst.port;
          webCorsOriginList = [ "http://localhost" ];
          ignoreOriginList = [ ];
        };
      })
      syncAddon
    ];

  # 첫 실행의 언어 선택 다이얼로그는 offscreen에서 닫을 수 없어 영원히 멈춘다 (과거 실측).
  # prefs21.db에 _global(firstRun=False)과 프로필 항목을 미리 써서 우회한다.
  # autoSync=False: Anki 자체의 열고/닫을 때 sync(GUI 경로)를 끄고 헬퍼 애드온만 sync한다.
  prefsBootstrap =
    inst:
    pkgs.writeShellScript "anki-host-prefs-${inst.profile}" ''
      set -eu
      base="$1"
      mkdir -p "$base/${inst.profile}"
      if [ -f "$base/prefs21.db" ]; then
        exit 0
      fi
      ${pkgs.python3}/bin/python3 - "$base/prefs21.db" ${lib.escapeShellArg inst.profile} <<'PY'
      import pickle, random, sqlite3, sys, time
      db_path, profile = sys.argv[1], sys.argv[2]
      db = sqlite3.connect(db_path)
      db.execute("create table if not exists profiles (name text primary key collate nocase, data blob not null)")
      meta = {"ver": 0, "updates": False, "created": int(time.time()), "id": random.randrange(0, 2**63),
              "lastMsg": -1, "suppressUpdate": True, "firstRun": False, "defaultLang": "en_US"}
      prof = {"mainWindowGeom": None, "mainWindowState": None, "numBackups": 30, "lastOptimize": int(time.time()),
              "searchHistory": [], "syncKey": None, "syncUser": None, "syncMedia": True, "autoSync": False,
              "autoSyncMediaMinutes": 15, "allowHTML": False, "importMode": 1, "lastColour": "#00f",
              "stripHTML": True, "deleteMedia": False}
      db.execute("insert or replace into profiles values (?, ?)", ("_global", pickle.dumps(meta, protocol=4)))
      db.execute("insert or replace into profiles values (?, ?)", (profile, pickle.dumps(prof, protocol=4)))
      db.commit()
      db.close()
      PY
    '';

  mkInstance =
    name: inst:
    let
      stateDir = "${stateRoot}/${name}";
      baseDir = "${stateDir}/Anki2";
      runtimeDir = "/run/anki-host/${name}";
    in
    lib.nameValuePair "anki-host-${name}" {
      description = "Headless Anki instance '${name}' (AnkiConnect 127.0.0.1:${toString inst.port})";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        QT_QPA_PLATFORM = "offscreen";
        # QtWebEngine은 GPU 없는 headless에서 EGL 초기화 실패로 abort된다 (과거 실측)
        QTWEBENGINE_CHROMIUM_FLAGS = "--disable-gpu";
        HOME = stateDir;
        XDG_DATA_HOME = "${stateDir}/.local/share";
        XDG_CONFIG_HOME = "${stateDir}/.config";
        XDG_CACHE_HOME = "${stateDir}/.cache";
        XDG_RUNTIME_DIR = runtimeDir;
        # 같은 유저의 두 인스턴스가 서로에게 명령을 넘기고 종료하지 않도록 single-instance 키를 분리한다
        ANKI_SINGLE_INSTANCE_KEY = "anki-host-${name}";
        ANKI_HOST_HELPER_PORT = toString inst.helperPort;
        # 헬퍼의 /export·/import-colpkg는 이 아래 backups/(일일 백업 스테이징)·restore-points/(복구점)만 허용한다
        ANKI_HOST_STATE_DIR = stateDir;
      }
      // lib.optionalAttrs inst.sync.enable {
        ANKI_HOST_SYNC_CREDENTIALS = ankiwebCredPath;
      };

      serviceConfig = {
        Type = "simple";
        User = user;
        Group = user;
        StateDirectory = "anki-host/${name}";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "anki-host/${name}";
        RuntimeDirectoryMode = "0700";
        ExecStartPre = "${prefsBootstrap inst} ${baseDir}";
        ExecStart = "${ankiFor inst}/bin/anki -b ${baseDir} -p ${lib.escapeShellArg inst.profile}";
        Restart = "on-failure";
        RestartSec = 10;
        TimeoutStopSec = 60;
        MemoryMax = "1G";

        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        LockPersonality = true;
      };
    };
in
{
  imports = [
    ./sync.nix
    ./backup.nix
  ];

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          let
            ports = lib.concatMap (inst: [
              inst.port
              inst.helperPort
            ]) (builtins.attrValues enabledInstances);
          in
          lib.length ports == lib.length (lib.unique ports);
        message = "homeserver.ankiHost: AnkiConnect/helper ports must be unique across instances.";
      }
    ];

    users.users.${user} = {
      isSystemUser = true;
      group = user;
      home = stateRoot;
    };
    users.groups.${user} = { };

    # AnkiWeb 자격 (ANKIWEB_USERNAME=/ANKIWEB_PASSWORD=). 헬퍼 애드온이 anki 프로세스 안에서
    # 읽어 로그인 1회 후 syncKey만 프로필에 남긴다. 비밀번호는 저장소·로그·이슈에 쓰지 않는다.
    age.secrets.anki-ankiweb = {
      file = ../../../../secrets/anki-ankiweb.age;
      owner = user;
      group = user;
      mode = "0400";
    };

    systemd.tmpfiles.rules = [
      "d ${stateRoot} 0750 ${user} ${user} -"
    ]
    ++ lib.concatMap (name: [
      "d ${stateRoot}/${name} 0700 ${user} ${user} -"
      "d ${stateRoot}/${name}/backups 0700 ${user} ${user} -"
      "d ${stateRoot}/${name}/restore-points 0700 ${user} ${user} -"
    ]) (builtins.attrNames enabledInstances);

    systemd.services = lib.mapAttrs' mkInstance enabledInstances;
  };
}
