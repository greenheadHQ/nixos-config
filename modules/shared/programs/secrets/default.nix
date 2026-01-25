# agenix secrets 설정
# 주의: agenix 모듈은 상위(darwin/home.nix, nixos/home.nix)에서 import해야 함
{
  config,
  pkgs,
  lib,
  ...
}:

{
  age = {
    # SSH 키로 복호화
    identityPaths = [ "${config.home.homeDirectory}/.ssh/id_ed25519" ];

    # Pushover API credentials
    # 사용처: atuin-watchdog.sh, fail2ban.nix, stop-notification.sh
    secrets.pushover-credentials = {
      file = ../../../../secrets/pushover-credentials.age;
      path = "${config.xdg.configHome}/pushover/credentials";
      mode = "0400";
    };

    # Pane Notepad 링크 파일 (회사 대시보드 등)
    # 사용처: pane-note.sh에서 새 노트 생성 시 Links 섹션에 포함
    secrets.pane-note-links = {
      file = ../../../../secrets/pane-note-links.age;
      path = "${config.xdg.configHome}/pane-note/links.txt";
      mode = "0400";
    };
  };
}
