#!/usr/bin/env bash
# commit-msg-pinning.sh
# 목적: commit message에서 LLM 박제(pinning) 패턴을 감지한다. 영구 산출물(commit/PR/이슈)에
#       세션 내부 메타데이터(라운드 번호/finding ID/DA 실행 키워드/Claude 세션 URL)가 박혀 drift나
#       stale 참조, 불필요한 세션 메타데이터 공개를 일으키는 것을 경고하거나 막는다.
# 정책:
# - 범주 A~C(라운드 카운터/finding ID/DA 키워드)는 warn-only: 매치 시 stderr 경고만 출력하고
#   commit을 막지 않는다. #583 ADR은 정규식 오탐이 정상 commit을 막아 작업 흐름을 해치는 것을
#   피하려고 차단 모드를 기각했다.
# - 범주 D(Claude 세션 URL, #1422)만 예외로 exit 1로 commit을 막는다. claude.ai의
#   `/code/session_<id>` 고정 형식이라 오탐 여지가 좁고, 차단은 사용자가 결정했다. 세션 URL은
#   PreToolUse 가드가 보지 못하는 경로(사람의 직접 commit, 가드 없는 도구, 파일 간접 참조)로도
#   들어오므로 commit 단계에서 한 번 더 막는다.
# - 검사 자체의 내부 오류(lib source 실패, 임시 파일 생성 실패 등)는 stderr 경고 후 exit 0이다.
#   commit-msg는 프로비저닝 drift나 실행 환경 문제로 commit을 막지 않는다는 기존 결정을 지키려고,
#   세션 URL 매치만 전용 상태 코드(BLOCK_STATUS)로 구분해 exit 1로 바꾼다.
# - lefthook 단계 자체를 건너뛰려면 lefthook 표준 메커니즘 (`LEFTHOOK=0`, `--no-verify`)을 사용한다.
# 작동 범위: 이 hook은 신규 commit message만 검사한다. 과거 commit / squash commit body /
#   PR · 이슈 본문에 이미 박힌 잔존 박제는 **소급해서 수정하지 않으며** 본 hook 범위 밖이다.
set -euo pipefail

# scan_commit_msg가 세션 URL 매치로 commit을 막을 때만 쓰는 종료 상태. 그 밖의 비0 종료는 내부
# 오류로 본다. grep·sed·mktemp·bash의 일반 실패 코드(1, 2, 4, 126, 127, 128+)와 겹치지 않는 값이다.
BLOCK_STATUS=3

warn() {
  echo "[WARN] pinning: $1" >&2
}

error() {
  echo "[ERROR] pinning: $1" >&2
}

# Category code → user-facing remediation message mapping. category code is
# the stable ID returned by pinning_findings_records (A/B/C/D); the message
# stays here in commit-msg context to preserve existing UX wording without
# embedding it in the shared lib.
WARN_A="라운드 카운터(\`Round N\`) 박제 감지. 영구 산출물에는 자연어 설명으로 표현하라."
WARN_B="DA finding ID 박제 감지. 라운드/finding ID는 휘발성 보고에만 사용하고 commit message에는 박지 마라."
WARN_C="DA 키워드 박제 감지. 검토 라운드/모드 표기는 commit message에 박지 말고 PR 코멘트 또는 휘발성 작업 노트에 둬라."
ERROR_D="Claude 세션 URL 박제 감지. 이 범주는 warn-only의 예외로 커밋을 차단한다."

# 서브셸 안에서만 호출한다 (아래 실행부). 전역 변수와 EXIT trap은 서브셸 밖으로 새지 않는다.
scan_commit_msg() {
  # Shared pattern/helper library. Missing library is fail-open: commit-msg must
  # not block commits on provisioning drift (the PreToolUse guard fails closed).
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

  # commit msg 본문을 임시 파일에 정제 저장한다. git이 실제로 남기는 메시지만 검사하려고
  # `git commit -v`(또는 `--cleanup=scissors`)의 scissors 줄부터 끝까지(안내 주석과 diff)를
  # 먼저 잘라낸 뒤 남은 `#` 주석 줄을 지운다.
  # 모든 grep을 파일 직접 읽기로 처리 — `echo "$VAR" | grep` 조합은 큰 메시지 + grep -q 조기
  # 종료 시 echo가 SIGPIPE를 받아 set -o pipefail 환경에서 pipeline이 nonzero를 반환하고
  # warn이 silent fail 한다 (PoC 검증). bash here-string도 동일 위험.
  CLEAN_MSG=$(mktemp)
  trap 'rm -f "$CLEAN_MSG"' EXIT
  sed -e '/^# ------------------------ >8 ------------------------$/,$d' -e '/^#/d' \
    "$COMMIT_MSG_FILE" > "$CLEAN_MSG"

  # Loop over the shared structured records. Verbose warn message is emitted
  # once per category (when the category code transitions). The shared category
  # label line is also printed so commit-msg output matches the guard/alert
  # rendering contract.
  records=$(pinning_findings_records "$CLEAN_MSG")
  warned=0
  blocked=0

  if [ -n "$records" ]; then
    prev_code=""
    while IFS=$'\t' read -r code label entry _sub_tag; do
      [ -n "$code" ] || continue
      if [ "$code" != "$prev_code" ]; then
        case "$code" in
          A) warn "$WARN_A"; printf '  - %s\n' "$label" >&2; warned=1 ;;
          B) warn "$WARN_B"; printf '  - %s\n' "$label" >&2; warned=1 ;;
          C) warn "$WARN_C"; printf '  - %s\n' "$label" >&2; warned=1 ;;
          D) error "$ERROR_D"; printf '  - %s\n' "$label" >&2; blocked=1 ;;
          *) warn "$label"; warned=1 ;;
        esac
        prev_code="$code"
      fi
      printf '%s%s\n' "$PINNING_REPORT_INDENT" "$entry" >&2
    done <<< "$records"
  fi

  if [ "$warned" -eq 1 ]; then
    warn "위 경고는 차단하지 않습니다 (warn-only). 검토 후 amend로 정정하거나 의도적 사용이면 무시하세요."
  fi

  if [ "$blocked" -eq 1 ]; then
    error "커밋을 중단했다. 메시지에서 세션 URL과 'Claude-Session:' 트레일러 줄을 지운 뒤 다시 커밋하라."
    exit "$BLOCK_STATUS"
  fi

  exit 0
}

# 검사는 errexit를 켠 서브셸에서 돌리고 종료 상태만 받는다. 서브셸을 `if`·`||` 문맥에 두면 bash가
# 그 안의 errexit까지 꺼 버리므로, 바깥 셸의 errexit를 잠시 끄고 단독 명령으로 실행한다.
set +e
(
  set -e
  scan_commit_msg "$@"
)
status=$?
set -e

case "$status" in
  0) exit 0 ;;
  "$BLOCK_STATUS") exit 1 ;;
  *)
    warn "내부 오류(rc=$status)로 검사를 끝내지 못했습니다. 커밋은 막지 않으니 메시지에 Claude 세션 URL이 없는지 직접 확인하세요."
    exit 0
    ;;
esac
