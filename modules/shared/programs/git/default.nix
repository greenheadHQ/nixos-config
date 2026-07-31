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

      # Claude Code (settings.local.json과 런타임 아티팩트만 무시, 나머지는 프로젝트별 커밋 가능)
      "**/.claude/settings.local.json"
      "**/.claude/plans"
      "**/.claude/worktrees"
      "CLAUDE.local.md"
      "CLAUDE.local.*.md"

      # wt 워크트리 관리
      ".wt-parent"
      ".wt-last"
      ".agents/skills/wt-plugin--*"

      # mise (프로젝트별 로컬 설정, dotfile 버전 포함)
      "mise.local.toml"
      ".mise.local.toml"

      # Codex CLI: .codex/config.toml은 MCP env 시크릿을 평문 담을 수 있어 글로벌 무시 유지.
      # .agents/·AGENTS.md·AGENTS.override.md는 Codex 자동발견용으로 커밋이 기본이라 무시하지 않는다.
      ".codex/"

      # Python
      "__pycache__/"
    ];
  };

  # GitHub CLI
  programs.gh = {
    enable = true;
    # 동반 선언: Home Manager linkFarm이 extensions 디렉터리 전체를 소유하므로
    # 모든 확장을 이 리스트에 함께 선언한다. 첫 activation 시 기존 명령형 설치
    # 디렉터리는 CLAUDE.md의 macOS 충돌 정책대로 timestamped backup으로 이동된다
    # — 모든 확장이 아래 선언에 있으므로 기능 손실 없음.
    # gh-stack은 전 플랫폼 공용(linux asset은 static Go 바이너리 실측).
    # gh-attach·gh-difftool은 쿠키 전제(브라우저 + Keychain)가 macOS 데스크톱
    # 전용이라 NixOS(MiniPC)는 제외한다.
    extensions = [
      (import ./gh-stack-package.nix { inherit pkgs; })
    ]
    ++ lib.optionals pkgs.stdenv.isDarwin [
      (import ./gh-attach-package.nix { inherit pkgs; })
      (import ./gh-difftool-package.nix { inherit pkgs; })
    ];
    settings = {
      # GitHub 인증 프로토콜. Mac은 https(아래 darwin 전용 git insteadOf + gh PAT
      # credential helper로 통일), NixOS(MiniPC)는 opnix/ssh 경로라 기존 ssh 유지.
      git_protocol = if pkgs.stdenv.isDarwin then "https" else "ssh";
    };
  };

  # Mac 전용 GitHub git 인증: git@github.com SSH URL을 https로 rewrite한다.
  # rewrite된 https remote는 gh credential helper(gh auth git-credential —
  # programs.gh.enable이 자동 주입)로 인증된다. 이 helper는 별도 gh 프로세스로 실행돼
  # shell의 gh wrapper(alias/함수)를 거치지 않으며, keyring의 PAT(gh auth login) 또는
  # git 프로세스 환경에 export된 GH_TOKEN으로 토큰을 조회한다 — git이 GH_TOKEN을 직접
  # 읽는 것이 아니다. SSH 키 등록 불필요.
  # NixOS(MiniPC)는 opnix github-pat + 기존 ssh 경로라 제외(darwin 한정 — git
  # credential helper에 토큰 공급원이 다름).
  programs.git.settings.url = lib.mkIf pkgs.stdenv.isDarwin {
    "https://github.com/".insteadOf = "git@github.com:";
  };
}
