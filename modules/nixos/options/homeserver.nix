# modules/nixos/options/homeserver.nix
# 홈서버 서비스 옵션 정의
# mkOption/mkEnableOption으로 서비스 선언적 활성화 지원
{
  config,
  lib,
  constants,
  ...
}:

{
  options.homeserver = {
    immich = {
      enable = lib.mkEnableOption "Immich photo backup service";
      port = lib.mkOption {
        type = lib.types.port;
        default = constants.network.ports.immich;
        description = "Port for Immich web interface";
      };
    };

    uptimeKuma = {
      enable = lib.mkEnableOption "Uptime Kuma monitoring service";
      port = lib.mkOption {
        type = lib.types.port;
        default = constants.network.ports.uptimeKuma;
        description = "Port for Uptime Kuma web interface";
      };
    };

    plex = {
      enable = lib.mkEnableOption "Plex media server";
      port = lib.mkOption {
        type = lib.types.port;
        default = constants.network.ports.plex;
        description = "Port for Plex web interface";
      };
    };

    immichCleanup = {
      enable = lib.mkEnableOption "Immich temp album cleanup (Claude Code Temp)";
      albumName = lib.mkOption {
        type = lib.types.str;
        default = "Claude Code Temp";
        description = "Name of the album to cleanup";
      };
    };
  };

  # 모든 서비스 모듈을 정적으로 import (Nix 모듈 시스템은 조건부 import 불가)
  # 각 서비스 모듈 내부에서 mkIf cfg.enable 처리
  imports = [
    ../programs/docker/runtime.nix # Podman 런타임 공통 설정
    ../programs/docker/immich.nix
    ../programs/docker/uptime-kuma.nix
    ../programs/docker/plex.nix
    ../programs/immich-cleanup # Immich 임시 앨범 자동 삭제
  ];
}
