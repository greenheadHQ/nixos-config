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
      # NixOS 기본값은 ETM-only MAC (보안 강화)
      # Echo (iOS SSH 클라이언트)가 비-ETM MAC만 지원하므로 호환성 추가
      # 협상은 클라이언트 선호 순서 우선 — 대부분의 최신 클라이언트는 ETM/AEAD 우선 사용
      Macs = [
        "hmac-sha2-512-etm@openssh.com"
        "hmac-sha2-256-etm@openssh.com"
        "umac-128-etm@openssh.com"
        "hmac-sha2-512"
        "hmac-sha2-256"
      ];
    };
  };
}
