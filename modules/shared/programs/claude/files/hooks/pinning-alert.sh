#!/usr/bin/env bash
# pinning-alert.sh — PostToolUse Edit/Write/NotebookEdit warn-only alert (Claude Code).
# 정책 출처: https://github.com/greenheadHQ/nixos-config/issues/603
# 패턴 SSOT: scripts/ai/commit-msg-pinning.sh (PATTERN_A/B/C/D + HASH_MIN/MAX).
#   ↑ 본 파일은 그 SSOT의 inline 사본이다. commit-msg-pinning.sh 패턴을 갱신할 때 본 파일 +
#     Codex 사본(modules/shared/programs/codex/files/hooks/pinning-alert.sh)도 함께
#     갱신해야 한다. lockstep 동등성은 scripts/ai/verify-ai-compat.sh가 PATTERN_A/B/C/D +
#     HASH_MIN/MAX 변수 라인 동등성으로 강제한다 (helper/scan/eligibility까지 cover하지는
#     않으므로 _should_check_path / _scan_file 본문 변경 시 두 사본을 수동 정합 필요).
# 정책: warn-only — stderr alert + exit 0. permissionDecision 사용 금지.
#
# pipefail 안전 모델 (commit-msg-pinning.sh:26-29와 동일 SSOT):
#   `printf '%s' "$TEXT" | grep -qE ...` 조합은 큰 입력에서 grep -q 조기 종료 + SIGPIPE로
#   producer가 nonzero를 반환해 pipefail 환경에서 silent miss를 만든다. 검사 텍스트를 mktemp
#   파일에 저장하고 `grep -qE "$PATTERN" "$tmpfile"`로 검사하여 회피한다.
set -euo pipefail

# 환경 가드(CLAUDECODE/CODEX_PROGRAMMATIC) 없음 — PostToolUse pinning-alert는 자식 LLM 세션의
# Edit/Write를 부모가 보지 못하기 때문에 항상 검사해야 한다 (record-prompt-submit/stop-notification
# 등의 부모-처리-신뢰 가드와 의미가 다르다). 중복 alert는 운영 noise로 수용.

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
case "$TOOL_NAME" in
  Edit | Write | NotebookEdit) ;;
  *) exit 0 ;;
esac

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '
  .tool_input.file_path
  // .tool_input.notebook_path
  // empty
' 2>/dev/null)
[ -n "$FILE_PATH" ] || exit 0

# 파일 한정 (실측: .md 317 + .sh 11 + mktemp tmpfile ~35 ≈ 박제 매치의 ~98.5% cover, 이슈 #603 본문).
# mktemp tmpfile은 모두 `body` substring을 가진 PR/issue body 작성 임시 파일이었으므로 그 형태로
# 한정한다. 일반 코드 확장자(.ts/.py/.nix 등)가 임시 디렉토리 안에 있어도 false positive 회피.
case "$FILE_PATH" in
  *.md | *.sh) ;;
  /tmp/*body* | /var/folders/*/T/*body*) ;;
  *) exit 0 ;;
esac

# Self-exclude: 정책 정의 파일, 본 hook 자기 자신, fixture/eval 데이터
case "$FILE_PATH" in
  */hooks/pinning-alert.sh) exit 0 ;;
  */scripts/ai/commit-msg-pinning.sh) exit 0 ;;
  */skills/run-da/*) exit 0 ;;
  */skills/parallel-audit/*) exit 0 ;;
  */tests/fixtures/*) exit 0 ;;
  */evals/queries.json) exit 0 ;;
  */eval-workspace/*) exit 0 ;;
esac

# 검사 대상 텍스트 추출
TEXT=""
case "$TOOL_NAME" in
  Edit) TEXT=$(printf '%s' "$INPUT" | jq -r '.tool_input.new_string // empty' 2>/dev/null) ;;
  Write) TEXT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // empty' 2>/dev/null) ;;
  NotebookEdit) TEXT=$(printf '%s' "$INPUT" | jq -r '.tool_input.new_source // empty' 2>/dev/null) ;;
esac
[ -n "$TEXT" ] || exit 0

# Pinning hash 길이 경계 (commit-msg-pinning.sh와 동일)
HASH_MIN=7
HASH_MAX=12

# Patterns (commit-msg-pinning.sh PATTERN_A~D와 동일 — lockstep 갱신)
PATTERN_A='\b[Rr][Oo][Uu][Nn][Dd] [0-9]+\b'
PATTERN_B='\b(Correctness|CORRECTNESS|Design|DESIGN|Regression|REGRESSION|Maintainability|MAINTAINABILITY|Security|SECURITY|Hallucination|HALLUCINATION|Side_effect|SIDE_EFFECT|Consistency|CONSISTENCY|Readability|READABILITY|Clean_code|CLEAN_CODE|Yagni|YAGNI|Ngmi|NGMI|CORR|MAINT|MNT|REG|CIR)-[0-9][A-Za-z0-9-]*\b'
PATTERN_C='\bDA (for_pr|for_plan|피드백|[Rr]ound)\b|\bAuditor [A-Za-z_]+-[0-9]|\bparallel-audit (반영|결과|finding)\b'
PATTERN_D='\b[a-f0-9]{7,40}\b|`[a-f0-9]+`'

# 검사 텍스트를 mktemp 파일에 저장 후 파일 기반 grep으로 SIGPIPE 회피.
SCAN_FILE=$(mktemp "${TMPDIR:-/tmp}/pinning-scan-XXXXXX") || exit 0
trap 'rm -f "$SCAN_FILE"' EXIT
printf '%s' "$TEXT" > "$SCAN_FILE"

findings=""
if grep -qE "$PATTERN_A" "$SCAN_FILE"; then
  findings="${findings}\n  - Round counter 박제: 'Round N'"
fi
if grep -qE "$PATTERN_B" "$SCAN_FILE"; then
  findings="${findings}\n  - Bundle finding ID 박제: 'Bundle-N'"
fi
if grep -qE "$PATTERN_C" "$SCAN_FILE"; then
  findings="${findings}\n  - DA 실행 키워드 박제"
fi
if grep -oE "$PATTERN_D" "$SCAN_FILE" 2>/dev/null \
  | awk -v min="$HASH_MIN" -v max="$HASH_MAX" '
       { tok = $0; gsub(/`/, "", tok);
         if (length(tok) >= min && length(tok) <= max && tok ~ /[a-f]/) found = 1 }
       END { exit !found }
     '; then
  findings="${findings}\n  - Partial commit hash 박제 (${HASH_MIN}~${HASH_MAX}자)"
fi

if [ -n "$findings" ]; then
  printf '[pinning-alert] %s on %s 매치:%b\n' "$TOOL_NAME" "$FILE_PATH" "$findings" >&2
fi

exit 0
