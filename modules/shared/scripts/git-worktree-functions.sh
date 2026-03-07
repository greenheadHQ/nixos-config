#!/usr/bin/env zsh
# Git Worktree 관리 함수
# shell/default.nix에서 source로 로딩됨 (cd 사용을 위해 함수로 유지)
# shellcheck shell=bash  # zsh 호환 코드이나 bash 수준 검증

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

  # [n] 재생성 시 pane 변수 보존용 (window kill → 새 window에 복원)
  local _saved_note_path=""

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

  # 현재 작업 트리 루트 (워크트리 내부에서 실행 시 해당 워크트리 루트)
  local source_root
  source_root=$(git rev-parse --show-toplevel 2>/dev/null)

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
        _wt_tmux_open "$branch_name" "$worktree_info" "$stay"
        # tmux 외부 fallback: stay=false일 때만 cd
        if [[ -z "${TMUX:-}" && "$stay" == false ]]; then
          cd "$worktree_info" || echo "⚠️  디렉토리 이동 실패"
        fi
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
            echo "⚠️  '$parent_branch' 이후 ${commit_count}개의 커밋이 있습니다:"
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
              echo "⚠️  '$upstream' 이후 push되지 않은 ${commit_count}개의 커밋이 있습니다:"
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

        # Pane 변수 보존 (window kill 전)
        if [[ -n "${TMUX:-}" ]]; then
          local _old_win
          _old_win=$(_wt_find_tmux_window "$branch_name" "$worktree_info")
          if [[ -n "$_old_win" ]]; then
            _saved_note_path=$(tmux display-message -t ":$_old_win" -p '#{@pane_note_path}' 2>/dev/null || true)
          fi
        fi
        _wt_tmux_close "$branch_name" "$worktree_info"

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
  local dir_name="${branch_name//\//_}"
  local worktree_dir="$git_root/.wt/$dir_name"

  # 디렉토리 충돌 확인 및 해결
  local suffix=1
  while [[ -d "$worktree_dir" ]]; do
    ((suffix++))
    if [[ $suffix -gt 99 ]]; then
      echo "❌ 디렉토리명 충돌 해결 실패 (최대 시도 횟수 초과)"
      return 1
    fi
    worktree_dir="$git_root/.wt/${dir_name}-${suffix}"
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
              echo "⚠️  '$parent_branch' 이후 ${commit_count}개의 커밋이 있습니다:"
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
              echo "⚠️  '$upstream' 이후 push되지 않은 ${commit_count}개의 커밋이 있습니다:"
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
          # Pane 변수 보존 + tmux window 닫기 (worktree 삭제 전)
          if [[ -n "${TMUX:-}" ]]; then
            local _old_win
            _old_win=$(_wt_find_tmux_window "$branch_name" "$existing_worktree")
            if [[ -n "$_old_win" ]]; then
              _saved_note_path=$(tmux display-message -t ":$_old_win" -p '#{@pane_note_path}' 2>/dev/null || true)
            fi
          fi
          _wt_tmux_close "$branch_name" "$existing_worktree"

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

  # 워크트리 bootstrap: 비추적 로컬 산출물만 최소 복사
  # - .claude, .agents는 git-tracked이므로 전체 디렉토리 재복사 금지
  #   (중첩 디렉토리 .claude/.claude, .agents/.agents 회귀 방지)
  # - .codex는 비추적 산출물이라 대상에 없을 때만 복사
  if [[ -d "$source_root/.codex" ]] && [[ ! -e "$worktree_dir/.codex" ]]; then
    cp -R "$source_root/.codex" "$worktree_dir/.codex"
  fi

  # 로컬 Claude 설정은 파일 단위로만 전달 (디렉토리 재귀 복사 금지)
  if [[ -f "$source_root/.claude/settings.local.json" ]] && [[ ! -e "$worktree_dir/.claude/settings.local.json" ]]; then
    mkdir -p "$worktree_dir/.claude"
    cp "$source_root/.claude/settings.local.json" "$worktree_dir/.claude/settings.local.json"
  fi

  # .claude/plans/는 세션별 데이터이므로 워크트리 생성 시 제거
  rm -rf "$worktree_dir/.claude/plans"

  # 회귀 가드: 중첩 디렉토리가 감지되면 즉시 실패 처리
  for _dir in .claude .agents .codex; do
    if [[ -d "$worktree_dir/$_dir/$_dir" ]]; then
      echo "❌ 워크트리 bootstrap 회귀 감지: $worktree_dir/$_dir/$_dir"
      echo "   원인 후보: 디렉토리 재귀 복사. 정리 후 wt 로직을 점검하세요."
      return 1
    fi
  done

  echo "✅ 워크트리 생성 완료: $worktree_dir"
  _wt_tmux_open "$branch_name" "$worktree_dir" "$stay"
  local tmux_result=$?
  # tmux 외부이거나 tmux window 생성 실패 시 cd fallback
  if [[ (-z "${TMUX:-}" || $tmux_result -ne 0) && "$stay" == false ]]; then
    cd "$worktree_dir" || echo "⚠️  디렉토리 이동 실패"
  fi
  # 보존된 pane 변수 복원 (재생성 시)
  if [[ -n "${TMUX:-}" && -n "$_saved_note_path" ]]; then
    local _new_win
    _new_win=$(_wt_find_tmux_window "$branch_name" "$worktree_dir")
    if [[ -n "$_new_win" ]]; then
      tmux set-option -t ":$_new_win" -p @pane_note_path "$_saved_note_path" 2>/dev/null || true
    fi
  fi
}

