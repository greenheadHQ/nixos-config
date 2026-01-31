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

    # Claude Code (권한 스킵 + MCP 설정 자동 로드)
    claude = "command claude --dangerously-skip-permissions --mcp-config ~/.claude/mcp.json";

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
      '')

      #─────────────────────────────────────────────────────────────────────────
      # Git Worktree 관리 함수
      #─────────────────────────────────────────────────────────────────────────
      ''
        #───────────────────────────────────────────────────────────────────────
        # wt: Git worktree 생성 및 관리
        # 사용법: wt [-s|--stay] <브랜치명>
        #───────────────────────────────────────────────────────────────────────
        wt() {
          local stay=false
          local branch_name=""

          # 플래그 파싱
          while [[ $# -gt 0 ]]; do
            case "$1" in
              -s|--stay)
                stay=true
                shift
                ;;
              -*)
                echo "알 수 없는 옵션: $1"
                return 1
                ;;
              *)
                branch_name="$1"
                shift
                ;;
            esac
          done

          # 부모 브랜치 미리 캡처 (worktree 생성 전에 해야 함)
          local parent_branch_for_wt
          parent_branch_for_wt=$(git branch --show-current 2>/dev/null)

          if [[ -z "$branch_name" ]]; then
            echo "사용법: wt [-s|--stay] <브랜치명>"
            echo ""
            echo "옵션:"
            echo "  -s, --stay    워크트리 생성 후 현재 디렉토리에 머무름"
            echo ""
            echo "예시:"
            echo "  wt feature-login    # 워크트리 생성 + cd 이동"
            echo "  wt -s feature-login # 워크트리 생성만 (이동 안 함)"
            echo "  wt feature/nested   # 슬래시 포함 (→ .wt/feature_nested)"
            return 1
          fi

          # 1. Git 저장소 확인
          local git_common_dir
          git_common_dir=$(git rev-parse --git-common-dir 2>/dev/null)
          if [[ $? -ne 0 || -z "$git_common_dir" ]]; then
            echo "❌ Git 저장소가 아닙니다"
            return 1
          fi

          # 2. Git 루트 계산 (워크트리 내부에서도 메인 루트 찾기)
          local git_root
          if [[ "$git_common_dir" == ".git" ]]; then
            git_root=$(pwd)
          else
            # .git/worktrees/xxx 형태 → 메인 .git 위치 계산
            git_root=$(cd "$git_common_dir" && cd ../.. && pwd)
          fi

          # 3. 워크트리 상태 확인 (브랜치 사용 여부)
          local worktree_info
          worktree_info=$(git worktree list --porcelain | awk -v branch="$branch_name" '
            /^worktree / { path = substr($0, 10) }
            /^branch refs\/heads\// {
              b = substr($0, 19)
              if (b == branch) print path
            }
          ')

          if [[ -n "$worktree_info" ]]; then
            echo "⚠️  브랜치 '$branch_name'은 이미 워크트리에서 사용 중입니다:"
            echo "    $worktree_info"
            echo ""
            echo "선택:"
            echo "  [o] 기존 워크트리 열기"
            echo "  [n] 기존 워크트리 삭제 후 새로 생성"
            echo "  [q] 취소"
            echo ""
            echo -n "선택: "
            read -r wt_choice

            case "$wt_choice" in
              o|O|"")
                if [[ "$stay" == false ]]; then
                  cd "$worktree_info" || echo "⚠️  디렉토리 이동 실패"
                fi
                _wt_open_editor "$worktree_info"
                return 0
                ;;
              n|N)
                local has_warning=false

                # 1. 커밋 체크 (.wt-parent 또는 upstream 기반)
                local parent_branch
                parent_branch=$(cat "$worktree_info/.wt-parent" 2>/dev/null)
                if [[ -n "$parent_branch" ]]; then
                  # Case A: .wt-parent 존재
                  local commit_count
                  commit_count=$(git -C "$worktree_info" rev-list --count "$parent_branch".."$branch_name" 2>/dev/null || echo "0")
                  if [[ "$commit_count" -gt 0 ]]; then
                    has_warning=true
                    echo "⚠️  '$parent_branch' 이후 ''${commit_count}개의 커밋이 있습니다:"
                    echo ""
                    git -C "$worktree_info" log --oneline "$parent_branch".."$branch_name"
                    echo ""
                  fi
                else
                  # Case B: .wt-parent 없음 → upstream 비교
                  local upstream
                  upstream=$(git -C "$worktree_info" rev-parse --abbrev-ref "$branch_name@{upstream}" 2>/dev/null)
                  if [[ -n "$upstream" ]]; then
                    local commit_count
                    commit_count=$(git -C "$worktree_info" rev-list --count "$upstream".."$branch_name" 2>/dev/null || echo "0")
                    if [[ "$commit_count" -gt 0 ]]; then
                      has_warning=true
                      echo "⚠️  '$upstream' 이후 push되지 않은 ''${commit_count}개의 커밋이 있습니다:"
                      echo ""
                      git -C "$worktree_info" log --oneline "$upstream".."$branch_name"
                      echo ""
                    fi
                  fi
                fi

                # 2. Dirty 체크
                if [[ -n $(git -C "$worktree_info" status --porcelain 2>/dev/null | grep -v '^.. \.wt-parent$') ]]; then
                  has_warning=true
                  echo "⚠️  커밋되지 않은 변경사항이 있습니다:"
                  echo ""
                  git -C "$worktree_info" status --short
                  echo ""
                  git -C "$worktree_info" diff --stat
                  echo ""
                fi

                # 3. 확인 프롬프트 (둘 중 하나라도 있으면)
                if [[ "$has_warning" == true ]]; then
                  echo -n "정말 삭제하시겠습니까? [y/N]: "
                  read -r confirm
                  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                    echo "취소되었습니다."
                    return 1
                  fi
                fi

                # Worktree 삭제
                git worktree remove "$worktree_info" --force || {
                  echo "❌ 기존 워크트리 삭제 실패"
                  return 1
                }
                echo "🗑️  기존 워크트리 삭제됨: $worktree_info"

                # 브랜치 삭제
                git branch -D "$branch_name" || {
                  echo "❌ 기존 브랜치 삭제 실패"
                  return 1
                }
                echo "🗑️  기존 브랜치 '$branch_name' 삭제됨"
                # 아래 로직에서 새 워크트리 생성 진행
                ;;
              q|Q|*)
                echo "취소되었습니다."
                return 1
                ;;
            esac
          fi

          # 4. 디렉토리명 생성 (슬래시 → 언더스코어)
          local dir_name="''${branch_name//\//_}"
          local worktree_dir="$git_root/.wt/$dir_name"

          # 디렉토리 충돌 확인 및 해결
          local suffix=1
          while [[ -d "$worktree_dir" ]]; do
            ((suffix++))
            if [[ $suffix -gt 99 ]]; then
              echo "❌ 디렉토리명 충돌 해결 실패 (최대 시도 횟수 초과)"
              return 1
            fi
            worktree_dir="$git_root/.wt/''${dir_name}-''${suffix}"
          done

          # .wt 디렉토리 생성
          if [[ ! -d "$git_root/.wt" ]]; then
            mkdir -p "$git_root/.wt" || {
              echo "❌ .wt 디렉토리 생성 실패: 권한을 확인하세요"
              return 1
            }
          fi

          # 5. 브랜치 존재 여부 확인
          local local_exists=false
          local remote_exists=false
          local remote_ref=""

          if git show-ref --verify --quiet "refs/heads/$branch_name" 2>/dev/null; then
            local_exists=true
          fi

          # 원격 브랜치 확인 (fetch 없이 로컬 캐시만)
          remote_ref=$(git for-each-ref --format='%(refname:short)' "refs/remotes/*/$branch_name" | head -1)
          if [[ -n "$remote_ref" ]]; then
            remote_exists=true
          fi

          if [[ "$local_exists" == true || "$remote_exists" == true ]]; then
            echo "⚠️  브랜치 '$branch_name'이 이미 존재합니다:"
            [[ "$local_exists" == true ]] && echo "    📍 로컬"
            [[ "$remote_exists" == true ]] && echo "    🌐 원격: $remote_ref"
            echo ""
            echo "선택:"
            echo "  [c] 기존 브랜치로 워크트리 생성"
            echo "  [n] 기존 브랜치 삭제 후 새로 생성 (현재 HEAD 기준)"
            echo "  [q] 취소"
            echo ""
            echo -n "선택: "
            read -r branch_choice

            case "$branch_choice" in
              c|C)
                if [[ "$local_exists" == true ]]; then
                  git worktree add "$worktree_dir" "$branch_name" || {
                    echo "❌ 워크트리 생성 실패"
                    return 1
                  }
                else
                  # 원격만 존재: 트래킹 브랜치 생성
                  git worktree add -b "$branch_name" "$worktree_dir" "$remote_ref" || {
                    echo "❌ 워크트리 생성 실패"
                    return 1
                  }
                fi
                # 부모 브랜치 기록
                if [[ -n "$parent_branch_for_wt" ]]; then
                  echo "$parent_branch_for_wt" > "$worktree_dir/.wt-parent"
                fi
                ;;
              n|N)
                # 1. 해당 브랜치를 사용하는 기존 worktree 확인
                local existing_worktree
                existing_worktree=$(git worktree list --porcelain | awk -v branch="$branch_name" '
                  /^worktree / { path = substr($0, 10) }
                  /^branch refs\/heads\// {
                    b = substr($0, 19)
                    if (b == branch) print path
                  }
                ')

                local has_warning=false

                if [[ -n "$existing_worktree" ]]; then
                  # Case A: worktree 존재 → .wt-parent 기반 커밋 체크

                  # 커밋 체크
                  local parent_branch
                  parent_branch=$(cat "$existing_worktree/.wt-parent" 2>/dev/null)
                  if [[ -n "$parent_branch" ]]; then
                    local commit_count
                    commit_count=$(git -C "$existing_worktree" rev-list --count "$parent_branch".."$branch_name" 2>/dev/null || echo "0")
                    if [[ "$commit_count" -gt 0 ]]; then
                      has_warning=true
                      echo "⚠️  '$parent_branch' 이후 ''${commit_count}개의 커밋이 있습니다:"
                      echo ""
                      git -C "$existing_worktree" log --oneline "$parent_branch".."$branch_name"
                      echo ""
                    fi
                  fi

                  # Dirty 체크
                  if [[ -n $(git -C "$existing_worktree" status --porcelain 2>/dev/null | grep -v '^.. \.wt-parent$') ]]; then
                    has_warning=true
                    echo "⚠️  커밋되지 않은 변경사항이 있습니다:"
                    echo ""
                    git -C "$existing_worktree" status --short
                    echo ""
                    git -C "$existing_worktree" diff --stat
                    echo ""
                  fi
                else
                  # Case B: worktree 없이 브랜치만 존재 → upstream 비교
                  local upstream
                  upstream=$(git rev-parse --abbrev-ref "$branch_name@{upstream}" 2>/dev/null)
                  if [[ -n "$upstream" ]]; then
                    local commit_count
                    commit_count=$(git rev-list --count "$upstream".."$branch_name" 2>/dev/null || echo "0")
                    if [[ "$commit_count" -gt 0 ]]; then
                      has_warning=true
                      echo "⚠️  '$upstream' 이후 push되지 않은 ''${commit_count}개의 커밋이 있습니다:"
                      echo ""
                      git log --oneline "$upstream".."$branch_name"
                      echo ""
                    fi
                  fi
                fi

                # 확인 프롬프트
                if [[ "$has_warning" == true ]]; then
                  echo -n "정말 삭제하시겠습니까? [y/N]: "
                  read -r confirm
                  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                    echo "취소되었습니다."
                    return 1
                  fi
                fi

                # worktree 삭제 (있는 경우만)
                if [[ -n "$existing_worktree" ]]; then
                  git worktree remove "$existing_worktree" --force || {
                    echo "❌ 기존 워크트리 삭제 실패"
                    return 1
                  }
                  echo "🗑️  기존 워크트리 삭제됨: $existing_worktree"
                fi

                # 기존 로컬 브랜치 삭제 후 같은 이름으로 새로 생성
                if [[ "$local_exists" == true ]]; then
                  git branch -D "$branch_name" || {
                    echo "❌ 기존 브랜치 삭제 실패"
                    return 1
                  }
                  echo "🗑️  기존 브랜치 '$branch_name' 삭제됨"
                fi
                git worktree add -b "$branch_name" "$worktree_dir" || {
                  echo "❌ 워크트리 생성 실패"
                  return 1
                }
                # 부모 브랜치 기록
                if [[ -n "$parent_branch_for_wt" ]]; then
                  echo "$parent_branch_for_wt" > "$worktree_dir/.wt-parent"
                fi
                ;;
              q|Q|*)
                echo "취소되었습니다."
                return 1
                ;;
            esac
          else
            # 브랜치가 존재하지 않음: 새로 생성
            git worktree add -b "$branch_name" "$worktree_dir" || {
              echo "❌ 워크트리 생성 실패"
              return 1
            }
            # 부모 브랜치 기록
            if [[ -n "$parent_branch_for_wt" ]]; then
              echo "$parent_branch_for_wt" > "$worktree_dir/.wt-parent"
            fi
          fi

          echo "✅ 워크트리 생성 완료: $worktree_dir"
          if [[ "$stay" == false ]]; then
            cd "$worktree_dir" || echo "⚠️  디렉토리 이동 실패"
          fi
          _wt_open_editor "$worktree_dir"
        }

        #───────────────────────────────────────────────────────────────────────
        # wt 헬퍼: 에디터 열기 (플랫폼별)
        #───────────────────────────────────────────────────────────────────────
        _wt_open_editor() {
          local target_dir="$1"

          if [[ "$(uname)" == "Darwin" ]]; then
            # macOS: 에디터 실행
            local editor="''${WT_EDITOR:-cursor}"
            if command -v "$editor" &>/dev/null; then
              "$editor" "$target_dir"
            else
              echo "⚠️  에디터 실행 실패: $editor"
              echo "📁 워크트리 경로: $target_dir"
            fi
          else
            # NixOS/Linux: 경로만 출력
            echo "📁 워크트리 경로: $target_dir"
          fi
        }

        #───────────────────────────────────────────────────────────────────────
        # wt-cleanup: Git worktree 정리
        # 사용법: wt-cleanup
        #───────────────────────────────────────────────────────────────────────
        wt-cleanup() {
          # 1. Git 저장소 확인 및 루트 계산
          local git_common_dir
          git_common_dir=$(git rev-parse --git-common-dir 2>/dev/null)
          if [[ $? -ne 0 || -z "$git_common_dir" ]]; then
            echo "❌ Git 저장소가 아닙니다"
            return 1
          fi

          local git_root
          if [[ "$git_common_dir" == ".git" ]]; then
            git_root=$(pwd)
          else
            git_root=$(cd "$git_common_dir" && cd ../.. && pwd)
          fi

          # 2. .wt/ 디렉토리 존재 확인
          if [[ ! -d "$git_root/.wt" ]]; then
            echo "📁 .wt 디렉토리가 없습니다"
            return 0
          fi

          # 3. 워크트리 목록 수집 (.wt/ 내부만)
          local -a worktree_paths=()
          local -a worktree_branches=()

          while IFS= read -r line; do
            if [[ "$line" =~ ^worktree\ (.+) ]]; then
              local wt_path="''${match[1]:-''${BASH_REMATCH[1]}}"
              if [[ "$wt_path" == "$git_root/.wt/"* ]]; then
                worktree_paths+=("$wt_path")
              fi
            elif [[ "$line" =~ ^branch\ refs/heads/(.+) ]]; then
              local branch="''${match[1]:-''${BASH_REMATCH[1]}}"
              if [[ ''${#worktree_paths[@]} -gt ''${#worktree_branches[@]} ]]; then
                worktree_branches+=("$branch")
              fi
            fi
          done < <(git worktree list --porcelain)

          if [[ ''${#worktree_paths[@]} -eq 0 ]]; then
            echo "✨ 정리할 워크트리가 없습니다"
            return 0
          fi

          echo ""
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          echo "🧹 Worktree Cleanup - 상태 확인 중..."
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          echo ""

          # 4. 워크트리별 상태 수집
          local -a dirty_status=()
          local -a pr_status=()
          local gh_available=false
          local offline_mode=false

          # gh CLI 확인
          if command -v gh &>/dev/null; then
            if gh auth status &>/dev/null; then
              gh_available=true
            else
              echo "⚠️  gh auth login 필요 - 오프라인 모드로 진행"
              offline_mode=true
            fi
          fi

          # 임시 디렉토리 생성 (병렬 PR 조회용)
          local tmp_dir=$(mktemp -d)
          trap "rm -rf $tmp_dir" EXIT INT TERM HUP

          # 4a. Dirty 상태 확인 + 4b. PR 상태 조회 (병렬)
          # job control 메시지 숨기기 (zsh)
          {
            setopt local_options no_monitor no_notify 2>/dev/null || true
            for i in {1..''${#worktree_paths[@]}}; do
              local wt_path="''${worktree_paths[$i]}"
              local branch="''${worktree_branches[$i]}"

              # Dirty 체크
              if [[ -n $(git -C "$wt_path" status --porcelain 2>/dev/null | grep -v '^.. \.wt-parent$') ]]; then
                dirty_status[$i]="DIRTY"
              else
                dirty_status[$i]=""
              fi

              # PR 상태 조회 (백그라운드)
              if [[ "$gh_available" == true ]]; then
                (gh pr list --head "$branch" --json state -q '.[0].state // "NONE"' > "$tmp_dir/$i" 2>/dev/null) &
              else
                echo "OFFLINE" > "$tmp_dir/$i"
              fi
            done
            wait
          }

          # PR 결과 수집
          for i in {1..''${#worktree_paths[@]}}; do
            pr_status[$i]=$(cat "$tmp_dir/$i" 2>/dev/null || echo "OFFLINE")
          done

          # 5. fzf 입력 데이터 준비
          local -a fzf_lines=()
          for i in {1..''${#worktree_paths[@]}}; do
            local wt_path="''${worktree_paths[$i]}"
            local branch="''${worktree_branches[$i]}"
            local pr="''${pr_status[$i]}"
            local dirty="''${dirty_status[$i]}"
            local wt_name=$(basename "$wt_path")

            # 상태 아이콘
            local icon=""
            case "$pr" in
              MERGED)  icon="✅" ;;
              OPEN)    icon="🔵" ;;
              CLOSED)  icon="🚫" ;;
              OFFLINE) icon="📵" ;;
              NONE|*)  icon="⚪" ;;
            esac

            # Dirty 표시
            local dirty_mark=""
            [[ -n "$dirty" ]] && dirty_mark=" 💾"

            # fzf 라인: "STATUS|PATH|BRANCH|DISPLAY"
            fzf_lines+=("$pr|$wt_path|$branch|$icon $wt_name ($branch)$dirty_mark")
          done

          # 6. 다중 선택 UI
          local -a selected_items=()

          if command -v fzf &>/dev/null; then
            # fzf 사용
            local fzf_input=""
            for line in "''${fzf_lines[@]}"; do
              fzf_input+="$line"$'\n'
            done

            local selected
            selected=$(echo -n "$fzf_input" | fzf --multi --ansi \
              --delimiter='|' \
              --with-nth=4 \
              --preview='echo {} | cut -d"|" -f2 | xargs -I{} git -C {} log --oneline -5 2>/dev/null || echo "로그 없음"' \
              --preview-window=right:50% \
              --header="TAB: 다중 선택 / Enter: 확인 / ESC: 취소" \
              --bind='ctrl-a:select-all')

            if [[ -z "$selected" ]]; then
              echo "취소되었습니다."
              return 0
            fi

            while IFS= read -r line; do
              selected_items+=("$line")
            done <<< "$selected"
          else
            # fzf 없음: 번호 선택
            echo "워크트리 목록:"
            for i in {1..''${#fzf_lines[@]}}; do
              local display=$(echo "''${fzf_lines[$i]}" | cut -d'|' -f4)
              echo "  [$i] $display"
            done
            echo ""
            echo "삭제할 번호를 입력하세요 (예: 1,3,5 또는 'a' 전체):"
            echo -n "> "
            read -r selection

            if [[ "$selection" == "a" || "$selection" == "A" ]]; then
              selected_items=("''${fzf_lines[@]}")
            elif [[ -n "$selection" ]]; then
              IFS=',' read -rA nums <<< "$selection"
              for num in "''${nums[@]}"; do
                num=$(echo "$num" | tr -d ' ')
                if [[ "$num" =~ ^[0-9]+$ ]] && [[ $num -ge 1 ]] && [[ $num -le ''${#fzf_lines[@]} ]]; then
                  selected_items+=("''${fzf_lines[$num]}")
                fi
              done
            fi
          fi

          if [[ ''${#selected_items[@]} -eq 0 ]]; then
            echo "선택된 항목이 없습니다."
            return 0
          fi

          # 7. 선택된 항목 삭제
          local deleted=0
          for item in "''${selected_items[@]}"; do
            local wt_path=$(echo "$item" | cut -d'|' -f2)
            local branch=$(echo "$item" | cut -d'|' -f3)
            local wt_name=$(basename "$wt_path")

            local has_warning=false

            # 커밋 체크 (.wt-parent 또는 upstream 기반)
            local parent_branch
            parent_branch=$(cat "$wt_path/.wt-parent" 2>/dev/null)
            if [[ -n "$parent_branch" ]]; then
              # Case A: .wt-parent 존재
              local commit_count
              commit_count=$(git -C "$wt_path" rev-list --count "$parent_branch".."$branch" 2>/dev/null || echo "0")
              if [[ "$commit_count" -gt 0 ]]; then
                has_warning=true
                echo ""
                echo "⚠️  '$wt_name' ($branch): '$parent_branch' 이후 ''${commit_count}개의 커밋이 있습니다:"
                echo ""
                git -C "$wt_path" log --oneline "$parent_branch".."$branch"
              fi
            else
              # Case B: .wt-parent 없음 → upstream 비교
              local upstream
              upstream=$(git -C "$wt_path" rev-parse --abbrev-ref "$branch@{upstream}" 2>/dev/null)
              if [[ -n "$upstream" ]]; then
                local commit_count
                commit_count=$(git -C "$wt_path" rev-list --count "$upstream".."$branch" 2>/dev/null || echo "0")
                if [[ "$commit_count" -gt 0 ]]; then
                  has_warning=true
                  echo ""
                  echo "⚠️  '$wt_name' ($branch): '$upstream' 이후 push되지 않은 ''${commit_count}개의 커밋이 있습니다:"
                  echo ""
                  git -C "$wt_path" log --oneline "$upstream".."$branch"
                fi
              fi
            fi

            # Dirty 체크
            if [[ -n $(git -C "$wt_path" status --porcelain 2>/dev/null | grep -v '^.. \.wt-parent$') ]]; then
              has_warning=true
              echo ""
              echo "⚠️  '$wt_name' ($branch)에 커밋되지 않은 변경사항이 있습니다:"
              echo ""
              git -C "$wt_path" diff --stat 2>/dev/null
            fi

            # 확인 프롬프트
            if [[ "$has_warning" == true ]]; then
              echo ""
              echo -n "삭제할까요? [y/N]: "
              read -r confirm
              if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                echo "   ⏭️  건너뜀"
                continue
              fi
            fi

            echo "🗑️  $wt_name 삭제 중..."

            # 워크트리 제거
            if git worktree remove "$wt_path" --force 2>/dev/null; then
              echo "   └─ 워크트리 제거 완료"
            else
              echo "   └─ ⚠️  워크트리 제거 실패"
              continue
            fi

            # 로컬 브랜치 삭제
            if git branch -D "$branch" 2>/dev/null; then
              echo "   └─ 브랜치 '$branch' 삭제 완료"
            else
              echo "   └─ ⚠️  브랜치 삭제 실패 (이미 삭제됨?)"
            fi

            ((deleted++))
          done

          # prune 실행
          git worktree prune 2>/dev/null

          echo ""
          echo "✅ ''${deleted}개의 워크트리가 삭제되었습니다."
        }
      ''

      #─────────────────────────────────────────────────────────────────────────
      # Git Diff → fzf → Neovim
      #─────────────────────────────────────────────────────────────────────────
      ''
        # ved: git diff 파일을 fzf로 선택하여 nvim으로 열기
        # 사용법: ved [git diff 옵션]
        #   ved              # 워킹 트리 변경 파일
        #   ved --cached     # 스테이징된 파일
        #   ved HEAD~3       # 최근 3커밋 변경 파일
        ved() {
          if ! git rev-parse --is-inside-work-tree &>/dev/null; then
            echo "Git 저장소가 아닙니다" >&2
            return 1
          fi

          local files
          files=$(git diff --name-only "$@" 2>/dev/null)

          if [[ -z "$files" ]]; then
            echo "변경된 파일이 없습니다"
            return 0
          fi

          local selected
          selected=$(echo "$files" | fzf --multi \
            --preview "git diff $* -- {} 2>/dev/null | head -200" \
            --preview-window=right:60% \
            --header="TAB: 다중 선택 / Enter: nvim으로 열기")

          [[ -n "$selected" ]] && echo "$selected" | xargs nvim
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
