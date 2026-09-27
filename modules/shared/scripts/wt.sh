#!/usr/bin/env bash
# wt: Git worktree 관리 도구 (fzf TUI)
# 사용법: wt [--yes|--if-exists=MODE] <branch> | wt cd [-|name] | wt ls [--json] | wt cleanup [--auto|--yes] [name...]

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
# v7 (이번 변경): 비대화형(LLM/스크립트) 호환 + dead-path 가지치기
#    배경: 비대화형 셸은 wt 함수 래퍼 없이 ~/.local/bin/wt 직행 → _confirm/_choose가 stdin EOF로
#          자동 취소되어 create 충돌 처리·cd 선택·cleanup 선택이 막혔다.
#    감지: _wt_interactive() = [[ -t 0 ]] && WT_NONINTERACTIVE unset. fzf/read/exec tmux 게이트.
#    플래그: create --if-exists=reuse|recreate|fail (비대화형 충돌 기본=안전 실패) + --yes,
#           cleanup [name...] 위치 인자 + --yes, ls --json 구조화 출력.
#    제거: .wt-parent (write-only dead data, 읽는 코드 0곳) / gum 의존 (wt ls 표시 전용 잔재,
#         plain printf fallback이 동등; packages.nix에서도 제거).
# v8: 비대화형 stdout 계약 강화 — "비대화형 셸은 래퍼 없이 직행"(v7 전제)이 깨짐을 확인.
#    배경: LLM 하네스(Claude Code)가 대화형 셸 snapshot을 비대화형 셸에 주입해 zsh 래퍼가
#          존재할 수 있다. 래퍼 cd 분기는 경로를 출력하지 않아 cd "$(wt cd <name>)"가 빈
#          문자열을 받고, zsh의 `cd ""` no-op 성공으로 잘못된 디렉토리에서 후속 명령이 실행됐다.
#    수정: 래퍼 self-gate(WT_NONINTERACTIVE/stdin 비TTY/stdout 비TTY → 바이너리 passthrough),
#          tmux UI 부수효과(윈도우 생성/전환)는 _wt_tmux_ui_allowed 단일 정책으로 대화형 한정,
#          --stay도 비대화형에서는 stdout 경로 출력.
# v9 (#1299): tmux·Claude presentation 제거 — wt는 worktree 관리만 한다
#    배경: v6~v8이 쌓은 UI 정책(대화형이면 윈도우/세션, 아니면 경로)은 같은 명령이 문맥에
#          따라 다른 일을 하게 만들었고, 그 분기가 CLI 플래그·핸들러 시그니처·셸 래퍼·
#          문서·테스트를 모두 관통했다. 조사 결과 세 플래그(--stay/--claude/--tmux)와
#          자동 window/session/Claude launch의 실사용 근거는 0이었다.
#    제거: 세 플래그와 전달 경로, window/session open·attach·select, Claude send-keys,
#          래퍼의 --tmux bypass. create/cd는 언제나 경로 한 줄을 stdout으로 낸다
#          (이동은 셸 래퍼나 cd "$(wt ...)"의 몫).
#    보존: 삭제 안전성 가드 — pane lookup, 활성 프로세스 판정, 창·세션 닫기.
#          범위는 창과 세션이 다르다 — 창은 이름이 아니라 pane cwd가 그 worktree 아래인지로
#          고르므로 사용자가 만든 창도 포함되고, 세션만 `wt-*` 이름 매칭이라 과거
#          presentation이 만든 것에 한정된다. 닫는 시점도 전략별로 다르다: 강제 경로는
#          제거 전, 보호 경로는 부분 정리를 피하려고 제거에 성공한 뒤 부수 정리로 닫는다.
#          강제 경로의 순서 계약은 tests/suites/wt-cleanup.sh가 고정한다.
#    소멸: v8의 _wt_tmux_ui_allowed 단일 정책, 그리고 직전 변경(#1285)이 `wt cd --tmux`에서
#          고친 세션명 충돌(basename → 표시 이름)이 그 호출부와 함께 사라졌다. 남은
#          _wt_session_name은 이미 떠 있는 legacy 세션을 찾아 닫는 용도뿐이라 규칙 고정이다.
# v10 (#1452): 활성 작업 보호를 tmux 창 검사에서 프로세스 cwd 탐지로 교체, tmux 코드 제거
#    배경: worktree는 주로 tmux 밖 터미널 탭에서 쓴다. pane만 보던 판정은 편집기·에이전트가
#          떠 있는 worktree도 "쓰지 않음"으로 통과시켜, v9가 보존한 가드의 목적(쓰는 중인
#          worktree를 cleanup·재생성에서 지킨다)을 달성하지 못했다.
#    교체: v9 보존 항목 중 활성 프로세스 판정은 목적을 유지하고 수단을 바꿨다 — worktree
#          폴더(하위 포함)를 cwd로 둔 프로세스를 lsof로 찾는다(lib/wt/process.sh). 유휴 셸도
#          막고, 탐지에 실패하면 멈춘다. wt 자신·조상·자손과 다른 사용자 프로세스는 뺀다.
#    제거: pane lookup, 창·세션 닫기, 무확인 삭제의 `wt-` 세션 존재 스킵, _wt_session_name.
#          창·세션 닫기는 사라진 cwd를 붙잡은 pane을 남기지 않으려는 수단이었다. 유휴 셸까지
#          막는 지금은 그런 pane이 생기기 전에 제거가 멈춘다. 세션 이름 규칙을 고정하던
#          이유(이미 떠 있는 legacy 세션 찾기)는 `wt-` 세션이 남지 않았음을 사용자가 확인해
#          사라졌다.
#    --yes: 이름을 지정하거나 대화형으로 고른 정리와 재생성(대화형 선택 포함)만 활성 가드를
#          우회한다(막힐 때 PID·명령을 보여 준 뒤의 판단). `wt cleanup --auto --yes`는 쓰는
#          중인 worktree를 건너뛴다. 잠금과 wt를 실행한 셸의 cwd 가드는 --yes로도 우회하지
#          않는다.
#    남는 제약: cwd가 worktree 밖인 프로세스(폴더를 연 GUI 편집기 등), 다른 사용자·root
#          프로세스, 탐지 뒤 제거 전에 새로 들어온 프로세스는 막지 못한다. 샌드박스가 다른
#          프로세스 정보만 가리면 lsof가 정상 종료하면서 일부만 내어 탐지가 통과한다.

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
  process
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

