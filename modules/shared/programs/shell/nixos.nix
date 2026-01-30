# Shell 설정 - Linux/NixOS 전용
{
  config,
  pkgs,
  lib,
  ...
}:

let
  nixosScriptsDir = ../../../nixos/scripts;
  sharedScriptsDir = ../../scripts;
in
{
  # NixOS 전용 Zsh 초기화
  programs.zsh.initContent = lib.mkMerge [
    (lib.mkBefore ''
      # 유니코드 결합 문자 처리 (wide character 지원)
      setopt COMBINING_CHARS

      # SSH 접속 시 tmux 자동 연결 (NixOS 서버 전용)
      # 조건: SSH 세션 + 대화형 + tmux 외부 + mosh 외부
      if [[ -n "$SSH_CONNECTION" && $- == *i* && -z "$TMUX" && -z "$MOSH" ]]; then
        if tmux has-session 2>/dev/null; then
          echo "━━━ tmux sessions ━━━"
          tmux list-sessions -F "  #{?session_attached,▶,○} #S: #{session_windows}w (#{session_created_string})" 2>/dev/null
          echo "━━━━━━━━━━━━━━━━━━━━━"
          echo ""
        fi
        tmux new-session -A -s main
      fi
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

  # 공용 스크립트 설치
  home.file.".local/bin/git-cleanup" = {
    source = "${sharedScriptsDir}/git-cleanup.sh";
    executable = true;
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

    # NixOS 세대 히스토리
    nrh = "sudo nix-env --list-generations --profile /nix/var/nix/profiles/system | tail -10";
    nrh-all = "sudo nix-env --list-generations --profile /nix/var/nix/profiles/system";
  };
}
