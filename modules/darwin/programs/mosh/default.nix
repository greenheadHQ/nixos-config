# macOS mosh 설정
#
# mosh-server를 활성화하여 Termius 등에서 mosh 연결 가능
# UDP 포트 60000-61000 사용 (Tailscale 네트워크에서는 방화벽 문제 없음)
{ pkgs, ... }:

{
  # mosh 패키지 설치 (mosh-server 포함)
  environment.systemPackages = [ pkgs.mosh ];
}
