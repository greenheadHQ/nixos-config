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
#   - v1과 값이 다른 항목과 이유: MemoryMax 512M→1G (v1 운영에서 OOMKill 실측 이력이 troubleshooting에
#     남아 있고, 이번엔 실제 이력 컬렉션의 .colpkg export가 205MB peak를 쓴 실측 + 인스턴스 2개 동시 기동);
#     numBackups 50→30 (Anki 자체 자동 백업은 프로필 아래 쌓이는 SSD 비용이고, 일일 HDD 백업이 따로 있다);
#     autoSync True→False (Anki의 열고/닫을 때 GUI sync 경로를 끄고 헬퍼 애드온만 sync한다).
#     — numBackups·autoSync는 프로필 **최초 생성 시** prefs21.db에 쓰는 값이다(prefsBootstrap 가드 참조);
#     tailscale-wait 미복원 (v1은 tailnet IP 바인딩 때문에 필요했고 loopback 전용인 지금은 근거가 없다).
{
  config,
  pkgs,
  lib,
  constants,
  ...
}:

let
  cfg = config.homeserver.ankiHost;
  inherit (constants.ankiHost) user;
  stateRoot = constants.paths.ankiHostState;
  # 애드온 버전의 단일 소스 — nix 파생 version과 /status의 addon_version이 같은 값을 갖는다
  addonVersion = "1.4.1";
  inherit (constants.ankiHost)
    helperMainTimeoutSecs
    helperBusyWaitSecs
    helperQueryTimeoutSecs
    ;
  instances = cfg.instances;
  ankiwebCredPath = config.age.secrets.anki-ankiweb.path;

  # AnkiWeb 로그인·sync·스냅샷·복구점 헬퍼 — 인스턴스 공용(설정은 env로 받는다)
  syncAddon = pkgs.anki-utils.buildAnkiAddon {
    pname = "anki_host_sync";
    version = addonVersion;
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
  # 프로필 이름은 인스턴스 이름과 같다 (상태 디렉터리·유닛·single-instance 키도 모두 인스턴스 이름 기준)
  prefsBootstrap =
    name:
    pkgs.writeShellScript "anki-host-prefs-${name}" ''
      set -eu
      base="$1"
      mkdir -p "$base/${name}"
      # 아래 prefs 값(numBackups·autoSync 등)은 프로필 최초 생성 시에만 적용된다 — 기존 인스턴스에 반영하려면
      # prefs21.db를 지우거나(프로필 재생성) Anki 쪽에서 바꿔야 한다. 파일을 바꾸고 nrs만 해서는 아무 효과가 없다.
      if [ -f "$base/prefs21.db" ]; then
        exit 0
      fi
      ${pkgs.python3}/bin/python3 - "$base/prefs21.db" ${lib.escapeShellArg name} <<'PY'
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
        ANKI_HOST_ADDON_VERSION = addonVersion;
        # 타임아웃 사다리의 안쪽 값들 (constants.ankiHost) — 스크립트 curl·유닛 값은 이보다 크다
        ANKI_HOST_MAIN_TIMEOUT_SECS = toString helperMainTimeoutSecs;
        ANKI_HOST_BUSY_WAIT_SECS = toString helperBusyWaitSecs;
        ANKI_HOST_QUERY_TIMEOUT_SECS = toString helperQueryTimeoutSecs;
        # 헬퍼의 /export·/import-colpkg는 이 아래 backups/(일일 백업 스테이징)·restore-points/(복구점)만 허용한다
        ANKI_HOST_STATE_DIR = stateDir;
      }
      // lib.optionalAttrs inst.sync.enable {
        ANKI_HOST_SYNC_CREDENTIALS = ankiwebCredPath;
      }
      // lib.optionalAttrs inst.allowImport {
        # 컬렉션 교체(/import-colpkg) 라우팅 — 구성 시점 결정. sync.enable과의 배타는 아래 assertion
        ANKI_HOST_ALLOW_IMPORT = "1";
      };

      serviceConfig = {
        Type = "simple";
        User = user;
        Group = user;
        StateDirectory = "anki-host/${name}";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "anki-host/${name}";
        RuntimeDirectoryMode = "0700";
        ExecStartPre = "${prefsBootstrap name} ${baseDir}";
        ExecStart = "${ankiFor inst}/bin/anki -b ${baseDir} -p ${lib.escapeShellArg name}";
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
            ]) (builtins.attrValues instances);
          in
          lib.length ports == lib.length (lib.unique ports);
        message = "homeserver.ankiHost: AnkiConnect/helper ports must be unique across instances.";
      }
      {
        # AnkiWeb 자격은 단일 시크릿(anki-ankiweb)뿐이다. 두 인스턴스가 같은 계정에 붙으면 서로 다른
        # 컬렉션이 15분마다 양방향 병합을 시도해 실제 학습 데이터가 오염된다.
        assertion =
          lib.length (lib.filter (inst: inst.sync.enable) (builtins.attrValues cfg.instances)) <= 1;
        message = "homeserver.ankiHost: at most one instance may enable sync — there is a single AnkiWeb credential.";
      }
      {
        # 컬렉션 교체 엔드포인트는 AnkiWeb에 붙는 인스턴스에 열지 않는다 — 운영 컬렉션이 loopback 무인증 호출로
        # 통째로 교체되는 경로를 구성 시점에 차단한다 (loopback은 --network=host 컨테이너와 공유된다)
        assertion = lib.all (inst: !(inst.allowImport && inst.sync.enable)) (builtins.attrValues instances);
        message = "homeserver.ankiHost: allowImport and sync.enable are mutually exclusive — import is for isolated fixture instances only.";
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
    ]) (builtins.attrNames instances);

    systemd.services = lib.mapAttrs' mkInstance instances;
  };
}
