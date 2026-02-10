# modules/nixos/programs/uptime-kuma-update/default.nix
# Uptime Kuma 버전 체크 (자동) 및 업데이트 (수동) 자동화
# - 매일 GitHub Releases API로 최신 버전 확인 → Pushover 알림
# - sudo uptime-kuma-update 명령으로 안전한 업데이트 (backup → pull → 재시작 → 헬스체크)
import ../../lib/mk-update-module.nix {
  serviceName = "uptime-kuma";
  serviceDisplayName = "Uptime Kuma";
  githubRepo = "louislam/uptime-kuma";

  updateCfgPath = config: config.homeserver.uptimeKumaUpdate;
  parentCfgPath = config: config.homeserver.uptimeKuma;

  pushoverSecretName = "pushover-uptime-kuma";
  pushoverSecretFile = ../../../../secrets/pushover-uptime-kuma.age;

  updateScriptFile = ./files/update-script.sh;

  updateScriptInputs =
    pkgs: with pkgs; [
      curl
      jq
      coreutils
      gzip
      podman
      systemd
      findutils
    ];

  extraUpdateEnv = _config: constants: {
    BACKUP_DIR = "/var/lib/uptime-kuma-update/backups";
    DATA_DIR = "${constants.paths.dockerData}/uptime-kuma/data";
  };

  extraTmpfilesRules = [
    "d /var/lib/uptime-kuma-update/backups 0700 root root -"
  ];

  detectMajorMismatch = true;
}
