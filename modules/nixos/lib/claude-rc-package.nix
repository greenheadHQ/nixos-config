# claude-rc 사용자 래퍼의 store 패키지 표현식.
#
# Home Manager가 ~/.local/bin/claude-rc로 링크하는 단일 래퍼 패키지다.
# headless multi-instance 래퍼는 flock/jq/lsof/native pid argv helper 등 일반 사용자 PATH에 없을 수
# 있는 도구에 의존하므로 writeShellApplication runtimeInputs로 실행 환경을
# 고정한다. claude 자체는 ~/.local/bin/claude launcher가 자체 업데이트를
# 관리하므로 runtimeInputs에 넣지 않고 호출측 PATH tail에서 해석한다.
{
  pkgs,
  controlEnvironment ? { },
}:
let
  controlEnvironmentScript = pkgs.lib.concatStringsSep "\n" (
    pkgs.lib.mapAttrsToList (
      name: value:
      assert builtins.match "[A-Z][A-Z0-9_]*" name != null;
      "export ${name}=${pkgs.lib.escapeShellArg (toString value)}"
    ) controlEnvironment
  );
  pidArgv = import ./claude-rc-pid-argv-package.nix { inherit pkgs; };
  launchGroup = import ./claude-rc-launch-group-package.nix { inherit pkgs; };
  claudeRcFlock = import ../../../libraries/claude-rc-flock.nix { inherit pkgs; };
in
pkgs.writeShellApplication {
  name = "claude-rc";
  runtimeInputs =
    with pkgs;
    [
      coreutils
      findutils
      gawk
      gnugrep
      gnused
      jq
      git
      pidArgv
      launchGroup
      claudeRcFlock
    ]
    ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
      procps # pgrep
      lsof
    ]
    ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
      lsof
      # pgrep은 nixpkgs 대체가 없어 호출측 PATH의 /usr/bin/pgrep으로 fallthrough.
    ];
  text =
    controlEnvironmentScript
    + "\n"
    + builtins.readFile ../scripts/claude-rc-lib.sh
    + "\n"
    + builtins.readFile ../scripts/claude-rc.sh;
}
