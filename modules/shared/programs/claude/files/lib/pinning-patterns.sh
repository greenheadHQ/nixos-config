#!/usr/bin/env bash
# Shared pinning pattern helpers for commit-msg and hook scanners.
# Consumers decide whether a match is warn-only or hard-fail.

# Named indent constant for line:token report rendering. Single SSOT for all
# rendered output (findings_text wrapper).
PINNING_REPORT_INDENT='         '

# Category labels (per-PATTERN). pinning_findings_records emits the label as
# a stable field so callers can map by category code (A/B/C) instead of
# substring-matching the human-readable text.
PINNING_PATTERN_A_LABEL="Round counter 박제: 'Round N'"
PINNING_PATTERN_B_LABEL="Bundle finding ID 박제: 'Bundle-N'"
PINNING_PATTERN_C_LABEL="DA 실행 키워드 박제"

# Pattern A: progress counters.
PATTERN_A='\b[Rr][Oo][Uu][Nn][Dd] [0-9]+\b'

# Pattern B: review finding identifier tokens. Suffix must start with a number
# to avoid common natural-language false positives.
PATTERN_B='\b(Correctness|CORRECTNESS|Design|DESIGN|Regression|REGRESSION|Maintainability|MAINTAINABILITY|Security|SECURITY|Hallucination|HALLUCINATION|Side_effect|SIDE_EFFECT|Consistency|CONSISTENCY|Readability|READABILITY|Clean_code|CLEAN_CODE|Yagni|YAGNI|Ngmi|NGMI|CORR|MAINT|MNT|REG|CIR)-[0-9][A-Za-z0-9-]*\b'

# Pattern C: review-mode keywords that should stay out of durable artifacts.
PATTERN_C='\bDA (for_pr|for_plan|피드백|[Rr]ound)\b|\bAuditor [A-Za-z_]+-[0-9]|\bparallel-audit (반영|결과|finding)\b'

# Canonicalize a path for whitelist comparison. Returns the canonical path on
# stdout when canonicalization succeeds, otherwise prints nothing. Callers
# must treat an empty result as "do not whitelist" (fail-closed) rather than
# falling back to the raw path, because a symlink under a whitelisted DA
# scratch directory could otherwise re-export a repo file as exempt.
pinning_canonicalize_path() {
  local raw="$1"
  local canon=""
  if command -v realpath >/dev/null 2>&1; then
    canon=$(realpath -m "$raw" 2>/dev/null) || canon=""
  fi
  if [ -z "$canon" ] && command -v readlink >/dev/null 2>&1; then
    canon=$(readlink -f "$raw" 2>/dev/null) || canon=""
  fi
  printf '%s\n' "$canon"
}

