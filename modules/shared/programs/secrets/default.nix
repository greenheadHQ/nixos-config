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

    # 서비스별 Pushover credentials (독립적 토큰 revocation + API rate limit 분리)
    secrets.pushover-claude-stop = {
      file = ../../../../secrets/pushover-claude-stop.age;
      path = "${config.xdg.configHome}/pushover/claude-stop";
      mode = "0400";
    };
    secrets.pushover-claude-ask = {
      file = ../../../../secrets/pushover-claude-ask.age;
      path = "${config.xdg.configHome}/pushover/claude-ask";
      mode = "0400";
    };
    secrets.pushover-atuin = {
      file = ../../../../secrets/pushover-atuin.age;
      path = "${config.xdg.configHome}/pushover/atuin";
      mode = "0400";
    };
    secrets.pushover-fail2ban = {
      file = ../../../../secrets/pushover-fail2ban.age;
      path = "${config.xdg.configHome}/pushover/fail2ban";
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
