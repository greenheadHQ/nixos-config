# SSH 서버 설정
{ config, constants, ... }:

let
  inherit (constants.ssh) clientAliveInterval clientAliveCountMax;
in
{
  services.openssh = {
    enable = true;
    openFirewall = false; # trustedInterfaces(tailscale0)에서 이미 허용됨. LAN 노출 방지
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      PubkeyAuthentication = true;
      X11Forwarding = false;
      AllowTcpForwarding = true; # 개발 서버 터널링용
      ClientAliveInterval = clientAliveInterval;
      ClientAliveCountMax = clientAliveCountMax;
    };
  };
}