pinning_canonicalize_existing_parent_path() {
  local raw="$1"
  local abs dir suffix parent
  case "$raw" in
    /*) abs="$raw" ;;
    *) abs="$PWD/$raw" ;;
  esac

  dir="$(dirname "$abs" 2>/dev/null)" || return 1
  suffix="/$(basename "$abs" 2>/dev/null)" || return 1
  while [ ! -d "$dir" ]; do
    [ "$dir" = "/" ] && break
    suffix="/$(basename "$dir" 2>/dev/null)$suffix" || return 1
    parent="$(dirname "$dir" 2>/dev/null)" || return 1
    [ "$parent" != "$dir" ] || break
    dir="$parent"
  done
  [ -d "$dir" ] || return 1
  (
    cd -P "$dir" 2>/dev/null && printf '%s%s\n' "$PWD" "$suffix"
  )
}

pinning_project_root_path() {
  local root="${PINNING_PROJECT_ROOT:-}"
  local canon
  if [ -n "$root" ]; then
    case "$root" in
      *'/../'* | '../'* | *'/..' | '..' ) return 1 ;;
    esac
  elif command -v git >/dev/null 2>&1; then
    root="$(git rev-parse --show-toplevel 2>/dev/null)" || root=""
  fi
  [ -n "$root" ] || root="$PWD"
  [ -d "$root" ] || return 1

  canon="$(pinning_canonicalize_path "$root")"
  if [ -z "$canon" ] && [ ! -L "$root" ]; then
    canon="$(pinning_canonicalize_existing_parent_path "$root")"
  fi
  [ -n "$canon" ] || return 1
  case "$canon" in
    *'/../'* | '../'* | *'/..' | '..' ) return 1 ;;
  esac
  printf '%s\n' "$canon"
}

pinning_should_check_path() {
  local raw="$1"
  # Reject path traversal segments at the raw layer so callers cannot
  # smuggle durable repo paths through the DA workspace whitelist via `..`.
  # Match only true segment traversal patterns (`/../`, leading `../`,
  # trailing `/..`) instead of any literal `..` so files whose name happens
  # to contain `..` (e.g. `README..md`) keep the existing exempt contract.
  case "$raw" in
    *'/../'* | '../'* | *'/..' | '..' ) return 0 ;;
  esac
  local path
  path="$(pinning_canonicalize_path "$raw")"
  if [ -z "$path" ] && [ ! -L "$raw" ]; then
    path="$(pinning_canonicalize_existing_parent_path "$raw")"
  fi
  if [ -z "$path" ]; then
    # Canonicalization unavailable, or the raw path is an unresolved symlink:
    # fail-closed and check the path so DA whitelist cannot apply on a fallback
    # that we cannot trust.
    return 0
  fi
  case "$path" in
    *'/../'* | '../'* | *'/..' | '..' ) return 0 ;;
  esac

  if ! pinning_is_prd_or_plan_path "$path"; then
    case "$path" in
      *.md | *.sh | *.ipynb) ;;
      /tmp/*body* | /var/folders/*/T/*body*) ;;
      *) return 1 ;;
    esac
  fi

  case "$path" in
    */hooks/pinning-alert.sh) return 1 ;;
    */hooks/pinning-guard.sh) return 1 ;;
    */lib/pinning-patterns.sh) return 1 ;;
    scripts/ai/commit-msg-pinning.sh | */scripts/ai/commit-msg-pinning.sh) return 1 ;;
    */skills/run-da/*) return 1 ;;
    */skills/parallel-audit/*) return 1 ;;
    tests/fixtures/* | */tests/fixtures/*) return 1 ;;
    eval-workspace/* | */eval-workspace/*) return 1 ;;
    # macOS는 /tmp가 /private/tmp의 symlink, /var가 /private/var의 symlink.
    # realpath -m 등으로 canonicalize되면 /private/* 형태가 되므로 둘 다 매치 필요.
    /tmp/da-*/* | /private/tmp/da-*/*) return 1 ;;
    /var/folders/*/T/da-*/* | /private/var/folders/*/T/da-*/*) return 1 ;;
  esac

  return 0
}

pinning_is_prd_or_plan_path() {
  local raw="$1"
  # Keep this helper fail-closed. It grants a narrow category skip, so path
  # traversal must not be normalized into an allowed PRD/plan segment.
  case "$raw" in
    *'/../'* | '../'* | *'/..' | '..' ) return 1 ;;
  esac

  local path root
  path="$(pinning_canonicalize_path "$raw")"
  if [ -z "$path" ] && [ ! -L "$raw" ]; then
    path="$(pinning_canonicalize_existing_parent_path "$raw")"
  fi
  [ -n "$path" ] || return 1
  case "$path" in
    *'/../'* | '../'* | *'/..' | '..' ) return 1 ;;
  esac

  root="$(pinning_project_root_path)" || return 1
  [ -n "$root" ] || return 1

  case "$path" in
    "$root"/.claude/prds/* | "$root"/.claude/plans/*) return 0 ;;
    *) return 1 ;;
  esac
}

pinning_apply_patch_added_sections() {
  local patch_file="$1"
  awk '
    function emit_added_line() {
      # Record format: <path-length><TAB><path><added-line>
      # The length prefix keeps paths containing tabs from corrupting path
      # attribution. Companion helpers below parse this exact format.
      printf "%d\t%s%s\n", length(path), path, line
    }
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
      emit_added_line()
    }
  ' "$patch_file"
}

pinning_apply_patch_section_paths() {
  local sections_file="$1"
  awk '
    {
      sep = index($0, "\t")
      if (sep == 0) next
      len = substr($0, 1, sep - 1) + 0
      rest = substr($0, sep + 1)
      print substr(rest, 1, len)
    }
  ' "$sections_file" | sort -u
}

pinning_apply_patch_section_lines_for_path() {
  local sections_file="$1"
  local target_path="$2"
  awk -v target="$target_path" '
    {
      sep = index($0, "\t")
      if (sep == 0) next
      len = substr($0, 1, sep - 1) + 0
      rest = substr($0, sep + 1)
      path = substr(rest, 1, len)
      if (path == target) {
        print substr(rest, len + 1)
      }
    }
  ' "$sections_file"
}

# Generic raw matcher for A/B/C — emits TSV records.
_pinning_simple_records() {
  local scan_file="$1" code="$2" pattern="$3" label="$4"
  grep -noE "$pattern" "$scan_file" 2>/dev/null \
    | awk -F: -v code="$code" -v label="$label" '
        { lineno = $1; tok = substr($0, length(lineno) + 2);
          print code "\t" label "\t" lineno ": " tok }
      ' || true
}

# Structured findings API. Output: TSV records, one per match.
# Format: <category_code>\t<label>\t<line>:<token>
# - category_code: stable identifier (A/B/C) — callers branch on this
#   without parsing the human-readable label, which keeps display-string
#   changes from breaking branching logic.
# - label: human-readable category label (sourced from PINNING_PATTERN_*_LABEL)
# - line:token: 1-based line number from grep -n + matched token
pinning_findings_records() {
  local scan_file="$1"

  _pinning_simple_records "$scan_file" "A" "$PATTERN_A" "$PINNING_PATTERN_A_LABEL"
  _pinning_simple_records "$scan_file" "B" "$PATTERN_B" "$PINNING_PATTERN_B_LABEL"
  _pinning_simple_records "$scan_file" "C" "$PATTERN_C" "$PINNING_PATTERN_C_LABEL"
}

_pinning_findings_records_for_prd_or_plan_state() {
  local scan_file="$1"
  local is_prd_or_plan="${2:-}"
  if [ -n "$is_prd_or_plan" ]; then
    pinning_findings_records "$scan_file" | awk -F'\t' '$1 != "A"'
  else
    pinning_findings_records "$scan_file"
  fi
}

_pinning_prd_or_plan_state_for_path() {
  local path="$1"
  if pinning_is_prd_or_plan_path "$path"; then
    printf '1\n'
  fi
}

# Path-aware records keep the generic TSV format. PRD/plan paths suppress only
# category A; categories B/C remain visible there.
pinning_findings_records_for_path() {
  local scan_file="$1"
  local path="$2"
  local is_prd_or_plan
  is_prd_or_plan="$(_pinning_prd_or_plan_state_for_path "$path")"
  _pinning_findings_records_for_prd_or_plan_state "$scan_file" "$is_prd_or_plan"
}

_pinning_render_records() {
  local records
  records="$(cat)"
  [ -n "$records" ] || return 0
  printf '%s\n' "$records" | awk -F'\t' -v indent="$PINNING_REPORT_INDENT" '
    BEGIN { last_code = "" }
    {
      code = $1; label = $2; entry = $3
      if (code != last_code) {
        printf "\n  - %s", label
        last_code = code
      }
      printf "\n%s%s", indent, entry
    }
  '
}

# Render records as human-readable findings text. Output preserves the legacy
# layout (label line per category followed by indented `<line>: <token>`
# evidence lines).
pinning_findings_text() {
  local scan_file="$1"
  pinning_findings_records "$scan_file" | _pinning_render_records
}

_pinning_findings_text_for_prd_or_plan_state() {
  local scan_file="$1"
  local is_prd_or_plan="${2:-}"
  _pinning_findings_records_for_prd_or_plan_state "$scan_file" "$is_prd_or_plan" \
    | _pinning_render_records
}

pinning_match_count() {
  local scan_file="$1"
  pinning_findings_records "$scan_file" | wc -l | tr -d ' '
}

_pinning_match_count_for_prd_or_plan_state() {
  local scan_file="$1"
  local is_prd_or_plan="${2:-}"
  _pinning_findings_records_for_prd_or_plan_state "$scan_file" "$is_prd_or_plan" \
    | wc -l | tr -d ' '
}

pinning_findings_text_for_path() {
  local scan_file="$1"
  local path="$2"
  pinning_findings_records_for_path "$scan_file" "$path" | _pinning_render_records
}

pinning_match_count_for_path() {
  local scan_file="$1"
  local path="$2"
  pinning_findings_records_for_path "$scan_file" "$path" | wc -l | tr -d ' '
}

# Intermediate schema for the delta helper:
# OLD<TAB>code<TAB>token
# NEW<TAB>code<TAB>label<TAB>line-entry<TAB>token
# Delta identity is category code + token; label and line-entry are retained
# only so newly introduced records can be rendered without rescanning.
_pinning_new_findings_records_for_prd_or_plan_state() {
  local old_scan_file="$1"
  local new_scan_file="$2"
  local is_prd_or_plan="${3:-}"
  {
    _pinning_findings_records_for_prd_or_plan_state "$old_scan_file" "$is_prd_or_plan" \
      | awk -F'\t' '{ token = $3; sub(/^[0-9]+: /, "", token); print "OLD\t" $1 "\t" token }'
    _pinning_findings_records_for_prd_or_plan_state "$new_scan_file" "$is_prd_or_plan" \
      | awk -F'\t' '{ token = $3; sub(/^[0-9]+: /, "", token); print "NEW\t" $1 "\t" $2 "\t" $3 "\t" token }'
  } | awk -F'\t' '
    $1 == "OLD" {
      key = $2 SUBSEP $3
      old[key]++
      next
    }
    $1 == "NEW" {
      key = $2 SUBSEP $5
      if (old[key] > 0) {
        old[key]--
        next
      }
      print $2 "\t" $3 "\t" $4
    }
  '
}

_pinning_new_findings_text_for_prd_or_plan_state() {
  local old_scan_file="$1"
  local new_scan_file="$2"
  local is_prd_or_plan="${3:-}"
  _pinning_new_findings_records_for_prd_or_plan_state \
      "$old_scan_file" "$new_scan_file" "$is_prd_or_plan" \
    | _pinning_render_records
}

pinning_guard_findings_text_for_path() {
  local old_scan_file="$1"
  local new_scan_file="$2"
  local path="$3"
  local is_prd_or_plan
  is_prd_or_plan="$(_pinning_prd_or_plan_state_for_path "$path")"

  if [ -n "$is_prd_or_plan" ]; then
    _pinning_new_findings_text_for_prd_or_plan_state \
      "$old_scan_file" "$new_scan_file" "$is_prd_or_plan"
    return
  fi

  local old_count new_count
  old_count="$(_pinning_match_count_for_prd_or_plan_state "$old_scan_file" "$is_prd_or_plan")"
  new_count="$(_pinning_match_count_for_prd_or_plan_state "$new_scan_file" "$is_prd_or_plan")"
  if [ "$new_count" -gt "$old_count" ]; then
    _pinning_findings_text_for_prd_or_plan_state "$new_scan_file" "$is_prd_or_plan"
  fi
}
