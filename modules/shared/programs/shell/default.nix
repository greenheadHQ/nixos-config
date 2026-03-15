# Shell 설정 - 공통 부분
{
  config,
  pkgs,
  lib,
  nixosConfigDefaultPath,
  ...
}:

let
  sharedScriptsDir = ../../scripts;
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
  # PATH 추가 (공통)
  home.sessionPath = [
    "$HOME/.local/bin"
  ];

  # recall resume 시 dangerously-skip-permissions 활성화
  # shell alias 'c'와 동일 플래그 — recall은 exec()로 직접 실행하므로 alias 무시됨
  home.sessionVariables = {
    RECALL_CLAUDE_CMD = "claude --dangerously-skip-permissions --mcp-config $HOME/.claude/mcp.json --resume {id}";
  };

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
    codex = "command codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen";

    # lazygit 단축
    lg = "lazygit";

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

    # .zshenv: SSH 비대화형 세션을 위한 mise shims PATH 추가
    # (대화형 훅은 .zshrc에서 활성화)
    envExtra = ''
      if command -v mise >/dev/null 2>&1 && [[ -z "$MISE_SHELL" ]]; then
        eval "$(mise activate zsh --shims)"
      fi

      # 비대화형 셸 기본값: side-by-side 비활성화
      # (대화형 셸에서는 .zshrc의 precmd 훅이 터미널 너비에 따라 동적 제어)
      export DELTA_FEATURES=""
    '';

    # 공통 초기화 스크립트 (.zshrc)
    initContent = lib.mkMerge [
      (lib.mkBefore ''
        # Mise 활성화 (대화형 셸: cd 시 자동 버전 전환 등)
        if command -v mise >/dev/null 2>&1; then
          eval "$(mise activate zsh)"
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

          local cred="$HOME/.config/pushover/claude-code"
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
