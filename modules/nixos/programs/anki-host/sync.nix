# modules/nixos/programs/anki-host/sync.nix
# 인스턴스별 AnkiWeb 동기화 — 주기 타이머(normal) + 첫 부트스트랩 전용 oneshot(allow-download-if-empty)
#
# 과거 anki-connect/sync.nix(61dadbe1^)와의 차이: AnkiConnect `sync` 액션(GUI 경로) 대신
# 헬퍼 애드온이 API를 직접 호출해 결과 코드를 돌려주고, 전후 스냅샷 차이로 "다른 기기의 학습이
# 내려왔는지"를 판정해 알림(b)을 보낸다. full sync 요구는 자동 결정하지 않는다 — 빈 컬렉션이면
# 부트스트랩 유닛을 운영자가 명시 실행할 때까지 조용히 대기하고, 비어 있지 않으면 알림(c)만 보낸다.
# sync의 운영 계층(상태 파일·알림·결과 분류)은 anki-host-sync 스크립트가 단일 소유한다 — PR 2의
# "지금 동기화"도 헬퍼를 직접 부르지 않고 이 서비스를 트리거한다 (plan 030 결정 13).
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
  pushoverCredPath = config.age.secrets.pushover-anki.path;
  syncInstances = lib.filterAttrs (_: inst: inst.sync.enable) cfg.instances;
  a = constants.ankiHost;
  # 타임아웃 사다리 바깥 계층 — 스크립트 최악 실행 시간을 constants.ankiHost 값에서 그대로 계산한다:
  # 준비 대기 tries×(probe+wait) + sync 재시도 maxRetries×curl + 백오프 합(5+10) + busy 재시도 (busyRetries−1)×busySecs + 여유
  unitTimeoutSecs =
    a.readyWaitTries * (a.readyProbeTimeoutSecs + a.readyWaitSecs)
    + a.maxRetries * a.helperCurlMaxTimeSecs
    + a.backoffSecs * 3
    + (a.busyRetries - 1) * a.busyRetrySecs
    + 60;
  # 스크립트가 받는 준비 대기·재시도 상수 — 위 계산과 같은 값 (스크립트는 env가 없으면 기본값 없이 실패한다)
  scriptEnv = {
    HELPER_CURL_MAX_TIME = toString a.helperCurlMaxTimeSecs;
    MAX_RETRIES = toString a.maxRetries;
    BACKOFF_SECS = toString a.backoffSecs;
    READY_WAIT_TRIES = toString a.readyWaitTries;
    READY_WAIT_SECS = toString a.readyWaitSecs;
    READY_PROBE_TIMEOUT = toString a.readyProbeTimeoutSecs;
    BUSY_RETRIES = toString a.busyRetries;
    BUSY_RETRY_SECS = toString a.busyRetrySecs;
  };

  # pushover 헬퍼 + 헬퍼 호출 공용 함수 + 본문을 텍스트로 결합한다 (source 경로 주입 대신 store에 고정)
  syncScript = pkgs.writeShellApplication {
    name = "anki-host-sync";
    runtimeInputs = with pkgs; [
      curl
      jq
      coreutils
      util-linux # flock
    ];
    text =
      builtins.readFile ../../../shared/scripts/lib/pushover.sh
      + "\n"
      + builtins.readFile ./files/lib/helper-call.sh
      + "\n"
      + builtins.readFile ./files/anki-host-sync.sh;
  };

  # 타이머 유닛과 부트스트랩 유닛이 공유하는 서비스 정의. extraArgs(리스트)만 다르다.
  mkSyncUnit = name: inst: extraArgs: description: {
    inherit description;
    after = [
      "anki-host-${name}.service"
      "network-online.target"
    ];
    wants = [
      "anki-host-${name}.service"
      "network-online.target"
    ];
    partOf = [ "anki-host-${name}.service" ];

    # LoadCredential은 원본 파일이 없으면 유닛이 EXIT_CREDENTIALS(243)로 실패한다. 시크릿 파일은
    # placeholder라도 배포와 함께 항상 존재하므로(secrets.nix 선언) 이 조건은 실질적으로 항상 참이고,
    # 파일 안의 값이 비어 있는 경우는 스크립트가 알림 없이 처리한다. backup.nix와 같은 정책.
    unitConfig.ConditionPathExists = pushoverCredPath;

    environment = scriptEnv // {
      HELPER_PORT = toString inst.helperPort;
      STATE_DIR = "${stateRoot}/${name}";
      INSTANCE = name;
    };

    serviceConfig = {
      Type = "oneshot";
      User = user;
      Group = user;
      # root 소유 0400 시크릿을 서비스 유저에게 파일 하나로만 넘긴다 (karakeep-notify 패턴)
      LoadCredential = [ "pushover:${pushoverCredPath}" ];
      ExecStart = lib.concatStringsSep " " (
        [ "${syncScript}/bin/anki-host-sync" ] ++ map lib.escapeShellArg extraArgs
      );
      TimeoutStartSec = "${toString unitTimeoutSecs}s";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ "${stateRoot}/${name}" ];
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
    };
  };

  mkSyncService =
    name: inst:
    lib.nameValuePair "anki-host-sync-${name}" (
      mkSyncUnit name inst [ ] "AnkiWeb periodic sync for headless Anki instance '${name}'"
    );

  # 첫 부트스트랩 — 로컬이 비어 있을 때만 AnkiWeb 컬렉션을 내려받는다. 타이머에 걸지 않으며
  # 운영자가 자격 투입 후 `systemctl start anki-host-sync-<name>-bootstrap`으로 1회 실행한다 (plan 030 Step 15).
  mkBootstrapService =
    name: inst:
    lib.nameValuePair "anki-host-sync-${name}-bootstrap" (
      mkSyncUnit name inst [
        "--mode"
        "allow-download-if-empty"
      ] "One-shot AnkiWeb bootstrap download for empty headless Anki instance '${name}' (manual)"
    );

  mkSyncTimer =
    name: inst:
    lib.nameValuePair "anki-host-sync-${name}" {
      description = "Periodic AnkiWeb sync trigger for '${name}'";
      wantedBy = [ "timers.target" ];
      # monotonic 타이머라 Persistent는 의미가 없다 — 부팅 후 첫 실행은 OnBootSec이 담당한다
      timerConfig = {
        Unit = "anki-host-sync-${name}.service";
        OnBootSec = "3min";
        OnUnitActiveSec = inst.sync.interval;
        RandomizedDelaySec = "1min";
      };
    };
in
{
  config = lib.mkIf (cfg.enable && syncInstances != { }) {
    # Anki 전용 Pushover 앱 토큰 (PUSHOVER_TOKEN=/PUSHOVER_USER=). backup.nix와 동일 선언 — 모듈 시스템이 merge
    age.secrets.pushover-anki = {
      file = ../../../../secrets/pushover-anki.age;
      owner = "root";
      mode = "0400";
    };

    systemd.services =
      lib.mapAttrs' mkSyncService syncInstances // lib.mapAttrs' mkBootstrapService syncInstances;
    systemd.timers = lib.mapAttrs' mkSyncTimer syncInstances;
  };
}
