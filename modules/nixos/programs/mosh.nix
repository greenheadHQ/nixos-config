# mosh 설정
{ config, ... }:

{
  programs.mosh = {
    enable = true;
    openFirewall = false; # trustedInterfaces(tailscale0)에서 이미 허용됨. LAN 노출 방지
  };
}
