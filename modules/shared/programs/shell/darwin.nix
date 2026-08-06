# Shell 설정 - macOS 전용
{
  config,
  pkgs,
  lib,
  constants,
  hostType,
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
    _sa="$HOME/${constants.onePassword.saTokenMacRelPath}"
    [ -r "$_sa" ] || exit 0
    command -v op >/dev/null 2>&1 || exit 0
    # OP_CONNECT_HOST/TOKEN은 op 공식 우선순위상 SA token보다 우선하므로 서브셸에서 제거한다
    # (op_get과 동일 계약 — repo는 Connect 서버 미도입 NG-1이라 잔존 Connect env는 항상 오염).
    _tok=$(unset OP_CONNECT_HOST OP_CONNECT_TOKEN; OP_SERVICE_ACCOUNT_TOKEN="$(cat "$_sa")" op read --no-newline \
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

  # ssh() preflight 단일 소스 주입 (constants 기반 — socket/키/기동인자 중복 제거)
  opAgentSock = "$HOME/${constants.onePassword.agentSocketRelPath}"; # zsh가 런타임에 $HOME 확장
  macSshKeyB64 = lib.elemAt (lib.splitString " " constants.sshDeviceKeys.macSsh) 1; # 공개키 가운데 base64 (nix가 split)
  opLaunchCmd = "/usr/bin/open ${lib.escapeShellArgs constants.onePassword.openArgs}"; # 1Password 백그라운드 기동(절대경로)
  minipcHostIP = constants.network.minipcTailscaleIP; # ssh -G effective hostname 판정 기준
  emergencyHost = "minipc-emergency"; # ssh config host alias(modules/darwin/programs/ssh) — 1Password 장애 fallback 안내 단일 소스
  headlessDispatcher = import ../../../darwin/programs/ssh/headless-dispatcher.nix {
    inherit
      config
      pkgs
      lib
      constants
      hostType
      ;
  };
  # Keep the non-interactive/remote signal set identical between .zshenv and
  # the interactive ssh() compatibility path. The launcher marker decides
  # whether .zshenv may change PATH; the signal set decides whether a shell is
  # headless enough to require bounded MiniPC authentication.
  headlessContextPredicate = ''
    { [ ! -t 0 ] || [ ! -t 2 ] || [ -n "''${SSH_CONNECTION:-}" ] \
      || [ -n "''${CI:-}" ] || [ -n "''${CLAUDECODE:-}" ] \
      || [ -n "''${CODEX_CI:-}" ] || [ -n "''${CODEX_PROGRAMMATIC:-}" ]; }
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

  # Codex/Claude launcher child가 명시 marker를 전달한 비대화형 컨텍스트에서만
  # private dispatcher를 PATH 앞에 둔다. global sessionPath/home.packages는 건드리지
  # 않으므로 interactive Ghostty와 일반 SSH는 /usr/bin/ssh 의미를 유지한다.
  programs.zsh.envExtra = lib.mkAfter (
    lib.optionalString headlessDispatcher.enabled ''
      if [[ "''${NIXOS_CONFIG_HEADLESS_SSH:-0}" == "1" ]] \
        && ${headlessContextPredicate}; then
        case ":$PATH:" in
          *":${headlessDispatcher.stableBinPath}:"*) ;;
          *) export PATH="${headlessDispatcher.stableBinPath}:$PATH" ;;
        esac
      fi
    ''
  );

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
    # ssh minipc preflight (1Password agent 안전망, PRD #780 Phase 2a 후속)
    # minipc 인증은 1Password agent의 mac-ssh 키에 의존한다(구 로컬 id_ed25519는 서버에서 퇴출).
    # 1Password가 미실행/잠금이면 agent가 mac-ssh를 못 줘 ssh가 구 키로 폴백→Permission denied가
    # 난다. 그 순간 원인·복구를 안내하고 1Password를 자동 기동한 뒤 agent 복구를 짧게 대기한다.
    # 평시엔 launchd 자동 기동(modules/darwin/programs/ssh)이 socket을 살려두므로 이 경로는
    # 수동 quit/크래시 등 잔여 케이스 전용이다. 대화형은 앱 기동 + Touch ID 잠금해제 대기를,
    # launcher-marked 무인 child는 .zshenv의 auth-phase dispatcher를 사용한다(#1094).
    # personal 전용 — minipc matchBlock/launchd와 스코프 일치(work Mac은 Tailnet 미소속이라 무관).
    # 대상 판정은 전부 `ssh -G "$@"`에 위임한다 — 수동 옵션 파싱은 ssh의 방대한 옵션 공간(메타모드·
    # user@host·-W·포트·alias·remote command)을 못 따라가 미탐·오탐이 난다. ssh -G는 -O/-W/-G 등과도
    # 충돌 없이 effective config를 출력한다(실측). preflight는 effective IdentityAgent가 1Password
    # socket과 정확히 일치할 때만 — none(emergency)·빈값·다른 agent 명시·타호스트는 raw ssh로 통과한다.
    # 활성 ControlMaster면 통과(multiplex/worker pool 재사용 보존)하되, "$@"를 -O check에 직접 넘기면
    # -W/-O와 충돌하므로 effective ControlPath만 -S로 쓴다. 키 매칭은 macSsh base64(단일 소스, nix split).
    # ════════════════════════════════════════════════════════════════
    (lib.optionalString (hostType == "personal") ''
      ssh() {
        local _cfg _host _ident _cpath
        # Preserve the bounded path that remote/automation zsh already had on
        # main. Launcher children also reach this same dispatcher via .zshenv;
        # interactive Ghostty has none of these signals and stays on raw SSH.
        if ${headlessContextPredicate}; then
          ${headlessDispatcher.stableBinPath}/ssh "$@"
          return $?
        fi
        _cfg=$(command ssh -G "$@" 2>/dev/null)
        _host=$(print -r -- "$_cfg" | awk 'tolower($1)=="hostname"{print $2; exit}')
        # IdentityAgent 전체 값(공백 포함 경로)을 추출해 1Password socket과 정확 비교한다.
        _ident=$(print -r -- "$_cfg" | awk 'tolower($1)=="identityagent"{sub(/^[^ ]+[ ]+/, ""); print; exit}')
        if [[ "$_host" == "${minipcHostIP}" && "$_ident" == "${opAgentSock}" ]]; then
          # 현재 호출의 effective ControlPath에 활성 master가 있으면 새 인증(서명)이 불필요하다.
          # 사용자 "$@"를 -O check에 직접 넘기면 -W/-O와 충돌하므로 effective ControlPath만 -S로 쓴다.
          # master 활성 여부를 1회 계산해 preflight와 후처리 진단이 공유한다(-O check 중복 호출 방지).
          _cpath=$(print -r -- "$_cfg" | awk 'tolower($1)=="controlpath"{sub(/^[^ ]+[ ]+/, ""); print; exit}')
          local _sock="${opAgentSock}" _b64="${macSshKeyB64}"
          local _master_active=0
          if [[ -n "$_cpath" && "$_cpath" != none ]] && command ssh -O check -S "$_cpath" "${minipcHostIP}" 2>/dev/null; then
            _master_active=1
          fi
          if (( ! _master_active )) \
            && ! SSH_AUTH_SOCK="$_sock" ssh-add -L 2>/dev/null | grep -qF "$_b64"; then
            # Touch ID 잠금 해제 대기 상한(초) — interactive shell을 오래 막지 않도록. tries = timeout / interval.
            local _poll_interval=0.5 _timeout_seconds=15
            local _max_tries=$(( _timeout_seconds / _poll_interval ))
            print -u2 "⚠️  ssh minipc 차단: 1Password SSH agent에 mac-ssh 키가 없습니다."
            print -u2 "   원인: 1Password 데스크탑이 미실행/잠금 상태 → mac-ssh 키 미제공."
            print -u2 "   조치: 1Password를 기동합니다 — Touch ID로 잠금 해제하세요."
            print -u2 "   대안: 즉시 접속이 필요하면  ssh ${emergencyHost}  (passphrase 직접 입력)."
            ${opLaunchCmd} 2>/dev/null
            local _i=0
            while ! SSH_AUTH_SOCK="$_sock" ssh-add -L 2>/dev/null | grep -qF "$_b64"; do
              if (( ++_i > _max_tries )); then
                print -u2 "   ✗ agent 복구 대기 초과(''${_timeout_seconds}s). 잠금 해제 후 재시도하거나 ssh ${emergencyHost} 사용."
                return 1
              fi
              sleep $_poll_interval
            done
            print -u2 "   ✓ agent 복구됨 — 접속합니다."
          fi

          # ── 후처리 진단(신규): agent 목록엔 있으나 sign만 실패하는 사각지대 안내 ──
          # 1Password가 "목록은 제공하나 서명(sign)에만 실패"하는 상태(앱 잠금/hang, 서명 승인
          # 미처리)에서 ssh minipc가 실패하면, raw ssh의 에러만으로는 원인이 1Password인지 알기
          # 어렵다. 여기에 원인 후보와 복구 경로를 덧붙인다.
          #
          # 설계: stderr를 캡처하지 않는다. command ssh를 원본 그대로 실행하므로 hang(procsubst/
          # ControlPersist master fd 상속)·원격 stderr multiplex 오탐·실시간성 손실·임시파일이
          # 구조적으로 없다(캡처 기반 접근이 반복 회귀를 낸 뒤의 단순화). 다만 stderr를 읽지 않으므로
          # "서명 실패"를 단정하지 않고 원인 후보를 제시한다. ssh 클라이언트 레벨 실패(exit 255: 연결·
          # 인증 계열)에만 발화하며, 원격 명령의 정상 실패는 그 명령의 exit code(≠255)로 전파되어
          # 여기 걸리지 않는다. master 재사용(_master_active) 경로는 서명이 없어 제외한다.
          if (( ! _master_active )); then
            local _rc
            command ssh "$@"
            _rc=$?
            if (( _rc == 255 )); then
              print -u2 "✗ ssh minipc 실패(exit 255 — 원인은 위 stderr 참조)."
              print -u2 "   1Password SSH agent 서명 실패라면: 1Password 완전 재시작(Cmd+Q → 재실행 → Touch ID 잠금 해제) 후 재시도."
              print -u2 "   그래도 안 되면(서버측 키 문제 등): ssh ${emergencyHost}  (passphrase 직접 입력)."
            fi
            return $_rc
          fi
        fi
        command ssh "$@"
      }
    '')

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
          GH_TOKEN="$_tok" command claude --dangerously-skip-permissions "$@"
        else
          command claude --dangerously-skip-permissions "$@"
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
