# modules/nixos/lib/service-lib.nix
# 홈서버 서비스 공통 셸 라이브러리를 Nix store에 배치
# 사용: serviceLib = import ../../lib/service-lib.nix { inherit pkgs; };
# 스크립트에서: source "$SERVICE_LIB"
{ pkgs }:
let
  pushoverLib = pkgs.writeText "pushover.sh" (builtins.readFile ../../shared/scripts/lib/pushover.sh);
in
pkgs.writeText "service-lib.sh" (
  builtins.replaceStrings [ "@pushoverLib@" ] [ (toString pushoverLib) ] (
    builtins.readFile ./service-lib.sh
  )
)