Git worktree 관리 도구 (fzf TUI; 비대화형/LLM 셸 호환)

서브커맨드:
  wt <branch>             현재 HEAD 기준 worktree 생성
  wt cd [name|-]          worktree로 이동 (fuzzy 검색, - = 이전)
  wt ls [--json]          worktree 목록 (PR 상태, age, dirty)
  wt cleanup [--auto]     worktree 정리 (인터랙티브/자동/이름 지정)

옵션 (create):
  --if-exists=MODE        충돌 시 동작: reuse|recreate|fail (비대화형 충돌 시 필수)
                          기존 worktree의 reuse/recreate는 그 경로에 요청 브랜치가
                          checkout돼 있을 때만 (다른 브랜치·detached·조회 실패면 실패)
  --yes, -y               확인 프롬프트 자동 승인. 재생성에서는 활성 작업 가드도 우회

옵션 (ls):
  --json                  JSON 배열로 출력 (name/branch/path/pr/dirty/unpushed/...)

옵션 (cleanup):
  --auto                  MERGED 상태 worktree 자동 정리
  --yes, -y               선정된 대상의 제거 전략을 강제로 전환 — dirty/unpushed 확인을
                          자동 승인하고, MERGED 무확인 삭제에 붙는 보호(비강제 제거·
                          제거 직전 재확인·ref CAS)를 해제한다. 단 --auto의 후보 선정과
                          그 경로가 삭제 직전에 다시 보는 dirty·근거(조회 이후 HEAD 변경,
                          근거 기록 부재 포함)는 우회하지 않는다. 이름을 지정하거나
                          대화형으로 고른 정리에서만 활성 작업 가드도 우회한다. 잠금과
                          현재 위치한 worktree 제외는 우회하지 않는다
  [name...]               정리할 worktree 이름 직접 지정

활성 작업 가드 (cleanup·재생성):
  대상 worktree(하위 포함)를 작업 위치(cwd)로 둔 프로세스가 있으면 유휴 셸이라도
  지우지 않고 PID와 명령을 보여 준다. 탐지(lsof)에 실패하면 원인을 알리고 멈춘다.
  wt를 부른 셸·세션(조상)과 wt의 자손은 판정에서 뺀다.
  우회(--yes): 이름을 지정하거나 대화형으로 고른 정리(wt cleanup <name> --yes)와
  재생성(wt --yes --if-exists=recreate <branch>, 대화형 선택 포함).
  wt cleanup --auto --yes는 우회하지 않고 그 worktree를 건너뛴다.
  막지 못하는 것:
    다른 사용자·root 프로세스 (현재 사용자 프로세스만 본다)
    cwd가 worktree 밖인 프로세스 (폴더를 연 GUI 편집기 등)
    샌드박스가 다른 프로세스 정보만 가린 환경 (lsof가 정상 종료하면서 일부만 내어
    탐지가 통과한다)

경로 출력:
  생성/이동은 언제나 경로 한 줄을 stdout으로 낸다 — 실제 이동은 셸 래퍼나
  cd "\$(wt cd <name>)"가 한다. 비대화형(stdin 비tty 또는 WT_NONINTERACTIVE=1)에서는
  fzf/번호선택 대신 명시 플래그·인자가 필요하다.

Claude/Codex:
  worktree 생성/재생성 bootstrap은 .claude/settings.local.json과 .codex/를 복사하고,
  Codex 전역 config에 worktree project trust를 등록한다. settings.local.json에서
  enabled된 source repo Claude local plugin manifest entry만 worktree 경로로 상속하며,
  해당 local plugin의 skills/는 worktree .agents/skills에 symlink로 투영한다.
  user-scope plugin entry, unrelated project entry, plugin agents/rules/MCP는 변경하지 않는다.

예시:
  wt feature-login              feature-login 브랜치 + worktree 생성
  wt --if-exists=reuse feat-x   있으면 재사용, 없으면 생성 (비대화형 안전)
  cd "\$(wt cd login)"           "login" worktree 경로로 이동 (비대화형)
  wt cd -                       이전 worktree로 이동
  wt ls --json                  worktree 상태 JSON 출력
  wt cleanup --auto             MERGED 자동 정리
  wt cleanup feat_x issue_3     지정 worktree 정리 (비대화형)
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
