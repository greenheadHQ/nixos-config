# modules/nixos/programs/vaultwarden-update/default.nix
# Vaultwarden 버전 체크 (자동) 및 업데이트 (수동) 자동화
# - 매일 GitHub Releases API로 최신 버전 확인 → Pushover 알림
# - sudo vaultwarden-update 명령으로 수동 업데이트 안내 (pinned tag 전략)
import ../../lib/mk-update-module.nix {
  serviceName = "vaultwarden";
  serviceDisplayName = "Vaultwarden";
  githubRepo = "dani-garcia/vaultwarden";

  updateCfgPath = config: config.homeserver.vaultwardenUpdate;
  parentCfgPath = config: config.homeserver.vaultwarden;

  pushoverSecretName = "pushover-vaultwarden";
  pushoverSecretFile = ../../../../secrets/pushover-vaultwarden.age;

  updateScriptFile = ./files/update-script.sh;

  detectMajorMismatch = true;
}
