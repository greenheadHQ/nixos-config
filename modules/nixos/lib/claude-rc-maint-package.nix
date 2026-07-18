# claude-rc-maint CLI의 store 패키지 표현식.
#
# NixOS systemd 모듈(claude-remote-control.nix)과 darwin launchd 모듈
# (modules/darwin/programs/claude-remote-control.nix)이 같은 표현식을 평가해
# 스크립트 본체를 공유한다. runtimeInputs만 플랫폼 분기한다:
#   - 공통: native pid argv helper와 플랫폼 selector의 flock을 사용한다.
#   - Linux: util-linux(flock) + procps(pgrep) + lsof(cwd 조회)
#   - Darwin: discoteq flock과 lsof를 넣는다.
#     pgrep은 nixpkgs 대체가 없어 시스템 /usr/bin/pgrep에 의존한다 —
#     호출측 launchd agent가 PATH tail에 /usr/bin을 포함해야 한다.
{ pkgs }:
let
  pidArgv = import ./claude-rc-pid-argv-package.nix { inherit pkgs; };
  launchGroup = import ./claude-rc-launch-group-package.nix { inherit pkgs; };
  claudeRcFlock = import ../../../libraries/claude-rc-flock.nix { inherit pkgs; };
in
pkgs.writeShellApplication {
  name = "claude-rc-maint";
  runtimeInputs =
    with pkgs;
    [
      coreutils
      findutils
      gawk
      gnugrep
      gnused
      jq
      curl # service-lib send_notification
      pidArgv
      launchGroup
      claudeRcFlock
    ]
    ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
      procps
      lsof
    ]
    ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
      lsof
    ];
  text =
    builtins.readFile ../scripts/claude-rc-lib.sh
    + "\n"
    + builtins.readFile ../programs/claude-remote-control/files/claude-rc-maint.sh;
}
