#!/usr/bin/env bash
# commit-msg-pinning.sh
# 목적: commit message에서 LLM 박제(pinning) 패턴을 감지하고 경고. 영구 산출물(commit/PR/이슈)에
#       세션 내부 메타데이터(라운드 번호/finding ID/partial hash)가 박혀 squash 후 dangling되거나
#       drift를 일으키는 것을 차단한다.
# 정책:
# - warn-only: 매치 시 stderr 경고만 출력하고 exit 0. commit 차단하지 않음. lefthook 단계 자체를
#   건너뛰려면 lefthook 표준 메커니즘 (`LEFTHOOK=0`, `--no-verify`)을 사용한다.
# - revert 예외: commit msg 첫 줄이 "revert" 또는 "Revert"로 시작하면 partial hash 검사 skip.
# 작동 범위: 이 hook은 신규 commit message만 검사한다. 과거 commit / squash commit body /
#   PR · 이슈 본문에 이미 박힌 잔존 박제는 **소급해서 수정하지 않으며** 본 hook 범위 밖이다.
set -euo pipefail

# Shared pattern/helper library. Missing library is fail-open because this
# hook is warn-only and must not block commits on provisioning drift.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PINNING_LIB="${PINNING_PATTERNS_LIB:-$REPO_ROOT/modules/shared/programs/claude/files/lib/pinning-patterns.sh}"
if [ ! -f "$PINNING_LIB" ]; then
  PINNING_LIB="$HOME/.claude/lib/pinning-patterns.sh"
fi
if [ ! -f "$PINNING_LIB" ]; then
  exit 0
fi
# shellcheck source=../modules/shared/programs/claude/files/lib/pinning-patterns.sh
. "$PINNING_LIB"

# 검사 대상 commit msg 파일 (lefthook이 {1}로 전달)
COMMIT_MSG_FILE="${1:-.git/COMMIT_EDITMSG}"

if [ ! -f "$COMMIT_MSG_FILE" ]; then
  exit 0
fi

# commit msg 본문을 임시 파일에 정제 저장 (verbose diff 라인 `#` 주석 제거).
# 모든 grep을 파일 직접 읽기로 처리 — `echo "$VAR" | grep` 조합은 큰 메시지 + grep -q 조기
# 종료 시 echo가 SIGPIPE를 받아 set -o pipefail 환경에서 pipeline이 nonzero를 반환하고
# warn이 silent fail 한다 (PoC 검증). bash here-string도 동일 위험.
CLEAN_MSG=$(mktemp)
trap 'rm -f "$CLEAN_MSG"' EXIT
sed -e '/^#/d' "$COMMIT_MSG_FILE" > "$CLEAN_MSG"

# commit msg 첫 줄 (revert prefix 판단용) — head는 첫 줄만 읽으므로 SIGPIPE 위험 동일하지만
# 1줄 읽기는 buffer 크기 미만이라 실측 안전. 명시적 read로 더 견고하게.
read -r FIRST_LINE < "$CLEAN_MSG" || FIRST_LINE=""

warn() {
  echo "[WARN] pinning: $1" >&2
}

# check_ere — 단순 정규식 검사 흐름 통합 helper (PATTERN_A/B/C 공통 구조).
# 매치 시 warn + 줄번호 출력 + found=1 설정. found는 셸 전역 변수 (subshell 회피 위해 함수 안 사용).
# usage: check_ere "$PATTERN" "$WARN_MESSAGE"
check_ere() {
  local pattern="$1"
  local message="$2"
  if grep -qE "$pattern" "$CLEAN_MSG"; then
    warn "$message"
    grep -nE "$pattern" "$CLEAN_MSG" | sed 's/^/         /' >&2
    found=1
  fi
}

found=0

check_ere "$PATTERN_A" "라운드 카운터(\`Round N\`) 박제 감지. 영구 산출물에는 자연어 설명으로 표현하라."
check_ere "$PATTERN_B" "DA finding ID 박제 감지. 라운드/finding ID는 휘발성 보고에만 사용하고 commit message에는 박지 마라."
check_ere "$PATTERN_C" "DA 키워드 박제 감지. 검토 라운드/모드 표기는 commit message에 박지 말고 PR 코멘트 또는 휘발성 작업 노트에 둬라."

if [[ ! "$FIRST_LINE" =~ ^[Rr]evert ]]; then
  pinning_hash_report=$(pinning_partial_hash_report "$CLEAN_MSG")
  if [ -n "$pinning_hash_report" ]; then
    warn "${PINNING_PARTIAL_HASH_FINDING_LABEL_SUBSTR} 감지. squash 머지 시 dangling 위험 (partial commit hash 포함). 안정 식별자(PR 번호, 머지된 SHA)로 대체하라."
    echo "$pinning_hash_report" >&2
    found=1
  fi
fi

if [ "$found" -eq 1 ]; then
  warn "위 경고는 차단하지 않습니다 (warn-only). 검토 후 amend로 정정하거나 의도적 사용이면 무시하세요."
fi

exit 0
