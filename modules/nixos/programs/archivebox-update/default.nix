# modules/nixos/programs/archivebox-update/default.nix
# ArchiveBox 버전 체크 (자동) 및 업데이트 (수동) 자동화
# - 매일 GitHub Releases API로 최신 버전 확인 → Pushover 알림
# - sudo archivebox-update 명령으로 안전한 업데이트 (pull → 재시작 → 헬스체크)
import ../../lib/mk-update-module.nix {
  serviceName = "archivebox";
  serviceDisplayName = "ArchiveBox";
  githubRepo = "ArchiveBox/ArchiveBox";

  updateCfgPath = config: config.homeserver.archiveBoxUpdate;
  parentCfgPath = config: config.homeserver.archiveBox;

  pushoverSecretName = "pushover-archivebox";
  pushoverSecretFile = ../../../../secrets/pushover-archivebox.age;

  updateScriptFile = ./files/update-script.sh;
}
