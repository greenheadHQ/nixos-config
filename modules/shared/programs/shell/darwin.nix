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

  # #872 후속(run-da 반영): gh 무인 인증을 PATH 실행 파일로 제공한다.
  # gh wrapper가 interactive .zshrc(initContent) 함수로만 정의되면 non-interactive 셸
  # (Claude Code Bash tool의 shell snapshot 등)에 적용되지 않아 gh가 biometric/미인증으로 빠졌다.
  # gh-auth는 PATH 실행 파일이지만 `gh` 라우팅은 shellAliases gh="gh-auth"에 의존한다 — 이는
  # Claude Code Bash tool의 shell snapshot이 캡처하는 셸(주 사용 환경, LLM 자동화)을 커버한다.
  # rc를 읽지 않는 셸(CI의 bash -c 등)은 범위 밖이며(F4), homebrew gh가 PATH 최우선이라
  # ~/.local/bin shim도 비효과 + 현재 CI 무인 gh 수요 없음(YAGNI) — 필요 시 별도 follow-up.
  #
  # gh-pat-mac: SA token → github-pat을 per-user temp 캐시(0700/0600, 12h TTL, prefix 검증)에
  # 무인 발급해 stdout으로 출력. 캐시/SA/op 부재 시 빈 출력(graceful). c/codex 런처와 공유.
  ghPatMac = pkgs.writeShellScriptBin "gh-pat-mac" ''
    # F1: getconf 실패 시 빈 prefix→상대경로(gh-pat-NNN) 붕괴로 PAT가 cwd에 평문 기록될 수 있다.
    # absolute 경로인지 검증하고, 아니면 fail-closed(발급 안 함)한다.
    _tmp="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR 2>/dev/null)"
    case "$_tmp" in /*) ;; *) exit 0 ;; esac
    _cache="''${_tmp%/}/gh-pat-$(id -u)"
    if [ -f "$_cache" ] && [ -z "$(/usr/bin/find "$_cache" -mmin +720 2>/dev/null)" ]; then
      _c="$(cat "$_cache" 2>/dev/null)"
      case "$_c" in ghp_*|github_pat_*) printf '%s' "$_c"; exit 0 ;; esac
    fi
    rm -f "$_cache" 2>/dev/null
    _sa="$HOME/.config/op/sa-token-mac"
    [ -r "$_sa" ] || exit 0
    command -v op >/dev/null 2>&1 || exit 0
    _tok=$(OP_SERVICE_ACCOUNT_TOKEN="$(cat "$_sa")" op read --no-newline \
           "op://${constants.onePassword.vaults.automation}/github-pat/token" 2>/dev/null || true)
    case "$_tok" in ghp_*|github_pat_*) ;; *) exit 0 ;; esac
    ( umask 077; printf '%s' "$_tok" > "$_cache.tmp.$$" && mv -f "$_cache.tmp.$$" "$_cache" )
    printf '%s' "$_tok"
  '';

  # gh-auth: GH_TOKEN 미설정 시 gh-pat-mac으로 발급해 주입한 뒤 실제 gh를 exec한다.
  # F3: op plugin biometric fallback은 제거했다 — [ -t 0 ]는 PTY를 받은 non-interactive
  # automation도 true라 무인 환경에서 biometric 팝업으로 빠질 수 있고, plugins.sh source도
  # 제거(default.nix)되어 도달 불가다. 발급 실패 시 GH_TOKEN 없이 실제 gh로 exec(gh 자체 인증).
  ghAuth = pkgs.writeShellScriptBin "gh-auth" ''
    if [ -z "''${GH_TOKEN:-}" ]; then
      _tok="$(${ghPatMac}/bin/gh-pat-mac)"
      [ -n "$_tok" ] && export GH_TOKEN="$_tok"
    fi
    exec ${pkgs.gh}/bin/gh "$@"
  '';
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
    # #872 후속: gh를 무인 wrapper(gh-auth)로 라우팅. shellAliases는 Claude Code Bash tool의 shell
    # snapshot이 캡처하므로, interactive .zshrc 함수와 달리 LLM 자동화 셸에서도 gh가 무인 동작한다.
    # rc를 읽지 않는 CI류 셸은 범위 밖(F4) — let 블록 주석 참조.
    gh = "gh-auth";
  };

  # #872 후속: gh 무인 wrapper 실행 파일 (interactive/non-interactive/snapshot 공통)
  home.packages = [
    ghPatMac
    ghAuth
  ];

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
    # #872(+후속): 무인 에이전트 gh 인증 (Mac 전용, 방식 B — SA token → github-pat 캐시)
    # PRD #780 Phase 2b. per-session op read(#848/#871, Touch ID 1회) 대체.
    # gh 자체는 gh-auth wrapper(let 블록 + shellAliases gh="gh-auth")가 처리한다(snapshot 캡처 셸 커버).
    # 셸 함수는 interactive .zshrc 전용이라 non-interactive(Claude Code Bash tool snapshot)에 미적용이라
    # gh가 biometric/미인증으로 빠졌다 → shellAliases 라우팅으로 LLM 자동화 셸을 커버. 아래는 c/codex 런처.
    # gh-pat-mac이 SA token(agenix 배포 ~/.config/op/sa-token-mac)으로 github-pat을 per-user temp
    # 캐시(getconf DARWIN_USER_TEMP_DIR, 0700/0600, 12h TTL, 재부팅 휘발)에 무인 발급(Touch ID 0회).
    # SA token은 op 프로세스 env로만 전달(셸 env 미상주), 캐시엔 github-pat만(디스크 평문은 휘발 tmp 한정).
    # graceful: sa-token 미배포(work role)·op 부재·발급 실패 시 GH_TOKEN 미주입 → 실제 gh로 exec.
    # 아래 mkOrder 1600 블록은 interactive 전용 c/codex 런처다(gh-pat-mac 공유).
    # ════════════════════════════════════════════════════════════════
    (lib.mkOrder 1600 ''
      # c(Claude Code) / codex 런처: 세션 시작 시 gh-pat-mac(PATH bin)으로 github-pat을 발급해
      # GH_TOKEN으로 주입(성공 시에만), 프로세스 한정. graceful: 발급 실패 시 미주입.
      # gh 자체는 gh-auth wrapper(PATH 실행 파일, let 블록)가 처리 — shellAliases gh = "gh-auth".
      unalias c codex 2>/dev/null || true
      c() {
        local _tok; _tok="$(gh-pat-mac)"
        if [ -n "$_tok" ]; then
          GH_TOKEN="$_tok" command claude --dangerously-skip-permissions --mcp-config ~/.claude/mcp.json "$@"
        else
          command claude --dangerously-skip-permissions --mcp-config ~/.claude/mcp.json "$@"
        fi
      }
      codex() {
        local _tok; _tok="$(gh-pat-mac)"
        if [ -n "$_tok" ]; then
          GH_TOKEN="$_tok" command codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen "$@"
        else
          command codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen "$@"
        fi
      }
    '')
  ];
}
