# modules/nixos/programs/anki-host/backup.nix
# 인스턴스별 .colpkg 일일 백업 (헬퍼 /export → SSD backups/ → HDD). 복구점(restore-points/)의 미러·보존은
# 생산자(MCP 도구)와 함께 PR 2b에서 도입한다 (plan 030 결정 11) — 이 모듈은 backups/만 다룬다.
# 관례: oneshot + daily timer, ProtectSystem=strict + ReadWrite/ReadOnly 분리, 04:30/05:00/05:30과 겹치지 않는
# 시각 — 타이머 배치의 정본은 `.claude/skills/running-containers/SKILL.md`의 "백업 타이머" 표이고 이 모듈도 거기 등록돼 있다.
{
  config,
  pkgs,
  lib,
  constants,
  ...
}:

let
  cfg = config.homeserver.ankiHost;
  stateRoot = constants.paths.ankiHostState;
  inherit (constants.paths) mediaData;
  backupDir = "${mediaData}/backups/anki-host";
  pushoverCredPath = config.age.secrets.pushover-anki.path;
  backupInstances = lib.filterAttrs (_: inst: inst.backup.enable) cfg.instances;
  instanceList = lib.concatStringsSep " " (
    lib.mapAttrsToList (name: inst: "${name}:${toString inst.helperPort}") backupInstances
  );
  a = constants.ankiHost;
  # 타임아웃 사다리 바깥 계층 — 인스턴스마다: 준비 대기 tries×(probe+wait) + export busy 재시도 busyRetries×curl
  # + (busyRetries−1)×busySecs + 복사·검사 여유 5min. constants.ankiHost 값에서 그대로 계산한다.
  perInstanceSecs =
    a.readyWaitTries * (a.readyProbeTimeoutSecs + a.readyWaitSecs)
    + a.busyRetries * a.helperCurlMaxTimeSecs
    + (a.busyRetries - 1) * a.busyRetrySecs
    + 300;
  unitTimeoutSecs = (builtins.length (builtins.attrNames backupInstances)) * perInstanceSecs + 60;

  backupScript = pkgs.writeShellApplication {
    name = "anki-host-backup";
    runtimeInputs = with pkgs; [
      curl
      jq
      coreutils
      findutils
      gawk
      python3
    ];
    text =
      builtins.readFile ../../../shared/scripts/lib/pushover.sh
      + "\n"
      + builtins.readFile ./files/lib/helper-call.sh
      + "\n"
      + builtins.readFile ./files/anki-host-backup.sh;
  };
in
{
  config = lib.mkIf (cfg.enable && backupInstances != { }) {
    age.secrets.pushover-anki = {
      file = ../../../../secrets/pushover-anki.age;
      owner = "root";
      mode = "0400";
    };

    systemd.services.anki-host-backup = {
      description = "Daily .colpkg backup of headless Anki instances (SSD -> HDD)";
      after = lib.mapAttrsToList (name: _: "anki-host-${name}.service") backupInstances;

      # sync.nix와 같은 정책 — LoadCredential 원본 부재 시 EXIT_CREDENTIALS 실패를 조건으로 막는다
      unitConfig.ConditionPathExists = pushoverCredPath;

      environment = {
        INSTANCES = instanceList;
        STATE_ROOT = stateRoot;
        BACKUP_DIR = backupDir;
        RETENTION_DAYS = toString cfg.retentionDays;
        # SSD에는 직전 백업 1개 + 오늘 백업 1개만 남긴다 (컬렉션+미디어 ≈ 200MB/개). 장기 보존은 HDD 몫.
        LOCAL_KEEP = "2";
        HELPER_CURL_MAX_TIME = toString a.helperCurlMaxTimeSecs;
        READY_WAIT_TRIES = toString a.readyWaitTries;
        READY_WAIT_SECS = toString a.readyWaitSecs;
        READY_PROBE_TIMEOUT = toString a.readyProbeTimeoutSecs;
        BUSY_RETRIES = toString a.busyRetries;
        BUSY_RETRY_SECS = toString a.busyRetrySecs;
      };

      serviceConfig = {
        Type = "oneshot";
        LoadCredential = [ "pushover:${pushoverCredPath}" ];
        ExecStart = "${backupScript}/bin/anki-host-backup";
        TimeoutStartSec = "${toString unitTimeoutSecs}s";
        ProtectSystem = "strict";
        ReadWritePaths = [
          backupDir
          stateRoot
        ];
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    };

    systemd.timers.anki-host-backup = {
      description = "Daily headless Anki .colpkg backup";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.backupTime;
        Persistent = true;
        RandomizedDelaySec = "5m";
      };
    };

    systemd.tmpfiles.rules = [ "d ${backupDir} 0700 root root -" ];
  };
}
