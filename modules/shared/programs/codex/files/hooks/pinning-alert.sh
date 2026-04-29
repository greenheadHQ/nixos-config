#!/usr/bin/env bash
# pinning-alert.sh — Codex 0.124+ PostToolUse warn-only alert.
# 정책 출처: https://github.com/greenheadHQ/nixos-config/issues/603
# 패턴 SSOT: scripts/ai/commit-msg-pinning.sh (PATTERN_A/B/C/D + HASH_MIN/MAX).
#   ↑ 본 파일은 그 SSOT의 inline 사본이다. commit-msg-pinning.sh 패턴을 갱신할 때 본 파일 +
#     Claude 사본(modules/shared/programs/claude/files/hooks/pinning-alert.sh)도 함께
#     갱신해야 한다. lockstep 동등성은 scripts/ai/verify-ai-compat.sh가 PATTERN_A/B/C/D +
#     HASH_MIN/MAX 변수 라인 동등성으로 강제한다 (helper/scan/eligibility까지 cover하지는
#     않으므로 _should_check_path / _scan_file 본문 변경 시 두 사본을 수동 정합 필요).
# 정책: warn-only — stderr alert + exit 0. permissionDecision 사용 금지.
#
# pipefail 안전 모델 (commit-msg-pinning.sh:26-29와 동일 SSOT):
#   `printf '%s' "$TEXT" | grep -qE ...` 조합은 큰 입력에서 grep -q 조기 종료 + SIGPIPE로
#   producer가 nonzero를 반환해 pipefail 환경에서 silent miss를 만든다. 검사 텍스트를 mktemp
#   파일에 저장하고 `grep -qE "$PATTERN" "$tmpfile"`로 검사하여 회피한다.
#
# Codex 0.125 PostToolUse stdin schema 실측 (issue #603 Phase 0):
#   - tool_name="Bash"        → tool_input.command (shell command text)
#   - tool_name="apply_patch" → tool_input.command (V4A patch envelope text)
#       envelope: '*** Begin Patch\n*** {Update,Add,Delete} File: <path>\n@@\n+<line>\n*** End Patch'
#       matcher alias `Edit|Write|NotebookEdit`로 매칭은 트리거되지만 stdin tool_name은 apply_patch.
#       (openai/codex#18391 + 본 PR Phase 0 echo hook 캡처)
#   - tool_name="Edit|Write|NotebookEdit" → Claude Code-호환 키 (.tool_input.file_path / .new_string /
#     .content / .new_source). Codex 0.125에서는 미관측이지만 미래 호환을 위해 fallback path 유지.
#
# apply_patch attribution 모델:
#   patch envelope을 파일 섹션별로 분리하여, eligible path마다 그 파일의 added line(`^+`,
#   `*** Begin/End Patch` 헤더 제외)만 검사한다. 삭제 라인(`^-`)·context 라인(` `)·헤더는 제외.
#   매치된 파일 path를 alert에 보고. multi-file patch에서 첫 파일만 보고하던 구조 회귀 (#603 DA for_pr Design-1/Regression-2).
set -euo pipefail

# 환경 가드(CLAUDECODE/CODEX_PROGRAMMATIC) 없음 — PostToolUse pinning-alert는 자식 LLM 세션의
# Edit/Write/apply_patch를 부모가 보지 못하기 때문에 항상 검사해야 한다
# (record-prompt-submit/stop-notification 등의 부모-처리-신뢰 가드와 의미가 다르다).
# Claude Code 안에서 Codex programmatic subprocess가 호출되면 부모 Claude hook은
# Bash matcher만 검사하고 Codex 안의 Edit/apply_patch는 못 보므로 자식 Codex hook이 직접
# 검사해야 박제를 놓치지 않는다. 중복 alert는 운영 noise로 수용.

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0

# tool_name 사전 분기 — Codex의 PostToolUse는 모든 tool 호출(Bash 포함)에 발화하므로,
# 검사 대상이 아닌 tool은 SCAN_DIR 생성/cleanup 비용 없이 즉시 종료한다.
case "$TOOL_NAME" in
  Edit | Write | NotebookEdit | apply_patch) ;;
  *) exit 0 ;;
esac

