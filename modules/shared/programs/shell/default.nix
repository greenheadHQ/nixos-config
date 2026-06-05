# Shell 설정 - 공통 부분
{
  config,
  pkgs,
  lib,
  nixosConfigDefaultPath,
  constants,
  ...
}:

let
  sharedScriptsDir = ../../scripts;
  # mise shims 경로 변수 선언 — envExtra/initContent 공통 SoT.
  # 경로는 constants.mise.shimsDirExpr 우선순위(MISE_DATA_DIR → XDG_DATA_HOME/mise → $HOME/.local/share/mise).
  miseShimsDecl = ''_mise_shims="${constants.mise.shimsDirExpr}"'';
  pythonWithTomlkit =
    (import ../../../../libraries/python-runtimes.nix { inherit pkgs; }).pythonWithTomlkit;
in
{
  home.file.".local/bin/atuin-clean-kr" = {
    source = "${sharedScriptsDir}/atuin-clean-kr.py";
    executable = true;
  };
  home.file.".local/bin/git-cleanup" = {
    source = "${sharedScriptsDir}/git-cleanup.sh";
    executable = true;
  };
  home.file.".local/bin/wt" = {
    source = "${sharedScriptsDir}/wt.sh";
    executable = true;
  };
  home.file.".local/lib/wt" = {
    source = "${sharedScriptsDir}/lib/wt";
    recursive = true;
  };
  home.file.".local/bin/codex-sync" = {
    source =
      let
        rawScript = "${sharedScriptsDir}/codex-sync.sh";
        wrapper = pkgs.writeShellScript "codex-sync-wrapper" ''
          export CODEX_SYNC_PYTHON="${pythonWithTomlkit}/bin/python3"
          exec "${pkgs.bash}/bin/bash" "${rawScript}" "$@"
        '';
      in
      wrapper;
    executable = true;
  };
  # codex exec hang supervisor (issue #593): Nix wrapper가 absolute store path env var를 set한 후
  # raw script를 exec한다. raw script는 CODEX_EXEC_TIMEOUT_BIN/CODEX_EXEC_SETSID_BIN 우선 사용.
  # 이로써 wrapper subprocess + codex exec 자식 shell의 PATH를 건드리지 않아 user PATH(BSD
  # coreutils 우선)를 보존한다.
  home.file.".local/bin/codex-exec-supervised" =
    let
      rawScript = "${sharedScriptsDir}/codex-exec-supervised.sh";
      wrapper = pkgs.writeShellScript "codex-exec-supervised-wrapper" ''
        export CODEX_EXEC_TIMEOUT_BIN="${pkgs.coreutils}/bin/timeout"
        export CODEX_EXEC_SETSID_BIN="${pkgs.util-linux}/bin/setsid"
        exec "${rawScript}" "$@"
      '';
    in
    {
      source = wrapper;
      executable = true;
    };
  home.file.".local/bin/nfu" = {
    source = pkgs.replaceVars "${sharedScriptsDir}/nfu.sh" {
      flakePath = nixosConfigDefaultPath;
    };
    executable = true;
  };
  home.file.".local/bin/nrs-relink" = {
    source = pkgs.replaceVars "${sharedScriptsDir}/nrs-relink.sh" {
      flakePath = nixosConfigDefaultPath;
    };
    executable = true;
  };

  # Shell 함수 라이브러리 (source로 로딩)
  # replaceVars: @flakePath@ → nixosConfigDefaultPath (항상 메인 레포 경로)
  # worktree 감지는 런타임에 detect_worktree()가 처리
  home.file.".local/lib/rebuild-common.sh" = {
    source = pkgs.replaceVars "${sharedScriptsDir}/rebuild-common.sh" {
      flakePath = nixosConfigDefaultPath;
    };
  };
  home.file.".local/lib/rebuild" = {
    source = "${sharedScriptsDir}/lib/rebuild";
    recursive = true;
  };
  # PATH 추가 (공통)
  home.sessionPath = [
    "$HOME/.local/bin"
  ];

  # Shell aliases (공통)
  home.shellAliases = {
    # 파일 목록 (eza 사용)
    l = "eza -l";
    ls = "eza -la";
    ll = "eza -la";

    # broot: tree 스타일 출력
    bt = "br -c :pt";

    # Claude Code (권한 스킵 + MCP 설정)
    # === Change Intent Record ===
    # v1: --chrome(Claude in Chrome) 기본 활성화 — 브라우저 자동화를 항상 사용하려 했고,
    #     당시 chrome-devtools MCP를 적극 활용하지 않았음
    # v2 (PR #74 이후, 이번 변경): --chrome 제거 — PR #74에서 chrome-devtools MCP
    #     autoConnect 전략이 확립된 이후 적극 활용하게 되면서, Claude in Chrome과
    #     동일 탭 제어가 경합. chrome-devtools가 응답 속도도 빠르고
    #     MCP 서버로 유연하게 on/off 가능하여 --chrome 불필요.
    #     trade-off: Claude in Chrome 전용 편의 기능(gif_creator 등)을 잃지만,
    #               chrome-devtools MCP가 동등 이상의 기능을 더 유연하게 제공.
    c = "claude --dangerously-skip-permissions --mcp-config ~/.claude/mcp.json";

    # Codex CLI 위험 모드 단축 (사용자 요청)
    # Linux MiniPC: apps feature 를 template 에서 비활성화해 fast startup 보장 (#772).
    # 기본 codex 는 connector discovery 가 비활성화되므로 stderr 한 줄 안내를 출력하고,
    # connector / plugin / tool_search 가 필요하면 codex-apps 로 세 feature 모두 복원한다.
    # Darwin 은 features default 가 true 라 안내 echo 없이 기존 alias 그대로 유지한다.
    codex =
      if pkgs.stdenv.isLinux then
        "echo '[codex] apps feature disabled for fast startup. Use codex-apps for full connector surface.' >&2; command codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen"
      else
        "command codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen";
    codex-apps = "command codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen --enable apps --enable plugins --enable tool_search";

    # lazygit 단축
    lg = "lazygit";

    # git stash --include-untracked 단축
    gs = "git stash --include-untracked";

    # cheat content search 단축
    cs = "cheat -c -s";

    # 디렉토리 이동 단축
    ".." = "cd ..";
    "..." = "cd ../..";
  };

  # Zsh 설정 (공통)
  programs.zsh = {
    enable = true;
    autosuggestion = {
      enable = true;
      highlight = "fg=#808080";
      strategy = [ "history" ];
    };
    syntaxHighlighting.enable = true;

    history = {
      size = 10000;
      save = 10000;
      ignoreDups = true;
      ignoreSpace = true;
      expireDuplicatesFirst = true;
      share = true;
    };

    # .zshenv: snapshot 미경유 비대화형 세션(SSH `zsh -c` 등)에서 mise 도구를
    # 노출하기 위해 PATH에 shims를 보장한다. 이 경로는 .zshrc를 로드하지 않아
    # `mise activate zsh`가 install-bins도 prepend하지 못하므로 shims가 없으면
    # mise 도구가 노출되지 않는다.
    # 대화형 훅 + Claude Code snapshot 경유 비대화형 보강은 .zshrc에서 처리한다.
    # 회귀 메커니즘(MISE_SHELL 가드 폐기 / hook 모드 정책상 shims 미prepend)의
    # SoT는 .claude/skills/managing-mise/SKILL.md "셸 활성화 구조" 섹션.
    envExtra = ''
      ${miseShimsDecl}
      if command -v mise >/dev/null 2>&1 \
         && [[ ":$PATH:" != *":$_mise_shims:"* ]]; then
        eval "$(mise activate zsh --shims)"
      fi
      unset _mise_shims

      # 비대화형 셸 기본값: side-by-side 비활성화
      # (대화형 셸에서는 .zshrc의 precmd 훅이 터미널 너비에 따라 동적 제어)
      export DELTA_FEATURES=""
    '';

    # 공통 초기화 스크립트 (.zshrc)
    initContent = lib.mkMerge [
      (lib.mkBefore ''
        # Mise 활성화 (대화형 셸)
        # cd-time 자동 버전 전환은 `mise activate zsh`(hook 모드)가 처리한다.
        # 직후 shims를 PATH에 prepend하여 Claude Code snapshot이 캡처하는
        # interactive PATH에 shims가 포함되도록 한다.
        # 회귀 메커니즘(snapshot baseline에 shims 누락 — hook 모드 정책상
        # install-bins만 prepend되고 shims는 prepend 안 됨) + 위험/우려 +
        # fallback 후보(.claude/settings.json env.PATH, login shell init 등)의
        # SoT는 .claude/skills/managing-mise/SKILL.md "셸 활성화 구조" 섹션.
        if command -v mise >/dev/null 2>&1; then
          eval "$(mise activate zsh)"
          ${miseShimsDecl}
          [[ ":$PATH:" != *":$_mise_shims:"* ]] && export PATH="$_mise_shims:$PATH"
          unset _mise_shims
        fi

        # tmux 내부에서 clear 시 history buffer도 함께 삭제
        if [ -n "$TMUX" ]; then
          alias clear='clear && tmux clear-history'
        fi

        # 동적 delta side-by-side 제어 (터미널 너비 기반)
        # 좁은 터미널(< 120컬럼)에서 side-by-side 자동 비활성화
        # precmd: 매 프롬프트 전 실행 → 터미널 리사이즈 즉시 반영
        _update_delta_features() {
          if [[ ''${COLUMNS:-80} -lt 120 ]]; then
            export DELTA_FEATURES=""
          else
            unset DELTA_FEATURES
          fi
        }
        precmd_functions+=(_update_delta_features)

        # worktree 삭제 후 dangling 심링크 자동 복구 안전망 (#294)
        # 성능: nrs-relink fix-dangling(~12ms) 대신 인라인 canary(~4ms)로 hot path 최적화.
        # fix-dangling과 동일 로직이지만, 매 프롬프트 fork 비용을 회피한다.
        _repair_claude_symlinks() {
          if [[ -L "$HOME/.claude/settings.json" && ! -e "$HOME/.claude/settings.json" ]]; then
            "$HOME/.local/bin/nrs-relink" restore >/dev/null 2>&1
          fi
        }
        precmd_functions+=(_repair_claude_symlinks)
      '')

      #─────────────────────────────────────────────────────────────────────────
      # fzf 키바인딩 재설정 (fzf zsh integration 로드 후 실행)
      #─────────────────────────────────────────────────────────────────────────
      (lib.mkAfter ''
        # fzf Alt+C → Ctrl+G (한글 IME 호환: Alt 조합은 한글 입력소스에서 IME가 가로챔)
        bindkey -rM emacs '\ec'
        bindkey -rM vicmd '\ec'
        bindkey -rM viins '\ec'
        bindkey -M emacs '\C-g' fzf-cd-widget
        bindkey -M vicmd '\C-g' fzf-cd-widget
        bindkey -M viins '\C-g' fzf-cd-widget
      '')

      #─────────────────────────────────────────────────────────────────────────
      # fzf-tab: Tab completion을 fzf 퍼지 검색으로 대체
      # mkAfter에서 source하여 fzf --zsh(mkOrder 910) 이후에 로드
      # → fzf_default_completion에 expand-or-complete가 정상 저장 (무한루프 방지)
      # → _ftb_orig_widget에 fzf-completion이 저장 (**<Tab> 폴백 보존)
      #─────────────────────────────────────────────────────────────────────────
      (lib.mkAfter ''
        source ${pkgs.zsh-fzf-tab}/share/fzf-tab/fzf-tab.plugin.zsh

        # === Change Intent Record ===
        # v1 (PR #188): LLM 추천으로 tab:accept 설정 — Tab 2-tap 빠른 확정 흐름
        # v2 (이번 변경): tab:accept 제거, fzf-tab 기본값 tab:down 복원
        #    독립 fzf(Ctrl+T/G)의 tab:toggle-down(PR #185)과 동작 불일치 해소.
        #    Enter가 이미 보편적 accept 키이고, 단일 결과는 팝업 없이 자동 수락됨.
        #    trade-off: Tab 2-tap 빠른 확정을 잃지만, 모든 fzf 컨텍스트에서
        #              Tab=아래이동 일관성 확보가 더 가치 있음.

        # '/'로 디렉토리 하위 연속 탐색
        zstyle ':fzf-tab:*' continuous-trigger '/'
        # F1/F2로 completion 그룹 전환
        zstyle ':fzf-tab:*' switch-group 'F1' 'F2'

        # 미리보기: 파일→bat 구문 강조, 디렉토리→eza 트리
        zstyle ':fzf-tab:complete:*' fzf-preview \
          'if [[ -d $realpath ]]; then ${lib.getExe pkgs.eza} --tree --level=2 --color=always $realpath; elif [[ -f $realpath ]]; then ${lib.getExe pkgs.bat} --color=always --style=numbers --line-range=:500 $realpath; fi'

        # git 브랜치/ref 미리보기 (커밋 로그)
        zstyle ':fzf-tab:complete:git-(checkout|switch|log):*' fzf-preview \
          'git log --oneline --graph --color=always $word -- 2>/dev/null | head -20'
        zstyle ':fzf-tab:complete:git-diff:*' fzf-preview \
          'git diff --color=always $word 2>/dev/null | head -50'
      '')

      #─────────────────────────────────────────────────────────────────────────
      # wt 래퍼 함수 (cd 서브커맨드: caller 셸 cwd 변경 필요)
      #─────────────────────────────────────────────────────────────────────────
      ''
        wt() {
          # --tmux: exec tmux를 위해 subshell 캡처 우회
          local _wt_has_tmux=false
          local _wt_arg
          for _wt_arg in "$@"; do
            [[ "$_wt_arg" == "--tmux" ]] && _wt_has_tmux=true
          done

          # tmux 밖에서만 bypass (tmux 안이면 exec tmux 불가 → 기존 cd 로직 필요)
          if [[ "$_wt_has_tmux" == "true" ]] && [[ -z "''${TMUX:-}" ]]; then
            command wt "$@"
            return $?
          fi

          if [[ "''${1:-}" == "cd" ]]; then
            shift
            local target
            target=$(command wt cd "$@") || return $?
            [[ -n "$target" ]] && cd "$target"
          else
            # stdout 캡처: tmux 밖에서 create/cd 시 경로가 출력되면 cd
            local output
            output=$(command wt "$@")
            local rc=$?
            if [[ $rc -ne 0 ]]; then
              [[ -n "$output" ]] && echo "$output"
              return $rc
            fi
            if [[ -n "$output" && -d "$output" ]]; then
              cd "$output"
            elif [[ -n "$output" ]]; then
              echo "$output"
            fi
          fi
        }
      ''

      #─────────────────────────────────────────────────────────────────────────
      # 1Password op_get helper (PRD #780)
      # op_get <name> <field> [<vault>] — vault 기본값은 constants.onePassword.vaults.automation
      # macOS는 1Password 데스크탑 biometric authorization (새 터미널마다 필요; 10분 inactivity 세션·사용 시 refresh·12시간 hard limit). MiniPC는 OP_SERVICE_ACCOUNT_TOKEN
      # (opnix가 systemd EnvironmentFile로 주입, Phase 3) 기반.
      #─────────────────────────────────────────────────────────────────────────
      ''
        op_get() {
          local name="$1"
          local field="$2"
          local vault="''${3:-${constants.onePassword.vaults.automation}}"
          if [ -z "$name" ] || [ -z "$field" ]; then
            echo "Usage: op_get <name> <field> [<vault>]" >&2
            return 2
          fi
          if ! command -v op >/dev/null 2>&1; then
            echo "Error: op CLI not found (Mac: brew install 1password-cli, MiniPC: opnix Phase 3)" >&2
            return 127
          fi
          # op read: 1Password 공식 권장 secret reference URI 방식 (단일 필드 값 조회 표준 경로).
          # password/credential 필드도 값을 그대로 반환 (item get의 기본 redact + --reveal 불필요).
          # --account: op CLI 멀티 계정(개인+회사) 환경에서 개인 account 고정 (multiple accounts 에러 방지).
          #   MiniPC는 OP_SERVICE_ACCOUNT_TOKEN이 account를 결정하므로 Phase 3에서 호환성 재확인.
          # --no-newline: 후행 개행 제거 — GH_TOKEN 등 env 주입 시 정확.
          op read --no-newline --account "${constants.onePassword.account}" "op://$vault/$name/$field"
        }
      ''

      #─────────────────────────────────────────────────────────────────────────
      # Pushover 텍스트 공유 (MiniPC -> iPhone)
      #─────────────────────────────────────────────────────────────────────────
      ''
        # push: 텍스트를 Pushover로 iPhone에 전송 (Unix-like)
        # 사용법: push <텍스트> | echo "text" | push | tmux buffer
        push() {
          local text
          if [ $# -gt 0 ]; then
            text="$*"
          elif [ ! -t 0 ]; then
            text=$(cat)
          elif [ -n "$TMUX" ]; then
            text=$(tmux save-buffer - 2>/dev/null)
          fi
          [ -z "$text" ] && { echo "Usage: push <text> or pipe input"; return 1; }

          local cred="$HOME/.config/pushover/share"
          if [ ! -f "$cred" ]; then
            echo "Error: Pushover credentials not found" >&2
            return 1
          fi
          local PUSHOVER_TOKEN="" PUSHOVER_USER=""
          source "$cred"
          [ -n "''${PUSHOVER_TOKEN:-}" ] && [ -n "''${PUSHOVER_USER:-}" ] || {
            echo "Error: Pushover credentials are incomplete" >&2
            return 1
          }

          local response
          if response=$(curl --fail-with-body --show-error --silent --max-time 10 -X POST \
            -H "Content-Type: application/x-www-form-urlencoded; charset=utf-8" \
            --data-urlencode "token=$PUSHOVER_TOKEN" \
            --data-urlencode "user=$PUSHOVER_USER" \
            --data-urlencode "title=📋 텍스트 공유 (''${#text}자)" \
            --data-urlencode "message=$text" \
            https://api.pushover.net/1/messages.json); then
            echo "✓ Pushover 전송 (''${#text}자)"
          else
            echo "Error: Pushover 전송 실패" >&2
            [ -n "$response" ] && echo "$response" >&2
            return 1
          fi
        }
      ''

      #─────────────────────────────────────────────────────────────────────────
      # 1Password Shell Plugins(op plugin init gh)의 gh alias source는 제거됨 (#872 후속, run-da F2).
      # op plugin alias("op plugin run -- gh")는 gh-auth wrapper를 덮어 non-interactive 셸에서
      # biometric 팝업을 유발했고(F2 회귀), plugins.sh 재생성 시 다시 회귀하므로 의존을 끊는다.
      # gh 무인 인증은 modules/shared/programs/shell/darwin.nix의 gh-auth wrapper가 담당한다.
      #─────────────────────────────────────────────────────────────────────────
    ];
  };

  # Starship 프롬프트
  programs.starship = {
    enable = true;
  };

  # Atuin 히스토리 (공통 설정)
  programs.atuin = {
    enable = true;
    settings = {
      auto_sync = true;
      sync_frequency = "1m";
      sync.records = true;
      network_timeout = 30;
      network_connect_timeout = 5;
      local_timeout = 5;
      style = "compact";
      inline_height = if pkgs.stdenv.isDarwin then 40 else 9;
      show_help = false;
      update_check = false;
      search_mode = "fulltext";
    };
  };

  # Zoxide (cd 대체)
  programs.zoxide = {
    enable = true;
    enableZshIntegration = true;
  };

  # FZF
  programs.fzf = {
    enable = true;
    enableZshIntegration = true;
    defaultCommand = "${lib.getExe pkgs.fd} --strip-cwd-prefix --exclude .git";
    fileWidgetCommand = "${lib.getExe pkgs.fd} --strip-cwd-prefix --exclude .git";
    changeDirWidgetCommand = "${lib.getExe pkgs.fd} --type d --strip-cwd-prefix --exclude .git";
    defaultOptions = [
      "--bind=tab:toggle-down,shift-tab:toggle-up"
    ];
    fileWidgetOptions = [
      "--preview 'if [ -d {} ]; then ${lib.getExe pkgs.eza} --tree --level=2 --color=always {}; else ${lib.getExe pkgs.bat} --color=always --style=numbers --line-range=:500 {}; fi'"
      "--preview-window=right:60%:wrap"
    ];
    changeDirWidgetOptions = [
      "--preview '${lib.getExe pkgs.eza} --tree --level=2 --color=always {}'"
      "--preview-window=right:60%:wrap"
    ];
  };
}
