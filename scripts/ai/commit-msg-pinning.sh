#!/usr/bin/env bash
# commit-msg-pinning.sh
# 목적: commit message에서 LLM 박제(pinning) 패턴을 감지하고 경고. 영구 산출물(commit/PR/이슈)에
#       세션 내부 메타데이터(라운드 번호/finding ID/DA 실행 키워드)가 박혀 drift나 stale 참조를
#       일으키는 것을 경고한다.
# 정책:
# - warn-only: 매치 시 stderr 경고만 출력하고 exit 0. commit 차단하지 않음. lefthook 단계 자체를
#   건너뛰려면 lefthook 표준 메커니즘 (`LEFTHOOK=0`, `--no-verify`)을 사용한다.
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

warn() {
  echo "[WARN] pinning: $1" >&2
}

# Category code → user-facing remediation message mapping. category code is
# the stable ID returned by pinning_findings_records (A/B/C); the message
# stays here in commit-msg context to preserve existing UX wording without
# embedding it in the shared lib.
WARN_A="라운드 카운터(\`Round N\`) 박제 감지. 영구 산출물에는 자연어 설명으로 표현하라."
WARN_B="DA finding ID 박제 감지. 라운드/finding ID는 휘발성 보고에만 사용하고 commit message에는 박지 마라."
WARN_C="DA 키워드 박제 감지. 검토 라운드/모드 표기는 commit message에 박지 말고 PR 코멘트 또는 휘발성 작업 노트에 둬라."

# Loop over the shared structured records. Verbose warn message is emitted
# once per category (when the category code transitions). The shared category
# label line is also printed so commit-msg output matches the guard/alert
# rendering contract.
records=$(pinning_findings_records "$CLEAN_MSG")
found=0

if [ -n "$records" ]; then
  found=1
  prev_code=""
  while IFS=$'\t' read -r code label entry _sub_tag; do
    [ -n "$code" ] || continue
    if [ "$code" != "$prev_code" ]; then
      case "$code" in
        A) warn "$WARN_A"; printf '  - %s\n' "$label" >&2 ;;
        B) warn "$WARN_B"; printf '  - %s\n' "$label" >&2 ;;
        C) warn "$WARN_C"; printf '  - %s\n' "$label" >&2 ;;
        *) warn "$label" ;;
      esac
      prev_code="$code"
    fi
    printf '%s%s\n' "$PINNING_REPORT_INDENT" "$entry" >&2
  done <<< "$records"
fi

if [ "$found" -eq 1 ]; then
  warn "위 경고는 차단하지 않습니다 (warn-only). 검토 후 amend로 정정하거나 의도적 사용이면 무시하세요."
fi

exit 0
