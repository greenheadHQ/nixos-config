# Shell 설정 - macOS 전용
{
  config,
  pkgs,
  lib,
  ...
}:

let
  darwinScriptsDir = ../../../darwin/scripts;
  sharedScriptsDir = ../../scripts;
in
{
  # macOS용 스크립트 설치
  home.file.".local/bin/nrs.sh" = {
    source = "${darwinScriptsDir}/nrs.sh";
    executable = true;
  };

  home.file.".local/bin/nrp.sh" = {
    source = "${darwinScriptsDir}/nrp.sh";
    executable = true;
  };

  home.file.".local/bin/nrh.sh" = {
    source = "${darwinScriptsDir}/nrh.sh";
    executable = true;
  };

  # 공용 스크립트 설치
  home.file.".local/bin/git-cleanup" = {
    source = "${sharedScriptsDir}/git-cleanup.sh";
    executable = true;
  };

  # macOS 전용 환경 변수
  home.sessionVariables = {
    ICLOUD = "$HOME/Library/Mobile Documents/com~apple~CloudDocs";
    BUN_INSTALL = "$HOME/.bun";
    # SSH 세션에서 로케일이 C로 폴백되는 문제 방지
    # (macOS는 /etc/locale.conf가 없어서 SSH 세션에 로케일이 자동 적용되지 않음)
    LANG = "en_US.UTF-8";
  };

  # macOS 전용 PATH
  home.sessionPath = [
    "$HOME/.bun/bin"
    "$HOME/.npm-global/bin"
  ];

  # macOS 전용 aliases
  home.shellAliases = {
    # Nix 시스템 관리 (darwin-rebuild)
    nrs = "~/.local/bin/nrs.sh";
    nrs-offline = "~/.local/bin/nrs.sh --offline";
    nrp = "~/.local/bin/nrp.sh";
    nrp-offline = "~/.local/bin/nrp.sh --offline";
    nrh = "~/.local/bin/nrh.sh";
    nrh-all = "~/.local/bin/nrh.sh --all";

    # Hammerspoon CLI
    hs = "/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs";
    hsr = ''hs -c "hs.reload()"'';

    # 터미널 CSI u 모드 리셋
    reset-term = ''printf "\033[?u\033[<u"'';
  };

  # macOS 전용 Zsh 초기화
  programs.zsh.initContent = lib.mkMerge [
    (lib.mkBefore ''
      # macOS NFD 유니코드 결합 문자 처리
      setopt COMBINING_CHARS

      # Ghostty 쉘 통합 설정
      if [ -n "''${GHOSTTY_RESOURCES_DIR}" ]; then
        builtin source "''${GHOSTTY_RESOURCES_DIR}/shell-integration/zsh/ghostty-integration"
      fi

      # Homebrew 설정
      eval "$(/opt/homebrew/bin/brew shellenv)"
    '')

    ''
      # cursor 래퍼: 인수 없이 실행 시 현재 디렉터리 열기
      cursor() {
        if [ $# -eq 0 ]; then
          command cursor .
        else
          command cursor "$@"
        fi
      }

      # NVM bash completion
      [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

      # Bun completions
      [ -s "$HOME/.bun/_bun" ] && source "$HOME/.bun/_bun"

      # Deno 설정
      [ -f "$HOME/.deno/env" ] && . "$HOME/.deno/env"
    ''
  ];
}
