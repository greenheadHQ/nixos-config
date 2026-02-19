# modules/nixos/programs/karakeep-update/default.nix
# Karakeep 버전 체크 (자동) 및 업데이트 (수동) 자동화
# - 매일 GitHub Releases API로 최신 버전 확인 → Pushover 알림
# - sudo karakeep-update 명령으로 안전한 업데이트 (pull → 재시작 → 헬스체크)
import ../../lib/mk-update-module.nix {
  serviceName = "karakeep";
  serviceDisplayName = "Karakeep";
  githubRepo = "karakeep-app/karakeep";

  updateCfgPath = config: config.homeserver.karakeepUpdate;
  parentCfgPath = config: config.homeserver.karakeep;

  pushoverSecretName = "pushover-karakeep";
  pushoverSecretFile = ../../../../secrets/pushover-karakeep.age;

  updateScriptFile = ./files/update-script.sh;
}