#───────────────────────────────────────────────────────────────────────
# wt 헬퍼: tmux window에서 worktree에 대응하는 window 찾기
#───────────────────────────────────────────────────────────────────────
_wt_find_tmux_window() {
  local branch_name="$1"
  local worktree_abs_path="$2"

  local window_list
  window_list=$(tmux list-windows -F '#{window_id}|#{window_name}|#{pane_current_path}' 2>/dev/null) || return 1

  # 1차: window_name exact match
  local found
  found=$(echo "$window_list" | awk -F'|' -v name="$branch_name" '$2 == name { print $1; exit }')
  if [[ -n "$found" ]]; then
    echo "$found"
    return 0
  fi

  # 2차 fallback: pane_current_path match
  found=$(echo "$window_list" | awk -F'|' -v path="$worktree_abs_path" '$3 == path { print $1; exit }')
  if [[ -n "$found" ]]; then
    echo "$found"
    return 0
  fi

  return 1
}

#───────────────────────────────────────────────────────────────────────
# wt 헬퍼: worktree용 tmux window 생성 또는 기존 window로 전환
#───────────────────────────────────────────────────────────────────────
_wt_tmux_open() {
  local branch_name="$1"
  local worktree_abs_path="$2"
  local stay="$3"

  # tmux 외부면 아무것도 안 함 (caller가 cd 처리)
  if [[ -z "${TMUX:-}" ]]; then
    return 0
  fi

  # 기존 window 검색
  local found
  found=$(_wt_find_tmux_window "$branch_name" "$worktree_abs_path")

  if [[ -n "$found" ]]; then
    # 기존 window로 전환
    if [[ "$stay" == false ]]; then
      tmux select-window -t "$found"
    fi
    return 0
  fi

  # 새 window 생성 (stderr를 분리하여 pane_id 오염 방지)
  local _tmux_err="${TMPDIR:-/tmp}/_wt_tmux_err.$$"
  if [[ "$stay" == false ]]; then
    local new_pane
    new_pane=$(tmux new-window -n "$branch_name" -c "$worktree_abs_path" -P -F '#{pane_id}' 2>"$_tmux_err") || {
      echo "❌ tmux window 생성 실패" >&2
      echo "  명령어: tmux new-window -n \"$branch_name\" -c \"$worktree_abs_path\"" >&2
      echo "  에러: $(cat "$_tmux_err" 2>/dev/null)" >&2
      echo "  환경: TMUX='${TMUX}' TERM='${TERM}' tmux_version='$(tmux -V 2>/dev/null)'" >&2
      echo "⚠️  cd fallback으로 전환합니다" >&2
      rm -f "$_tmux_err"
      return 1
    }
    rm -f "$_tmux_err"
    tmux set-option -t "$new_pane" -p @custom_pane_title "$branch_name"
  else
    local new_pane
    new_pane=$(tmux new-window -d -n "$branch_name" -c "$worktree_abs_path" -P -F '#{pane_id}' 2>"$_tmux_err") || {
      echo "❌ tmux window 생성 실패" >&2
      echo "  명령어: tmux new-window -d -n \"$branch_name\" -c \"$worktree_abs_path\"" >&2
      echo "  에러: $(cat "$_tmux_err" 2>/dev/null)" >&2
      echo "  환경: TMUX='${TMUX}' TERM='${TERM}' tmux_version='$(tmux -V 2>/dev/null)'" >&2
      echo "⚠️  cd fallback으로 전환합니다" >&2
      rm -f "$_tmux_err"
      return 1
    }
    rm -f "$_tmux_err"
    tmux set-option -t "$new_pane" -p @custom_pane_title "$branch_name"
  fi

  return 0
}

