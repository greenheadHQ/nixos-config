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
    # #872: 무인 에이전트 gh 인증 (Mac 전용, 방식 B — SA token → github-pat 캐시)
    # PRD #780 Phase 2b. per-session op read(#848/#871, Touch ID 1회) 대체.
    # SA token(agenix 배포 ~/.config/op/sa-token-mac)으로 github-pat을 무인 발급(Touch ID 0회) →
    # per-user temp 캐시(getconf DARWIN_USER_TEMP_DIR, 0700 디렉토리/0600 파일, 재부팅 휘발)에
    # 저장 후 세션/프로세스 간 재사용. 무인 다중 에이전트 지원.
    # SA token은 op 프로세스 env로만 전달(셸 env 미상주), 캐시엔 github-pat만(디스크 평문은 휘발 tmp 한정).
    # graceful: sa-token 미배포(work role)·op 부재·발급 실패 시 GH_TOKEN 미주입 → biometric/기존 경로.
    # 셸 lazy(launchd 비의존): op는 셸 PATH 사용, agenix 복호화 완료 후 로그인 셸에서 실행.
    # mkOrder 1600: shared default.nix의 plugins.sh source(mkAfter=1500)와 shellAliases 이후 로드.
    # ════════════════════════════════════════════════════════════════
    (lib.mkOrder 1600 ''
      # github-pat 캐시 발급/조회 (방식 B):
      #  - 캐시 경로는 per-user temp(getconf DARWIN_USER_TEMP_DIR, 0700 디렉토리)로 고정. world-writable
      #    /tmp 폴백을 쓰지 않아, 타 로컬 사용자가 캐시 파일을 선점해 GH_TOKEN을 치환하는 표면을 제거한다.
      #  - 유효 캐시(존재 + 12h 이내 + github-pat 형식)만 재사용. 만료(TTL)·부분쓰기·형식 불일치 캐시는
      #    폐기 후 SA로 재발급 → stale/truncated 토큰을 silent하게 GH_TOKEN으로 주입하지 않는다.
      #  - 동시 다중 에이전트 첫 호출 중복 발급은 무인 무해(atomic mv, 마지막 write win).
      _gh_pat() {
        local _cache; _cache="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)gh-pat-$(id -u)"
        if [ -f "$_cache" ] && [ -z "$(/usr/bin/find "$_cache" -mmin +720 2>/dev/null)" ]; then
          local _c; _c="$(cat "$_cache" 2>/dev/null)"
          case "$_c" in (ghp_*|github_pat_*) printf '%s' "$_c"; return 0 ;; esac
        fi
        rm -f "$_cache" 2>/dev/null
        local _sa="$HOME/.config/op/sa-token-mac"
        [ -r "$_sa" ] || return 0
        command -v op >/dev/null 2>&1 || return 0
        local _tok
        _tok=$(OP_SERVICE_ACCOUNT_TOKEN="$(cat "$_sa")" op read --no-newline \
               "op://${constants.onePassword.vaults.automation}/github-pat/token" 2>/dev/null || true)
        case "$_tok" in (ghp_*|github_pat_*) ;; (*) return 0 ;; esac
        ( umask 077; printf '%s' "$_tok" > "$_cache.tmp.$$" && mv -f "$_cache.tmp.$$" "$_cache" )
        printf '%s' "$_tok"
      }

      # gh: GH_TOKEN 있으면 직접, 없으면 캐시 PAT 주입, 그래도 없으면 op plugin biometric → command gh.
      unalias gh 2>/dev/null || true
      gh() {
        if [ -n "''${GH_TOKEN:-}" ]; then
          command gh "$@"
        else
          local _tok; _tok="$(_gh_pat)"
          if [ -n "$_tok" ]; then
            GH_TOKEN="$_tok" command gh "$@"
          elif [ -f "$HOME/.config/op/plugins.sh" ]; then
            op plugin run -- gh "$@"
          else
            command gh "$@"
          fi
        fi
      }

      # c(Claude Code) / codex 런처: 세션 시작 시 캐시 PAT을 GH_TOKEN으로 주입(성공 시에만), 프로세스 한정.
      unalias c codex 2>/dev/null || true
      c() {
        local _tok; _tok="$(_gh_pat)"
        if [ -n "$_tok" ]; then
          GH_TOKEN="$_tok" command claude --dangerously-skip-permissions --mcp-config ~/.claude/mcp.json "$@"
        else
          command claude --dangerously-skip-permissions --mcp-config ~/.claude/mcp.json "$@"
        fi
      }
      codex() {
        local _tok; _tok="$(_gh_pat)"
        if [ -n "$_tok" ]; then
          GH_TOKEN="$_tok" command codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen "$@"
        else
          command codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen "$@"
        fi
      }
    '')
  ];
}