# Pinning hash 길이 경계 (commit-msg-pinning.sh와 동일)
HASH_MIN=7
HASH_MAX=12

# Patterns (commit-msg-pinning.sh PATTERN_A~D와 동일 — lockstep 갱신)
PATTERN_A='\b[Rr][Oo][Uu][Nn][Dd] [0-9]+\b'
PATTERN_B='\b(Correctness|CORRECTNESS|Design|DESIGN|Regression|REGRESSION|Maintainability|MAINTAINABILITY|Security|SECURITY|Hallucination|HALLUCINATION|Side_effect|SIDE_EFFECT|Consistency|CONSISTENCY|Readability|READABILITY|Clean_code|CLEAN_CODE|Yagni|YAGNI|Ngmi|NGMI|CORR|MAINT|MNT|REG|CIR)-[0-9][A-Za-z0-9-]*\b'
PATTERN_C='\bDA (for_pr|for_plan|피드백|[Rr]ound)\b|\bAuditor [A-Za-z_]+-[0-9]|\bparallel-audit (반영|결과|finding)\b'
PATTERN_D='\b[a-f0-9]{7,40}\b|`[a-f0-9]+`'

# 임시 디렉토리 (모든 mktemp 파일을 한 곳에 두고 EXIT trap으로 일괄 정리).
SCAN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pinning-scan-XXXXXX") || exit 0
trap 'rm -rf "$SCAN_DIR"' EXIT

