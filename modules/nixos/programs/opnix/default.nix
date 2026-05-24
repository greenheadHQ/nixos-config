# modules/nixos/programs/opnix/default.nix
# opnix stub (Phase 1) — SA token 만료일 평문 record 배포만 담당
# Full opnix 구현 (flake input import, SA token EnvironmentFile, systemd unit,
# 90일 rotation timer + Pushover 알림)은 Phase 3에서 본 stub을 extend한다.
{
  config,
  lib,
  ...
}:

let
  cfg = config.homeserver.opnix;
in
{
  config = lib.mkIf cfg.enable {
    # 만료일 평문 배포 — Phase 3 rotation timer가 /etc/opnix-service-account-expiry를 읽음
    # source 파일: secrets/opnix-service-account-expiry.txt (ISO-8601 date 1줄, agenix 아님)
    environment.etc."opnix-service-account-expiry".source =
      ../../../../secrets/opnix-service-account-expiry.txt;
  };
}
