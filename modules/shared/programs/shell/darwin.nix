# Shell 설정 - macOS 전용
{
  config,
  pkgs,
  lib,
  constants,
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

    # ════════════════════════════════════════════════════════════════
    # #848: 무인 에이전트 gh Touch ID 우회 (Mac 전용, PRD #780 Phase 2b 후속)
    # c/codex 런처가 세션 시작 시 op read로 GH_TOKEN을 1회 주입(Touch ID 1회) →
    # 세션 내 gh는 무인 작동(화면잠금/sleep 무관). 대화형 직접 gh는 op plugin biometric 유지.
    # graceful: op read 실패/빈 값 시 GH_TOKEN 미주입 → 기존 경로 fallback(work 맥북 무해).
    # 토큰은 env(메모리)만 — 디스크 평문 0 (Phase 2b hosts.yml 평문 제거 이득 보존).
    # mkOrder 1600: shared default.nix의 plugins.sh source(mkAfter=1500)와 shellAliases 이후 로드.
    # ════════════════════════════════════════════════════════════════
    (lib.mkOrder 1600 ''
      # gh: GH_TOKEN 있으면 직접 사용, 없으면 op plugin biometric (plugins.sh alias override).
      unalias gh 2>/dev/null || true
      gh() {
        if [ -n "''${GH_TOKEN:-}" ]; then
          command gh "$@"
        elif [ -f "$HOME/.config/op/plugins.sh" ]; then
          op plugin run -- gh "$@"
        else
          command gh "$@"
        fi
      }

      # 에이전트 런처용 GH_TOKEN 발급 (op read, Touch ID 1회). 실패 시 빈 문자열(graceful).
      _agent_gh_token() {
        command -v op >/dev/null 2>&1 || return 0
        op read --no-newline --account "${constants.onePassword.account}" \
          "op://${constants.onePassword.vaults.automation}/github-pat/token" 2>/dev/null || true
      }

      # c(Claude Code) / codex 런처: 세션 시작 시 GH_TOKEN 주입(성공 시에만), 프로세스 한정.
      unalias c codex 2>/dev/null || true
      c() {
        local _tok; _tok="$(_agent_gh_token)"
        if [ -n "$_tok" ]; then
          GH_TOKEN="$_tok" command claude --dangerously-skip-permissions --mcp-config ~/.claude/mcp.json "$@"
        else
          command claude --dangerously-skip-permissions --mcp-config ~/.claude/mcp.json "$@"
        fi
      }
      codex() {
        local _tok; _tok="$(_agent_gh_token)"
        if [ -n "$_tok" ]; then
          GH_TOKEN="$_tok" command codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen "$@"
        else
          command codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen "$@"
        fi
      }
    '')
  ];
}
