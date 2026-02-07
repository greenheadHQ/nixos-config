# Tailscale VPN
{ config, pkgs, ... }:

{
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "both"; # Funnel/Serve 지원
  };

  networking.firewall = {
    enable = true;
    trustedInterfaces = [ "tailscale0" ];
    allowedUDPPorts = [ config.services.tailscale.port ];
  };

  environment.systemPackages = [ pkgs.tailscale ];
}