#───────────────────────────────────────────────────────────────────────
# wt 헬퍼: worktree에 대응하는 tmux window 닫기
#───────────────────────────────────────────────────────────────────────
_wt_tmux_close() {
  local branch_name="$1"
  local worktree_abs_path="$2"

  if [[ -z "${TMUX:-}" ]]; then
    return 0
  fi

  local found
  found=$(_wt_find_tmux_window "$branch_name" "$worktree_abs_path")
  if [[ -z "$found" ]]; then
    return 0
  fi

  # 현재 window는 닫지 않음 (쉘이 종료됨)
  local current
  current=$(tmux display-message -p '#{window_id}')
  if [[ "$found" == "$current" ]]; then
    echo "   ⚠️  현재 윈도우는 닫을 수 없습니다 (수동으로 닫아주세요)"
    return 2
  fi

  # 마지막 window는 닫지 않음 (세션이 종료됨)
  local window_count
  window_count=$(tmux list-windows | wc -l)
  if [[ $window_count -le 1 ]]; then
    echo "   ⚠️  마지막 윈도우는 닫을 수 없습니다 (세션이 종료됩니다)"
    return 0
  fi

  tmux kill-window -t "$found" 2>/dev/null
  echo "   └─ tmux 윈도우 닫힘"
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
      local wt_path="${match[1]:-${BASH_REMATCH[1]}}"
      if [[ "$wt_path" == "$git_root/.wt/"* ]]; then
        worktree_paths+=("$wt_path")
      fi
    elif [[ "$line" =~ ^branch\ refs/heads/(.+) ]]; then
      local branch="${match[1]:-${BASH_REMATCH[1]}}"
      if [[ ${#worktree_paths[@]} -gt ${#worktree_branches[@]} ]]; then
        worktree_branches+=("$branch")
      fi
    fi
  done < <(git worktree list --porcelain)

  if [[ ${#worktree_paths[@]} -eq 0 ]]; then
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

  # gh CLI 확인
  if command -v gh &>/dev/null; then
    if gh auth status &>/dev/null; then
      gh_available=true
    else
      echo "⚠️  gh auth login 필요 - 오프라인 모드로 진행"
    fi
  fi

  # 임시 디렉토리 생성 (병렬 PR 조회용)
  local tmp_dir
  tmp_dir=$(mktemp -d)
  trap 'rm -rf "$tmp_dir"' EXIT INT TERM HUP

  # 4a. Dirty 상태 확인 + 4b. PR 상태 조회 (병렬)
  # job control 메시지 숨기기 (zsh)
  {
    setopt local_options no_monitor no_notify 2>/dev/null || true
    # shellcheck disable=SC2051  # zsh 전용: {1..${#array[@]}} 패턴
    for i in {1..${#worktree_paths[@]}}; do
      local wt_path="${worktree_paths[$i]}"
      local branch="${worktree_branches[$i]}"

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
  # shellcheck disable=SC2051
  for i in {1..${#worktree_paths[@]}}; do
    pr_status[$i]=$(cat "$tmp_dir/$i" 2>/dev/null || echo "OFFLINE")
  done

  # 5. fzf 입력 데이터 준비
  local -a fzf_lines=()
  # shellcheck disable=SC2051
  for i in {1..${#worktree_paths[@]}}; do
    local wt_path="${worktree_paths[$i]}"
    local branch="${worktree_branches[$i]}"
    local pr="${pr_status[$i]}"
    local dirty="${dirty_status[$i]}"
    local wt_name
    wt_name=$(basename "$wt_path")

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
    for line in "${fzf_lines[@]}"; do
      fzf_input+="$line"$'\n'
    done

    local selected
    selected=$(echo -n "$fzf_input" | fzf --multi --ansi \
      --delimiter='|' \
      --with-nth=4 \
      --preview='echo {} | cut -d"|" -f2 | xargs -I{} git -C {} log --oneline -5 2>/dev/null || echo "로그 없음"' \
      --preview-window=right:50% \
      --bind='space:toggle,ctrl-a:select-all' \
      --header="Space: 다중 선택 / Enter: 확인 / ESC: 취소")

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
    # shellcheck disable=SC2051
    for i in {1..${#fzf_lines[@]}}; do
      local display
      display=$(echo "${fzf_lines[$i]}" | cut -d'|' -f4)
      echo "  [$i] $display"
    done
    echo ""
    echo "삭제할 번호를 입력하세요 (예: 1,3,5 또는 'a' 전체):"
    echo -n "> "
    read -r selection

    if [[ "$selection" == "a" || "$selection" == "A" ]]; then
      selected_items=("${fzf_lines[@]}")
    elif [[ -n "$selection" ]]; then
      IFS=',' read -rA nums <<< "$selection"
      for num in "${nums[@]}"; do
        num=$(echo "$num" | tr -d ' ')
        if [[ "$num" =~ ^[0-9]+$ ]] && [[ $num -ge 1 ]] && [[ $num -le ${#fzf_lines[@]} ]]; then
          selected_items+=("${fzf_lines[$num]}")
        fi
      done
    fi
  fi

  if [[ ${#selected_items[@]} -eq 0 ]]; then
    echo "선택된 항목이 없습니다."
    return 0
  fi

  # 7. 선택된 항목 삭제
  local deleted=0
  for item in "${selected_items[@]}"; do
    local wt_path
    wt_path=$(echo "$item" | cut -d'|' -f2)
    local branch
    branch=$(echo "$item" | cut -d'|' -f3)
    local wt_name
    wt_name=$(basename "$wt_path")

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
        echo "⚠️  '$wt_name' ($branch): '$parent_branch' 이후 ${commit_count}개의 커밋이 있습니다:"
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
          echo "⚠️  '$wt_name' ($branch): '$upstream' 이후 push되지 않은 ${commit_count}개의 커밋이 있습니다:"
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

    # tmux 윈도우 닫기 (worktree 제거 전)
    _wt_tmux_close "$branch" "$wt_path"
    if [[ $? -eq 2 ]]; then
      echo "   ⏭️  현재 윈도우의 워크트리는 삭제할 수 없습니다. 다른 윈도우로 이동 후 다시 시도하세요."
      continue
    fi

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
  echo "✅ ${deleted}개의 워크트리가 삭제되었습니다."
}
