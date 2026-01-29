# macOS SSH 서버 보안 설정
#
# 참고: macOS에서는 launchd가 SSH 소켓을 직접 관리하므로
# ListenAddress 설정이 적용되지 않습니다.
# LAN 접근 제한이 필요한 경우 pf 방화벽을 사용해야 합니다.
{
  config,
  lib,
  pkgs,
  constants,
  ...
}:

let
  inherit (constants.ssh) clientAliveInterval clientAliveCountMax;
in
{
  environment.etc."ssh/sshd_config.d/200-security.conf".text = ''
    # 공개키 인증만 허용
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no

    # 보안 강화
    PermitRootLogin no
    PermitEmptyPasswords no
    X11Forwarding no

    # 세션 타임아웃
    ClientAliveInterval ${toString clientAliveInterval}
    ClientAliveCountMax ${toString clientAliveCountMax}
  '';
}
