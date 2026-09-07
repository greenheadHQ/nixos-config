# modules/nixos/programs/anki-host/backup.nix
# 인스턴스별 .colpkg 일일 백업 (헬퍼 /export → SSD backups/ → HDD). 복구점(restore-points/)의 미러·보존은
# 생산자(MCP 도구)와 함께 PR 2b에서 도입한다 (plan 030 결정 11) — 이 모듈은 backups/만 다룬다.
# 관례: oneshot + daily timer, ProtectSystem=strict, 04:30/05:00/05:30과 겹치지 않는 시각 — 타이머 배치의 정본은
# `.claude/skills/running-containers/SKILL.md`의 "백업 타이머" 표이고 이 모듈도 거기 등록돼 있다.
# 쓰기 경로는 HDD 백업 디렉터리와 각 인스턴스의 backups/(SSD 정리)뿐이다 — 원본은 파일이 아니라 헬퍼 /export라
# 읽기 전용 소스 경로가 없고, 살아 있는 프로필·restore-points/는 이 유닛(root)에 열지 않는다.
# 백업 신선도는 smoke-test.nix가 인스턴스별 최신 .colpkg mtime으로 검사한다.
# 헬퍼 env·Pushover 시크릿·스크립트 결합은 sync.nix와 helper-script.nix를 공유한다.
{
  config,
  pkgs,
  lib,
  constants,
  ...
}:

let
  cfg = config.homeserver.ankiHost;
  h = import ./helper-script.nix { inherit config pkgs constants; };
  inherit (h) ankiHost stateRoot;
  inherit (constants.paths) mediaData;
  backupDir = "${mediaData}/backups/anki-host";
  backupInstances = lib.filterAttrs (_: inst: inst.backup.enable) cfg.instances;
  instanceList = lib.concatStringsSep " " (
    lib.mapAttrsToList (name: inst: "${name}:${toString inst.helperPort}") backupInstances
  );
  # 타임아웃 사다리 바깥 계층 — 인스턴스마다: 준비 대기 tries×(probe+wait) + export busy 재시도 (busyRetries−1)×(busyWait+busySecs)
  # (409는 락 대기 busyWait 뒤 즉시 온다) + export 1회 curl + 복사·검사 여유 5min. constants.ankiHost 값에서 그대로 계산한다 (eval AH8).
  perInstanceSecs =
    h.readyWorstSecs
    + (ankiHost.busyRetries - 1) * (ankiHost.helperBusyWaitSecs + ankiHost.busyRetrySecs)
    + ankiHost.helperCurlMaxTimeSecs
    + 300;
  unitTimeoutSecs = (builtins.length (builtins.attrNames backupInstances)) * perInstanceSecs + 60;

  backupScript = h.mkHelperScript "anki-host-backup" (with pkgs; [
    findutils
    gawk
    python3
  ]) ./files/anki-host-backup.sh;
in
{
  config = lib.mkIf (cfg.enable && backupInstances != { }) {
    age.secrets.pushover-anki = h.pushoverSecret;

    systemd.services.anki-host-backup = {
      description = "Daily .colpkg backup of headless Anki instances (SSD -> HDD)";
      after = lib.mapAttrsToList (name: _: "anki-host-${name}.service") backupInstances;

      unitConfig.ConditionPathExists = h.pushoverCondition;

      # 공용 헬퍼 env(helper-script.nix) + 이 스크립트만 요구하는 값
      environment = h.helperEnv // {
        INSTANCES = instanceList;
        STATE_ROOT = stateRoot;
        BACKUP_DIR = backupDir;
        RETENTION_DAYS = toString cfg.retentionDays;
        # SSD에는 직전 백업 1개 + 오늘 백업 1개만 남긴다 (컬렉션+미디어 ≈ 200MB/개). 장기 보존은 HDD 몫.
        LOCAL_KEEP = "2";
      };

      serviceConfig = {
        Type = "oneshot";
        LoadCredential = h.pushoverLoadCredential;
        ExecStart = "${backupScript}/bin/anki-host-backup";
        TimeoutStartSec = "${toString unitTimeoutSecs}s";
        ProtectSystem = "strict";
        ReadWritePaths = [
          backupDir
        ]
        ++ map (name: "${stateRoot}/${name}/backups") (builtins.attrNames backupInstances);
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
