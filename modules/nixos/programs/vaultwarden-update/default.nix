# modules/nixos/programs/vaultwarden-update/default.nix
# Vaultwarden 버전 체크 (자동) 및 업데이트 (수동 실행) 자동화
# - 매일 GitHub Releases API로 최신 버전 확인 → Pushover 알림
# - sudo vaultwarden-update 명령으로 pinned tag 이미지 pull/restart/헬스체크
import ../../lib/mk-update-module.nix {
  serviceName = "vaultwarden";
  serviceDisplayName = "Vaultwarden";
  githubRepo = "dani-garcia/vaultwarden";

  updateCfgPath = config: config.homeserver.vaultwardenUpdate;
  parentCfgPath = config: config.homeserver.vaultwarden;

  pushoverSecretName = "pushover-vaultwarden";
  pushoverSecretFile = ../../../../secrets/pushover-vaultwarden.age;

  updateScriptFile = ./files/update-script.sh;

  extraUpdateEnv = config: _constants: {
    BACKUP_SERVICE = "vaultwarden-backup.service";
    HEALTH_URL = "http://127.0.0.1:${toString config.homeserver.vaultwarden.port}/alive";
  };

  detectMajorMismatch = true;
}
