# Git 설정
{
  config,
  pkgs,
  lib,
  ...
}:

let
  # Rebase 역순 표시 스크립트
  rebaseReverseEditor = pkgs.writeShellScript "git-rebase-reverse-editor" ''
    set -euo pipefail

    TODO_FILE="$1"
    TEMP_FILE=$(mktemp)
    trap 'rm -f "$TEMP_FILE"' EXIT

    COMMAND_PATTERN='^(p|pick|r|reword|e|edit|s|squash|f|fixup|x|exec|b|break|d|drop|l|label|t|reset|m|merge)[[:space:]]'

    # 커밋 라인과 나머지(주석/빈줄) 분리
    COMMITS=()
    OTHERS=()
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ $COMMAND_PATTERN ]]; then
        COMMITS+=("$line")
      else
        OTHERS+=("$line")
      fi
    done < "$TODO_FILE"

    # 역순 정렬하여 표시 (최신 커밋이 위로)
    {
      for ((i=''${#COMMITS[@]}-1; i>=0; i--)); do
        printf '%s\n' "''${COMMITS[i]}"
      done
      printf '%s\n' "''${OTHERS[@]}"
    } > "$TODO_FILE"

    # 에디터 실행
    "''${EDITOR:-${pkgs.neovim}/bin/nvim}" "$TODO_FILE"
    EDITOR_EXIT=$?

    # 에디터가 실패하면 즉시 종료 (rebase 취소)
    if [[ $EDITOR_EXIT -ne 0 ]]; then
      exit $EDITOR_EXIT
    fi

    # 편집 후 다시 역순으로 복원 (= 원래 순서)
    EDITED_COMMITS=()
    EDITED_OTHERS=()
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ $COMMAND_PATTERN ]]; then
        EDITED_COMMITS+=("$line")
      else
        EDITED_OTHERS+=("$line")
      fi
    done < "$TODO_FILE"

    # 복원 로직 - 쓰기 실패 시 에러 처리
    if {
      for ((i=''${#EDITED_COMMITS[@]}-1; i>=0; i--)); do
        printf '%s\n' "''${EDITED_COMMITS[i]}"
      done
      printf '%s\n' "''${EDITED_OTHERS[@]}"
    } > "$TODO_FILE"; then
      exit 0
    else
      echo "Error: Failed to restore rebase order." >&2
      exit 1
    fi
  '';
in
{
  # Delta (git diff 시각화)
  programs.delta = {
    enable = true;
    enableGitIntegration = true;
    options = {
      dark = true;
      line-numbers = true;
      # --mouse: 마우스 휠/터치 스크롤 활성화 (trade-off: less 내 텍스트 선택 불가)
      # -e: 끝까지 스크롤 후 한 번 더 스크롤하면 자동 종료 (q 불필요)
      pager = "less -e --mouse";
      # navigate와 side-by-side는 interactive feature로 분리
      # (lazygit에서 비활성화하기 위해 — lazygit diff 패널이 좁아서 side-by-side 부적합)
      features = "interactive";
    };
  };

  # 터미널 git diff 전용: side-by-side와 navigate 활성화
  programs.git.settings."delta \"interactive\"" = {
    side-by-side = true;
    navigate = true;
  };

  programs.git = {
    enable = true;

    settings = {
      user = {
        name = "greenhead";
        email = "shren0812@gmail.com";
      };

      alias = {
        s = "status -s";
        l = "log --color --graph --decorate --date=format:'%Y-%m-%d' --abbrev-commit --pretty=format:'%C(red)%h%C(auto)%d %s %C(green)(%cr)%C(bold blue) %an'";
      };

      http.postBuffer = 157286400;
      branch.sort = "committerdate";
      init.defaultBranch = "main";
      push.autoSetupRemote = true;
      pull.rebase = true;
      merge.conflictStyle = "zdiff3";

      # Rerere (REuse REcorded REsolution)
      # 병합 충돌 해결을 자동화하는 기능
      #
      # 역할:
      #   - 수동으로 해결한 충돌 패턴을 기록
      #   - 동일한 충돌 발생 시 자동으로 이전 해결책 적용
      #   - 반복적인 rebase/merge 작업에서 유용
      #
      # 관련 명령어:
      #   - git rerere status    : 현재 기록된 충돌 상태 확인
      #   - git rerere diff      : 기록된 해결책과 현재 상태 비교
      #   - git rerere remaining : 아직 해결되지 않은 충돌 목록
      #   - git rerere gc        : 오래된 기록 정리
      #
      # 기록 초기화:
      #   - 전체 초기화: rm -rf .git/rr-cache
      #   - 특정 항목 제거: rm -rf .git/rr-cache/<conflict-id>
      rerere.enabled = true;

      # Rebase 역순 표시 설정
      sequence.editor = "${rebaseReverseEditor}";
    };

    ignores = [
      # macOS
      ".DS_Store"

      # IDE
      ".idea"
      ".cursorrules"
      ".cursor"

      # Claude Code (settings.local.json만 무시, 나머지는 프로젝트별 커밋 가능)
      "**/.claude/settings.local.json"
      "**/.claude/plans"
      "CLAUDE.local.md"
      "CLAUDE.local.*.md"

      # mise (프로젝트별 로컬 설정, dotfile 버전 포함)
      "mise.local.toml"
      ".mise.local.toml"

      # Codex CLI (syncing-codex-harness 프로젝션 산출물)
      ".agents/"
      ".codex/"
      "AGENTS.md"
      "AGENTS.override.md"

      # Python
      "__pycache__/"

      # wt worktree 디렉토리 및 메타데이터
      ".wt/"
      ".wt-parent"
    ];
  };

  # GitHub CLI
  programs.gh = {
    enable = true;
    settings = {
      git_protocol = "ssh";
    };
  };
}
