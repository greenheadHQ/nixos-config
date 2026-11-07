{
  inputs,
  constants,
  ...
}:
{
  # system service의 별도 rex 사용자가 아니라 로그인 사용자 계정으로 실행한다.
  imports = [ inputs.rex.homeManagerModules.default ];

  programs.rex.enable = true;
  services.rex = {
    enable = true;
    # Unix socket + 내장 Tailscale만 사용한다. 익명 TCP·공개 인그레스는 열지 않는다.
    allowAnonymous = false;
    extraListen = [ ];
    tailscale = {
      enable = true;
      hostname = constants.rex.minipcTailnetHostname;
      allowTailnetMembers = false;
      # 최초 등록은 사용자가 로그인한다. 태그를 붙이면 소유자 제한이 불가능하다.
      advertiseTags = [ ];
    };
  };
  # 공식 모듈의 X-SwitchMethod=keep-old를 유지한다. nrs가 살아 있는 세션을
  # 종료하지 않으며, 새 바이너리 적용을 위한 재시작은 세션을 확인한 뒤 수동으로 한다.
  # 로그아웃 후 생존은 NixOS private-job-runner 모듈의 기존 linger 선언이 보장한다.
}
