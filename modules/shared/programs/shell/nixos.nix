# Shell 설정 - Linux/NixOS 전용
{
  config,
  pkgs,
  lib,
  nixosConfigDefaultPath,
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
  ];

  # NixOS용 스크립트 설치
  home.file.".local/bin/nrs.sh" = {
    source = "${nixosScriptsDir}/nrs.sh";
    executable = true;
  };

  home.file.".local/bin/nrp.sh" = {
    source = "${nixosScriptsDir}/nrp.sh";
    executable = true;
  };

  home.file.".local/bin/claude-rc.sh" = {
    source = pkgs.replaceVars "${nixosScriptsDir}/claude-rc.sh" {
      flakePath = nixosConfigDefaultPath;
    };
    executable = true;
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
    # Nix 시스템 관리 (nixos-rebuild)
    nrs = "~/.local/bin/nrs.sh";
    nrs-offline = "~/.local/bin/nrs.sh --offline";
    nrp = "~/.local/bin/nrp.sh";
    nrp-offline = "~/.local/bin/nrp.sh --offline";

    # Claude Code Remote Control
    claude-rc = "~/.local/bin/claude-rc.sh";

    # nrs-relink (worktree 심링크 전환)
    nrs-relink = "~/.local/bin/nrs-relink.sh relink";
    nrs-restore = "~/.local/bin/nrs-relink.sh restore";
    nrs-relink-status = "~/.local/bin/nrs-relink.sh status";

    # NixOS 세대 히스토리
    nrh = "sudo nix-env --list-generations --profile /nix/var/nix/profiles/system | tail -10";
    nrh-all = "sudo nix-env --list-generations --profile /nix/var/nix/profiles/system";
  };
}
