# Shell 설정 - 공통 부분
{
  config,
  pkgs,
  lib,
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

  # Shell 함수 라이브러리 (source로 로딩)
  home.file.".local/lib/git-worktree-functions.sh" = {
    source = "${sharedScriptsDir}/git-worktree-functions.sh";
  };
  home.file.".local/lib/git-diff-fzf-functions.sh" = {
    source = "${sharedScriptsDir}/git-diff-fzf-functions.sh";
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

    # Claude Code (macOS에서만 Claude in Chrome 활성화 + 권한 스킵 + MCP 설정 자동 로드)
    c = "command claude${
      if pkgs.stdenv.isDarwin then " --chrome" else ""
    } --dangerously-skip-permissions --mcp-config ~/.claude/mcp.json";

    # Codex CLI 위험 모드 단축 (사용자 요청)
    codex = "command codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen";

    # lazygit 단축
    lg = "lazygit";

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
      # Shell 함수 라이브러리 로딩
      #─────────────────────────────────────────────────────────────────────────
      ''
        # Git Worktree 관리 함수 (wt, wt-cleanup, _wt_open_editor)
        source "$HOME/.local/lib/git-worktree-functions.sh"

        # Git Diff → fzf → Neovim (gdf, gdl)
        source "$HOME/.local/lib/git-diff-fzf-functions.sh"
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
          source "$cred"
          curl -s -X POST \
            -H "Content-Type: application/x-www-form-urlencoded; charset=utf-8" \
            --data-urlencode "token=$PUSHOVER_TOKEN" \
            --data-urlencode "user=$PUSHOVER_USER" \
            --data-urlencode "title=📋 텍스트 공유 (''${#text}자)" \
            --data-urlencode "message=$text" \
            https://api.pushover.net/1/messages.json > /dev/null
          echo "✓ Pushover 전송 (''${#text}자)"
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
      inline_height = 9;
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
  };
}
