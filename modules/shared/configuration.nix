# 공유 Nix 설정 (Darwin + Linux 공통)
{ lib, pkgs, ... }:

{
  # Nix 설정
  nix = {
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      warn-dirty = false;

      # 병렬 다운로드 최적화
      max-substitution-jobs = 128; # 기본값 16 → 128
      http-connections = 50; # 기본값 25 → 50
    };

    # 스토어 최적화 (auto-optimise-store 대신 사용)
    optimise.automatic = true;

    # 가비지 컬렉션
    gc = {
      automatic = true;
      options = "--delete-older-than 30d";
    }
    // lib.optionalAttrs pkgs.stdenv.isDarwin {
      interval = {
        Weekday = 0;
        Hour = 2;
        Minute = 0;
      };
    };
  };

  # 프로그램 활성화
  programs.zsh.enable = true;
}
