# modules/nixos/programs/docker/immich-originals-mirror.nix
# Immich 원본 사진/영상 일일 미러 (SSD upload-cache → HDD)
# rsync --archive --delete 미러: 원본은 무변경(읽기 전용), 목적지가 소스에 수렴한다.
# "무백업 SSD 단독 존재" 해소 — 원본이 disko 포맷 대상 SSD에만 존재하던 백업 자세 결함 시정.
# service-lib.sh로 Pushover 알림(실패 시만). oneshot systemd service + daily timer.
{
  config,
  pkgs,
  lib,
  constants,
  ...
}:

let
  cfg = config.homeserver.immichOriginalsMirror;
  immichCfg = config.homeserver.immich;
  inherit (constants.paths) immichUploadCache mediaData;

  srcDir = immichUploadCache;
  destDir = "${mediaData}/backups/immich-originals";
  pushoverCredPath = config.age.secrets.pushover-immich.path;
  serviceLib = import ../../lib/service-lib.nix { inherit pkgs; };

  mirrorScript = pkgs.writeShellApplication {
    name = "immich-originals-mirror";
    runtimeInputs = with pkgs; [
      rsync
      coreutils
      curl # service-lib.sh의 send_notification에서 사용
    ];
    text = builtins.readFile ./immich-originals-mirror/files/immich-originals-mirror.sh;
  };
in
{
  config = lib.mkIf (cfg.enable && immichCfg.enable) {
    # Pushover 시크릿 (immich.nix와 동일 선언 — 모듈 시스템이 merge)
    age.secrets.pushover-immich = {
      file = ../../../../secrets/pushover-immich.age;
      owner = "root";
      mode = "0400";
    };

    # 미러 서비스 (oneshot)
    systemd.services.immich-originals-mirror = {
      description = "Immich originals mirror (rsync SSD upload-cache → HDD)";

      unitConfig = {
        ConditionPathExists = pushoverCredPath;
      };

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${mirrorScript}/bin/immich-originals-mirror";
        TimeoutSec = "3h"; # 초회 105G 전체 복사 대비
        ProtectSystem = "strict";
        ReadWritePaths = [ destDir ];
        ReadOnlyPaths = [ srcDir ];
        PrivateTmp = true;
        NoNewPrivileges = true;
      };

      environment = {
        PUSHOVER_CRED_FILE = pushoverCredPath;
        SERVICE_LIB = "${serviceLib}";
        SRC_DIR = srcDir;
        DEST_DIR = destDir;
      };
    };

    # 타이머 (기본 매일 04:30 KST — DB 백업 05:30 이전, IO 경합 회피)
    systemd.timers.immich-originals-mirror = {
      description = "Daily Immich originals mirror to HDD";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        OnCalendar = cfg.mirrorTime;
        Persistent = true;
        RandomizedDelaySec = "5m";
      };
    };

    # 목적지 디렉토리 생성 (원본 자산이므로 0700)
    systemd.tmpfiles.rules = [
      "d ${destDir} 0700 root root -"
    ];
  };
}
