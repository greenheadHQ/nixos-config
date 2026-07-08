# Shell 설정 - Linux/NixOS 전용
{
  config,
  pkgs,
  lib,
  username,
  ...
}:

let
  nixosScriptsDir = ../../../nixos/scripts;
in
{
  # NixOS 전용 Zsh 초기화
  programs.zsh.initContent = lib.mkMerge [
    (lib.mkBefore ''
      # 유니코드 결합 문자 처리 (wide character 지원)
      setopt COMBINING_CHARS
    '')

    # MiniPC gh 인증 — opnix가 materialize한 github-pat을 GH_TOKEN으로 주입한다.
    # headless 환경이라 1Password Shell Plugin(desktop app + interactive 요구)은 부적합하므로
    # 데스크탑의 op plugin alias 패턴 대신 GH_TOKEN wrapper를 쓴다.
    # 파일 부재(부팅 직후 opnix-secrets 완료 전 / SaaS outage) 시 plain gh로 폴백해 wrapper가 깨지지 않게 한다.
    ''
      gh() {
        local _ghpat=/run/opnix/${username}/github-pat
        if [ -r "$_ghpat" ]; then
          GH_TOKEN="$(< "$_ghpat")" command gh "$@"
        else
          command gh "$@"
        fi
      }
    ''
  ];

  # NixOS용 스크립트 설치
  home.file.".local/bin/nrs" = {
    source = "${nixosScriptsDir}/nrs.sh";
    executable = true;
  };

  home.file.".local/bin/nrp" = {
    source = "${nixosScriptsDir}/nrp.sh";
    executable = true;
  };

  # store 패키지로 배선 — 래퍼는 flock/jq/lsof 등 runtimeInputs가 필요하므로
  # Home Manager activation 산출물이 아니라 패키지 산출물을 ~/.local/bin에 링크한다.
  home.file.".local/bin/claude-rc" = {
    source = "${
      import ../../../nixos/lib/claude-rc-package.nix {
        inherit pkgs;
      }
    }/bin/claude-rc";
  };

  # NixOS: mise prebuilt 바이너리 사용 (소스 빌드 방지)
  # NixOS에서 all_compile/node.compile 기본값이 true → Python 3.13과 Node.js configure.py 비호환 에러 발생
  home.sessionVariables = {
    MISE_ALL_COMPILE = "0";
    MISE_NODE_COMPILE = "0"; # Node 전용 안전핀
  };

  # NixOS 전용 패키지 (macOS는 Homebrew python3 사용)
  home.packages = [
    pkgs.python3
  ];

  # NixOS 전용 aliases
  home.shellAliases = {
    # NixOS 세대 히스토리
    nrh = "sudo nix-env --list-generations --profile /nix/var/nix/profiles/system | tail -10";
    nrh-all = "sudo nix-env --list-generations --profile /nix/var/nix/profiles/system";
  };
}
