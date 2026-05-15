# Shell 설정 - macOS 전용
{
  config,
  pkgs,
  lib,
  ...
}:

let
  darwinScriptsDir = ../../../darwin/scripts;
  sharedScriptsDir = ../../../shared/scripts;
in
{
  # macOS용 스크립트 설치
  home.file.".local/bin/nrs" = {
    source = "${darwinScriptsDir}/nrs.sh";
    executable = true;
  };

  home.file.".local/bin/nrp" = {
    source = "${darwinScriptsDir}/nrp.sh";
    executable = true;
  };

  home.file.".local/bin/nrh" = {
    source = "${darwinScriptsDir}/nrh.sh";
    executable = true;
  };

  # nrs-lock CLI (lock 상태 조회/해제)
  home.file.".local/bin/nrs-lock" = {
    source = "${sharedScriptsDir}/nrs-lock.sh";
    executable = true;
  };

  # macOS 전용 환경 변수
  home.sessionVariables = {
    ICLOUD = "$HOME/Library/Mobile Documents/com~apple~CloudDocs";
    BUN_INSTALL = "$HOME/.bun";
    # SSH 세션에서 로케일이 C로 폴백되는 문제 방지
    # (macOS는 /etc/locale.conf가 없어서 SSH 세션에 로케일이 자동 적용되지 않음)
    LANG = "en_US.UTF-8";
    ANDROID_HOME = "$HOME/Library/Android/sdk";
  };

  # macOS 전용 PATH
  home.sessionPath = [
    "$HOME/.bun/bin"
  ];

  # macOS 전용 aliases
  home.shellAliases = {
    # Hammerspoon CLI
    hs = "/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs";
    hsr = ''hs -c "hs.reload()"'';
  };

  # macOS 전용 Zsh 초기화
  programs.zsh.initContent = lib.mkMerge [
    (lib.mkBefore ''
      # macOS NFD 유니코드 결합 문자 처리
      setopt COMBINING_CHARS

      # Ghostty 쉘 통합 설정
      if [ -n "''${GHOSTTY_RESOURCES_DIR}" ]; then
        # cmux can set GHOSTTY_RESOURCES_DIR without Ghostty.app's zsh integration path.
        if [ -r "''${GHOSTTY_RESOURCES_DIR}/shell-integration/zsh/ghostty-integration" ]; then
          builtin source "''${GHOSTTY_RESOURCES_DIR}/shell-integration/zsh/ghostty-integration"
        fi
      fi

      # Homebrew 설정
      eval "$(/opt/homebrew/bin/brew shellenv)"
    '')

    ''
      # NVM bash completion
      [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

      # Bun completions
      [ -s "$HOME/.bun/_bun" ] && source "$HOME/.bun/_bun"

      # Deno 설정
      [ -f "$HOME/.deno/env" ] && . "$HOME/.deno/env"

      # Android SDK platform-tools (adb, fastboot)
      # home.sessionPath는 PATH 앞에 prepend하므로 platform-tools의
      # sqlite3 등이 시스템 바이너리를 shadow한다. append로 우회.
      [ -d "$ANDROID_HOME/platform-tools" ] && export PATH="$PATH:$ANDROID_HOME/platform-tools"
    ''
  ];
}