# 공통: file path가 본 hook 검사 대상에 부합하는지 판정. 통과하면 0, skip이면 1.
# mktemp tmpfile 한정: 실측 35건 모두 `body` substring(PR/issue body 작성 임시) → 그 형태로 한정.
# 일반 코드 확장자(.ts/.py/.nix 등)가 임시 디렉토리 안에 있어도 false positive 회피.
_should_check_path() {
  local p="$1"
  case "$p" in
    *.md | *.sh) ;;
    /tmp/*body* | /var/folders/*/T/*body*) ;;
    *) return 1 ;;
  esac
  case "$p" in
    */hooks/pinning-alert.sh) return 1 ;;
    */scripts/ai/commit-msg-pinning.sh) return 1 ;;
    */skills/run-da/*) return 1 ;;
    */skills/parallel-audit/*) return 1 ;;
    */tests/fixtures/*) return 1 ;;
    */evals/queries.json) return 1 ;;
    */eval-workspace/*) return 1 ;;
  esac
  return 0
}

# 공통: SCAN_FILE을 받아 패턴 4종 검사 후 매치된 finding 라인을 stdout으로 출력 (없으면 빈 출력).
# 파일 기반 grep으로 SIGPIPE 회피 (commit-msg-pinning.sh와 동일 안전 모델).
_scan_file() {
  local scan_file="$1"
  local out=""
  if grep -qE "$PATTERN_A" "$scan_file"; then
    out="${out}\n  - Round counter 박제: 'Round N'"
  fi
  if grep -qE "$PATTERN_B" "$scan_file"; then
    out="${out}\n  - Bundle finding ID 박제: 'Bundle-N'"
  fi
  if grep -qE "$PATTERN_C" "$scan_file"; then
    out="${out}\n  - DA 실행 키워드 박제"
  fi
  if grep -oE "$PATTERN_D" "$scan_file" 2>/dev/null \
    | awk -v min="$HASH_MIN" -v max="$HASH_MAX" '
        { tok = $0; gsub(/`/, "", tok);
          if (length(tok) >= min && length(tok) <= max && tok ~ /[a-f]/) found = 1 }
        END { exit !found }
      '; then
    out="${out}\n  - Partial commit hash 박제 (${HASH_MIN}~${HASH_MAX}자)"
  fi
  printf '%b' "$out"
}

case "$TOOL_NAME" in
  Edit | Write | NotebookEdit)
    # Claude Code-호환 단일 파일 케이스 (Codex 0.125에서는 미관측이지만 미래 호환).
    FILE_PATH=$(printf '%s' "$INPUT" | jq -r '
      .tool_input.file_path
      // .tool_input.notebook_path
      // empty
    ' 2>/dev/null)
    [ -n "$FILE_PATH" ] || exit 0
    _should_check_path "$FILE_PATH" || exit 0

    case "$TOOL_NAME" in
      Edit) TEXT=$(printf '%s' "$INPUT" | jq -r '.tool_input.new_string // empty' 2>/dev/null) ;;
      Write) TEXT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // empty' 2>/dev/null) ;;
      NotebookEdit) TEXT=$(printf '%s' "$INPUT" | jq -r '.tool_input.new_source // empty' 2>/dev/null) ;;
    esac
    [ -n "$TEXT" ] || exit 0

    SCAN_FILE="$SCAN_DIR/scan.txt"
    printf '%s' "$TEXT" > "$SCAN_FILE"

    findings="$(_scan_file "$SCAN_FILE")"
    if [ -n "$findings" ]; then
      printf '[pinning-alert] %s on %s 매치:%b\n' "$TOOL_NAME" "$FILE_PATH" "$findings" >&2
    fi
    ;;
  apply_patch)
    # Codex 0.125 V4A apply_patch envelope을 파일 섹션별로 분해한다.
    # 각 파일의 added line(`^+`)만 추출해 그 파일이 eligible일 때 그 파일에 한정해 박제 검사.
    # 삭제(`^-`)·context(` `)·헤더(`^***`)는 제외하므로 박제 패턴 제거 patch는 alert를 발생시키지 않는다.
    # multi-file patch에서도 매치된 파일 단위로 정확히 보고한다.
    PATCH_TEXT=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
    [ -n "$PATCH_TEXT" ] || exit 0

    PATCH_FILE="$SCAN_DIR/patch.txt"
    printf '%s' "$PATCH_TEXT" > "$PATCH_FILE"

    # awk로 파일별 added line을 분리. 출력: <path>\t<line> per line.
    # path는 다음 헤더가 나오기 전까지 유지. End Patch 또는 새 File 헤더에서 reset.
    # `*** Move to: <newpath>`를 만나면 current section의 effective path를 새 경로로 갱신
    # (V4A rename 케이스: old.txt → new.md에서 새 산출물의 확장자 기준 eligibility 판단 — 이슈 #603 R3 Correctness-1/Regression-1).
    SECTIONS_FILE="$SCAN_DIR/sections.tsv"
    awk '
      /^\*\*\* (Update|Add|Delete) File: / {
        path = $0
        sub(/^\*\*\* [A-Za-z]+ File: /, "", path)
        next
      }
      /^\*\*\* Move to: / {
        newpath = $0
        sub(/^\*\*\* Move to: /, "", newpath)
        path = newpath
        next
      }
      /^\*\*\* End Patch/ { path = ""; next }
      path != "" && /^\+/ && !/^\*\*\*/ {
        line = $0
        sub(/^\+/, "", line)
        printf "%s\t%s\n", path, line
      }
    ' "$PATCH_FILE" > "$SECTIONS_FILE"

    [ -s "$SECTIONS_FILE" ] || exit 0

    # 각 eligible path마다 added line만 모아 검사.
    # scan 파일명에 path 원문을 사용하지 않는다 — 긴 nested path가 NAME_MAX(보통 255 bytes)를
    # 초과하면 redirection이 'File name too long'으로 실패하고 set -e로 hook이 exit 1이 되어
    # warn-only 계약을 위반한다 (#603 DA for_pr R2 Correctness-1/Regression-1). path는 보고용
    # 변수로만 유지하고 scan 파일은 mktemp으로 익명 basename을 받는다.
    awk -F'\t' '{print $1}' "$SECTIONS_FILE" | sort -u | while IFS= read -r p; do
      [ -n "$p" ] || continue
      if ! _should_check_path "$p"; then
        continue
      fi
      PATH_SCAN_FILE=$(mktemp "$SCAN_DIR/scan-XXXXXX")
      awk -F'\t' -v target="$p" '$1 == target { print substr($0, length(target) + 2) }' \
        "$SECTIONS_FILE" > "$PATH_SCAN_FILE"
      [ -s "$PATH_SCAN_FILE" ] || continue
      findings="$(_scan_file "$PATH_SCAN_FILE")"
      if [ -n "$findings" ]; then
        printf '[pinning-alert] apply_patch on %s 매치:%b\n' "$p" "$findings" >&2
      fi
    done
    ;;
  *) exit 0 ;;
esac

exit 0
