# claude-rc-maint CLI의 store 패키지 표현식.
#
# NixOS systemd 모듈(claude-remote-control.nix)과 darwin launchd 모듈
# (modules/darwin/programs/claude-remote-control.nix)이 같은 표현식을 평가해
# 스크립트 본체를 공유한다. runtimeInputs만 플랫폼 분기한다:
#   - Linux: procps(pgrep) + util-linux(flock) + lsof(cwd 조회)
#   - Darwin: flock(discoteq — darwin 빌드 존재)과 lsof를 넣는다.
#     pgrep은 nixpkgs 대체가 없어 시스템 /usr/bin/pgrep에 의존한다 —
#     호출측 launchd agent가 PATH tail에 /usr/bin을 포함해야 한다.
{ pkgs }:
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
    ]
    ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
      procps
      util-linux # flock
      lsof
    ]
    ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
      flock
      lsof
    ];
  text =
    builtins.readFile ../scripts/claude-rc-lib.sh
    + "\n"
    + builtins.readFile ../programs/claude-remote-control/files/claude-rc-maint.sh;
}
