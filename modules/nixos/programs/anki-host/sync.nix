# modules/nixos/programs/anki-host/sync.nix
# 인스턴스별 AnkiWeb 동기화 — 주기 타이머(normal) + 첫 부트스트랩 전용 oneshot(allow-download-if-empty)
#
# 과거 anki-connect/sync.nix(61dadbe1^)와의 차이: AnkiConnect `sync` 액션(GUI 경로) 대신
# 헬퍼 애드온이 API를 직접 호출해 결과 코드를 돌려주고, 전후 스냅샷 차이로 "다른 기기의 학습이
# 내려왔는지"를 판정해 알림(b)을 보낸다. full sync 요구는 자동 결정하지 않는다 — 빈 컬렉션이면
# 부트스트랩 유닛을 운영자가 명시 실행할 때까지 조용히 대기하고, 비어 있지 않으면 알림(c)만 보낸다.
# sync의 운영 계층(상태 파일·알림·결과 분류)은 anki-host-sync 스크립트가 단일 소유한다 — PR 2의
# "지금 동기화"도 헬퍼를 직접 부르지 않고 이 서비스를 트리거한다 (plan 030 결정 13).
# 헬퍼 env·Pushover 시크릿·스크립트 결합은 backup.nix와 helper-script.nix를 공유한다.
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
  h = import ./helper-script.nix { inherit config pkgs constants; };
  inherit (h) ankiHost stateRoot;
  syncInstances = lib.filterAttrs (_: inst: inst.sync.enable) cfg.instances;
  pow2 = k: lib.foldl' (x: _: x * 2) 1 (lib.range 1 k);
  # 지수 백오프 합 — 스크립트는 attempt 1..maxRetries−1 뒤에 backoff×2^(attempt−1)만큼 대기한다: backoff × (2^(maxRetries−1) − 1)
  backoffTotalSecs = ankiHost.backoffSecs * (pow2 (ankiHost.maxRetries - 1) - 1);
  # 타임아웃 사다리 바깥 계층 — 스크립트 최악 실행 시간을 constants.ankiHost 값에서 그대로 계산한다 (eval AH8이 독립 재계산):
  #   준비 대기 tries×(probe+wait)
  # + busy 응답 busyRetries×busyWait — 409는 애드온이 락 대기 busyWait 뒤 즉시 돌려준다. busy 예산은 스크립트 전체에서
  #   busyRetries회이고 sync 재시도 회차와 무관하다 (anki-host-sync.sh의 busy_left)
  # + busy 사이 대기 (busyRetries−1)×busySecs
  # + sync 시도 maxRetries×curl + 백오프 합 + 여유
  unitTimeoutSecs =
    h.readyWorstSecs
    + ankiHost.busyRetries * ankiHost.helperBusyWaitSecs
    + (ankiHost.busyRetries - 1) * ankiHost.busyRetrySecs
    + ankiHost.maxRetries * ankiHost.helperCurlMaxTimeSecs
    + backoffTotalSecs
    + 60;

  syncScript = h.mkHelperScript "anki-host-sync" [ pkgs.util-linux ] ./files/anki-host-sync.sh; # util-linux: flock

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

    unitConfig.ConditionPathExists = h.pushoverCondition;

    # 공용 헬퍼 env(helper-script.nix) + 이 스크립트만 요구하는 값
    environment = h.helperEnv // {
      MAX_RETRIES = toString ankiHost.maxRetries;
      BACKOFF_SECS = toString ankiHost.backoffSecs;
      GUARD_MIN_RETAIN_PCT = toString ankiHost.syncGuardMinRetainPct;
      HELPER_PORT = toString inst.helperPort;
      STATE_DIR = "${stateRoot}/${name}";
      INSTANCE = name;
    };

    serviceConfig = {
      Type = "oneshot";
      User = user;
      Group = user;
      LoadCredential = h.pushoverLoadCredential;
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
    age.secrets.pushover-anki = h.pushoverSecret;

    systemd.services =
      lib.mapAttrs' mkSyncService syncInstances // lib.mapAttrs' mkBootstrapService syncInstances;
    systemd.timers = lib.mapAttrs' mkSyncTimer syncInstances;
  };
}
