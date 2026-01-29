# SSH 서버 설정
{ config, constants, ... }:

let
  inherit (constants.ssh) clientAliveInterval clientAliveCountMax;
in
{
  services.openssh = {
    enable = true;
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

  networking.firewall.allowedTCPPorts = [ 22 ];
}
