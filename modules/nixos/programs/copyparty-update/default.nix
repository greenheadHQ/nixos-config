# modules/nixos/programs/copyparty-update/default.nix
# Copyparty 버전 체크 (자동) 및 업데이트 (수동) 자동화
# - 매일 GitHub Releases API로 최신 버전 확인 → Pushover 알림
# - sudo copyparty-update 명령으로 안전한 업데이트 (pull → 재시작 → 헬스체크)
import ../../lib/mk-update-module.nix {
  serviceName = "copyparty";
  serviceDisplayName = "Copyparty";
  githubRepo = "9001/copyparty";

  updateCfgPath = config: config.homeserver.copypartyUpdate;
  parentCfgPath = config: config.homeserver.copyparty;

  pushoverSecretName = "pushover-copyparty";
  pushoverSecretFile = ../../../../secrets/pushover-copyparty.age;

  updateScriptFile = ./files/update-script.sh;
}
