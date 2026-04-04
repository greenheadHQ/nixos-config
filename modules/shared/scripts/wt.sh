#!/usr/bin/env bash
# wt: Git worktree 관리 도구 (fzf TUI, tmux 통합)
# 사용법: wt [--stay] [--claude] [--tmux] <branch> | wt cd [--tmux] [-|name] | wt ls | wt cleanup [--auto]

# === Change Intent Record ===
# v1 (2025년 초~): 커스텀 wt/wt-cleanup 셸 함수 838줄 (zsh, fzf 기반)
#    .wt/ 경로, tmux 윈도우 통합, .wt-parent 부모 브랜치 추적
# v2 (PR #176, CLOSED): claude-wrapper.sh Killed: 9 수정 시도, wrapper 복잡성 한계 확인
# v3 (PR #180): Claude Code v2.x 내장 --worktree --tmux로 완전 대체, -1441줄 삭제
#    판단 근거: 내장 기능이 동일 역할을 수행하므로 코드 제거가 합리적
# v4 (PR #205): 내장 --worktree의 치명적 한계 확인 후 커스텀 구현 복구+고도화
#    한계 1: 항상 default branch 기준 분기 (Git Flow 환경에서 치명적, GitHub Issue #28958)
#    한계 2: Ctrl+C/Z 시 main worktree cwd로 복귀 (worktree 컨텍스트 유실)
#    한계 3: worktree 정리 도구 부재 (stale worktree 누적)
#    TUI 백엔드: gum (choose/filter/confirm/spin/style/table 6종 서브커맨드 활용)
# v5 (이번 변경): TUI 백엔드를 gum → fzf로 전환
#    전환 이유 1: gum의 wide character truncation 버그 — 한글 커밋 메시지가 바이트 경계에서
#               잘려서 인코딩이 깨짐 (CJK 2-column width 미고려)
#    전환 이유 2: fzf의 --preview 지원 — 선택 전 worktree 상태(커밋 로그, dirty) 미리보기 가능
#    전환 이유 3: 사용자가 fzf에 더 익숙하고, 프로젝트 전체가 이미 fzf 기반 (cheat, tmux, nfu)
#    trade-off: gum의 대화형 컴포넌트(choose/filter/confirm)를 잃지만,
#              fzf의 preview + 정확한 유니코드 처리가 실용적으로 더 우수.
#    보존: gum table/style은 표시 전용(wide char 무관)이므로 wt ls에서 유지.
# v6 (이번 변경): --tmux 플래그 추가 — tmux 밖에서 독립 tmux 세션 생성+attach
#    동기: claude --worktree --tmux와 유사한 경험을 wt에서도 제공
#    세션 이름: wt-<repo>-<dir_name> (repo별 네임스페이스 — 멀티 repo 충돌 방지)
#    핵심 제약: 래퍼의 subshell $() 안에서 exec tmux 불가 → --tmux 감지 시 우회
#    tmux 안에서 --tmux: 기존 윈도우 모드로 fallback (의도적 정책 — 세션 전환보다 윈도우가 워크플로우에 적합)

set -euo pipefail

# ── 상수 ─────────────────────────────────────────────────────────────────────

# shellcheck disable=SC2034  # Helper modules consume these globals.
WORKTREE_DIR=".claude/worktrees"
# shellcheck disable=SC2034  # Helper modules consume these globals.
WT_LAST_FILE=".claude/worktrees/.wt-last"
WT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WT_LIB_DIR=""
WT_DEPLOYED_LIB_DIR="$(cd "$WT_SCRIPT_DIR/.." && pwd)/lib/wt"
WT_REPO_LIB_DIR=""
WT_HELPERS=(
  ui
  tmux
  git-state
  bootstrap
  create
  navigate
  cleanup
)

case "$WT_SCRIPT_DIR" in
  */modules/shared/scripts) WT_REPO_LIB_DIR="$WT_SCRIPT_DIR/lib/wt" ;;
esac

_wt_has_helper_set() {
  local dir="$1"
  local helper
  for helper in "${WT_HELPERS[@]}"; do
    [[ -f "$dir/$helper.sh" ]] || return 1
  done
  return 0
}

if _wt_has_helper_set "$WT_DEPLOYED_LIB_DIR"; then
  WT_LIB_DIR="$WT_DEPLOYED_LIB_DIR"
elif [[ -n "$WT_REPO_LIB_DIR" ]] && _wt_has_helper_set "$WT_REPO_LIB_DIR"; then
  WT_LIB_DIR="$WT_REPO_LIB_DIR"
fi

[[ -n "$WT_LIB_DIR" ]] || {
  echo "error: wt helper directory not found" >&2
  exit 1
}

# Load order is intentional and driven by the ordered helper manifest above.
for helper in "${WT_HELPERS[@]}"; do
  # shellcheck source=/dev/null
  source "$WT_LIB_DIR/$helper.sh"
done

# ── 도움말 ───────────────────────────────────────────────────────────────────

show_help() {
  cat << 'EOF'
사용법: wt [옵션] <command|branch>

Git worktree 관리 도구 (fzf TUI, tmux 통합)

서브커맨드:
  wt <branch>             현재 HEAD 기준 worktree 생성
  wt cd [name|-]          worktree로 이동 (fuzzy 검색, - = 이전)
  wt ls                   worktree 목록 (PR 상태, age, dirty)
  wt cleanup [--auto]     worktree 정리 (인터랙티브/자동)

옵션 (create):
  --stay                  tmux 윈도우를 백그라운드로 생성
  --claude                worktree 생성 후 Claude Code 자동 실행
  --tmux                  독립 tmux 세션 생성+attach (tmux 밖에서)

옵션 (cd):
  --tmux                  worktree를 tmux 세션으로 열기 (tmux 밖에서)

옵션 (cleanup):
  --auto                  MERGED 상태 worktree 자동 정리

예시:
  wt feature-login        feature-login 브랜치 + worktree 생성
  wt --claude fix-bug     worktree 생성 + claude 실행
  wt --tmux feature-x     worktree 생성 + tmux 세션 attach
  wt --tmux --claude pr   worktree + tmux 세션 + claude 실행
  wt --tmux --stay test   tmux 세션 detached 생성
  wt cd login             "login" 포함 worktree로 이동
  wt cd --tmux login      worktree를 tmux 세션으로 열기
  wt cd -                 이전 worktree로 이동
  wt ls                   전체 worktree 상태 확인
  wt cleanup              인터랙티브 정리
  wt cleanup --auto       MERGED 자동 정리
EOF
}

# ── 디스패치 ─────────────────────────────────────────────────────────────────

case "${1:-}" in
  cd)      shift; cmd_cd "$@" ;;
  ls)      shift; cmd_ls "$@" ;;
  cleanup) shift; cmd_cleanup "$@" ;;
  -h|--help) show_help ;;
  "")      show_help ;;
  *)       cmd_create "$@" ;;
esac
