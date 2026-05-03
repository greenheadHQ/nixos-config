#!/usr/bin/env bash
# Shared pinning pattern helpers for commit-msg and hook scanners.
# Consumers decide whether a match is warn-only or hard-fail.

# Partial commit hash length bounds: GitHub short hashes are at least 7 chars;
# the upper bound keeps full hashes and long hex blobs out of this guard.
HASH_MIN=7
HASH_MAX=12

# Pattern A: progress counters.
PATTERN_A='\b[Rr][Oo][Uu][Nn][Dd] [0-9]+\b'

# Pattern B: review finding identifier tokens. Suffix must start with a number
# to avoid common natural-language false positives.
PATTERN_B='\b(Correctness|CORRECTNESS|Design|DESIGN|Regression|REGRESSION|Maintainability|MAINTAINABILITY|Security|SECURITY|Hallucination|HALLUCINATION|Side_effect|SIDE_EFFECT|Consistency|CONSISTENCY|Readability|READABILITY|Clean_code|CLEAN_CODE|Yagni|YAGNI|Ngmi|NGMI|CORR|MAINT|MNT|REG|CIR)-[0-9][A-Za-z0-9-]*\b'

# Pattern C: review-mode keywords that should stay out of durable artifacts.
PATTERN_C='\bDA (for_pr|for_plan|피드백|[Rr]ound)\b|\bAuditor [A-Za-z_]+-[0-9]|\bparallel-audit (반영|결과|finding)\b'

# Pattern D: raw/backtick partial hex tokens. Callers apply HASH_MIN/HASH_MAX.
PATTERN_D='\b[a-f0-9]{7,40}\b|`[a-f0-9]+`'

# GitHub issue/PR attachment assets are durable media identifiers, not commits.
# Keep this exact so other URL/path hex tokens remain visible to PATTERN_D.
# The trailing delimiter is captured and restored by the sanitizer.
# Sentence punctuation is only accepted before another delimiter or EOL.
PATTERN_GITHUB_ATTACHMENT_ASSET_URL="https://github\.com/user-attachments/assets/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}([][:space:])}>\"'\`]|\$|[.,;:!?]([][:space:])}>\"'\`]|\$))"

pinning_should_check_path() {
  local path="$1"
  case "$path" in
    *.md | *.sh | *.ipynb) ;;
    /tmp/*body* | /var/folders/*/T/*body*) ;;
    *) return 1 ;;
  esac

  case "$path" in
    */hooks/pinning-alert.sh) return 1 ;;
    */hooks/pinning-guard.sh) return 1 ;;
    */lib/pinning-patterns.sh) return 1 ;;
    scripts/ai/commit-msg-pinning.sh | */scripts/ai/commit-msg-pinning.sh) return 1 ;;
    */skills/run-da/*) return 1 ;;
    */skills/parallel-audit/*) return 1 ;;
    tests/fixtures/* | */tests/fixtures/*) return 1 ;;
    evals/queries.json | */evals/queries.json) return 1 ;;
    eval-workspace/* | */eval-workspace/*) return 1 ;;
  esac

  return 0
}

pinning_sanitize_partial_hash_input() {
  local scan_file="$1"
  sed -E "s#${PATTERN_GITHUB_ATTACHMENT_ASSET_URL}#__GITHUB_ATTACHMENT_ASSET_URL__\\1#g" "$scan_file"
}

pinning_partial_hash_report() {
  local scan_file="$1"
  pinning_sanitize_partial_hash_input "$scan_file" 2>/dev/null \
    | grep -noE "$PATTERN_D" 2>/dev/null \
    | awk -v min="$HASH_MIN" -v max="$HASH_MAX" '
        { idx = index($0, ":"); lineno = substr($0, 1, idx - 1); tok = substr($0, idx + 1);
          gsub(/`/, "", tok); n = length(tok);
          if (n < min || n > max) next;
          if (tok !~ /[a-f]/) next;
          print "         " lineno ": " tok }
      ' || true
}

pinning_findings_text() {
  local scan_file="$1"
  local findings=""

  if grep -qE "$PATTERN_A" "$scan_file"; then
    findings="${findings}\n  - Round counter 박제: 'Round N'"
  fi
  if grep -qE "$PATTERN_B" "$scan_file"; then
    findings="${findings}\n  - Bundle finding ID 박제: 'Bundle-N'"
  fi
  if grep -qE "$PATTERN_C" "$scan_file"; then
    findings="${findings}\n  - DA 실행 키워드 박제"
  fi
  if [ -n "$(pinning_partial_hash_report "$scan_file")" ]; then
    findings="${findings}\n  - Partial commit hash 박제 (${HASH_MIN}~${HASH_MAX}자)"
  fi

  printf '%b' "$findings"
}

pinning_match_count() {
  local scan_file="$1"
  local total=0 count=0

  count=$({ grep -oE "$PATTERN_A" "$scan_file" 2>/dev/null || true; } | wc -l | tr -d ' ')
  total=$((total + count))
  count=$({ grep -oE "$PATTERN_B" "$scan_file" 2>/dev/null || true; } | wc -l | tr -d ' ')
  total=$((total + count))
  count=$({ grep -oE "$PATTERN_C" "$scan_file" 2>/dev/null || true; } | wc -l | tr -d ' ')
  total=$((total + count))
  count=$(pinning_partial_hash_report "$scan_file" | wc -l | tr -d ' ')
  total=$((total + count))

  printf '%s\n' "$total"
}
