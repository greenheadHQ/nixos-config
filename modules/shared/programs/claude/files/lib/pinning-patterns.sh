#!/usr/bin/env bash
# Shared pinning pattern helpers for commit-msg and hook scanners.
# Consumers decide whether a match is warn-only or hard-fail.
#
# USED-BY:
#   claude/files/hooks/pinning-alert.sh   # via $PINNING_LIB
#   claude/files/hooks/pinning-guard.sh   # via $PINNING_LIB
#   codex/files/hooks/pinning-alert.sh    # via $PINNING_LIB
#   codex/files/hooks/pinning-guard.sh    # via $PINNING_LIB
#   scripts/ai/commit-msg-pinning.sh      # via $PINNING_LIB
#
# scripts/ai/verify-ai-compat.sh 가 본 USED-BY 선언과 실제 source 호출 일치를 oracle로 검증.

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

# Pattern C: review-mode keywords. Split into workflow and volatile sub-patterns so
# stable procedural guidance (e.g. running PR-mode review later) can stay in plan /
# handoff / PRD bodies while concrete volatile review metadata stays denied.
# - workflow sub-pattern: DA execution mode names that legitimately appear in
#   stable procedural guidance text. PreToolUse hard-fail records suppress these
#   on allowed paths; diagnostic records (warn-only) still emit them.
# - volatile sub-pattern: round counter / feedback / numbered reviewer label /
#   parallel-audit follow-up action tokens. These remain hard-fail everywhere.
#
# Note on word boundary across multibyte tokens: GNU grep (gnugrep-3.12) does
# not treat the transition between an ASCII word char and a Hangul (multibyte
# UTF-8) char as a word boundary, so the trailing `\b` after a Hangul
# alternative silently fails to match (BSD `grep` does match). To keep the
# library working under both grep implementations, Hangul alternatives are
# written without a trailing `\b` while ASCII alternatives retain it.
PINNING_PATTERN_C_WORKFLOW='\bDA (for_pr|for_plan)\b'
PINNING_PATTERN_C_VOLATILE='\bDA 피드백|\bDA [Rr]ound\b|\bAuditor [A-Za-z_]+-[0-9][A-Za-z0-9-]*\b|\bparallel-audit (반영|결과)|\bparallel-audit finding\b'

# Combined PATTERN_C preserves backward-compat for `verify-ai-compat.sh`'s
# exported-var inventory check. `pinning_findings_records` now grep's the
# workflow and volatile sub-patterns separately so it can tag each record;
# this variable is no longer read inside the library.
# shellcheck disable=SC2034
PATTERN_C="$PINNING_PATTERN_C_WORKFLOW|$PINNING_PATTERN_C_VOLATILE"

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

# Raw traversal segment matcher. Consolidates the
# `*'/../'* | '../'* | *'/..' | '..'` glob check used across path-aware
# helpers and the D-1 token-delta trigger so a future tweak only updates
# this single shape. Returns 0 when the input contains a true traversal
# segment, non-zero otherwise.
_pinning_raw_path_has_traversal() {
  case "$1" in
    *'/../'* | '../'* | *'/..' | '..' ) return 0 ;;
  esac
  return 1
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
    if _pinning_raw_path_has_traversal "$root"; then
      return 1
    fi
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
  if _pinning_raw_path_has_traversal "$canon"; then
    return 1
  fi
  printf '%s\n' "$canon"
}

pinning_should_check_path() {
  local raw="$1"
  # Reject path traversal segments at the raw layer so callers cannot
  # smuggle durable repo paths through the DA workspace whitelist via `..`.
  # Match only true segment traversal patterns (`/../`, leading `../`,
  # trailing `/..`) instead of any literal `..` so files whose name happens
  # to contain `..` (e.g. `README..md`) keep the existing exempt contract.
  if _pinning_raw_path_has_traversal "$raw"; then
    return 0
  fi
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
  if _pinning_raw_path_has_traversal "$path"; then
    return 0
  fi

  # Eligibility taxonomy goes through helper composition so canonical aliases
  # and issue-draft staging stay in lockstep with the workflow allow predicate.
  # Plain extension whitelist still applies for anything outside the policy
  # categories (general .md / .sh / .ipynb edits).
  if ! pinning_is_prd_or_plan_path "$raw" \
     && ! pinning_is_body_temp_path "$raw" \
     && ! pinning_is_issue_draft_path "$raw"; then
    case "$path" in
      *.md | *.sh | *.ipynb) ;;
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

# Workflow policy path category glob source. Single owner of the glob
# enumeration for the workflow-allow path taxonomy. Path helpers + the
# raw-shape classifier delegate to this so the supported policy categories
# (PRD/plan, body temp, issue-draft) stay in lockstep.
#
# Args:
#   $1 path     — already canonicalized (or raw, for the D-1 classifier) path
#   $2 category — one of "prd_or_plan", "body_temp", "issue_draft"
#   $3 root     — required only for category="prd_or_plan" (project root for
#                 the `.claude/{prds,plans}/*` glob). Ignored by the other
#                 categories; caller may omit the argument or pass "".
_pinning_path_category_glob_match() {
  local path="$1" category="$2" root="${3:-}"
  case "$category" in
    prd_or_plan)
      [ -n "$root" ] || return 1
      case "$path" in
        "$root"/.claude/prds/* | "$root"/.claude/plans/*) return 0 ;;
      esac
      ;;
    body_temp)
      case "$path" in
        /tmp/*-body* | /var/folders/*/T/*-body*) return 0 ;;
        /private/tmp/*-body* | /private/var/folders/*/T/*-body*) return 0 ;;
      esac
      ;;
    issue_draft)
      case "$path" in
        /tmp/issue-draft/* | /private/tmp/issue-draft/*) return 0 ;;
      esac
      ;;
  esac
  return 1
}

pinning_is_prd_or_plan_path() {
  local raw="$1"
  # Keep this helper fail-closed. It grants a narrow category skip, so path
  # traversal must not be normalized into an allowed PRD/plan segment.
  if _pinning_raw_path_has_traversal "$raw"; then
    return 1
  fi

  local path root
  path="$(pinning_canonicalize_path "$raw")"
  if [ -z "$path" ] && [ ! -L "$raw" ]; then
    path="$(pinning_canonicalize_existing_parent_path "$raw")"
  fi
  [ -n "$path" ] || return 1
  if _pinning_raw_path_has_traversal "$path"; then
    return 1
  fi

  root="$(pinning_project_root_path)" || return 1
  [ -n "$root" ] || return 1

  _pinning_path_category_glob_match "$path" "prd_or_plan" "$root"
}

# Canonicalize a raw path for policy-category matching with fail-closed
# traversal guards on both raw and canonicalized forms. Returns the canonical
# path on stdout when safe, exits non-zero otherwise. Callers should treat a
# non-zero exit as "this path is outside any policy category" and bail.
_pinning_canonical_policy_path_fail_closed() {
  local raw="$1"
  if _pinning_raw_path_has_traversal "$raw"; then
    return 1
  fi
  local path
  path="$(pinning_canonicalize_path "$raw")"
  if [ -z "$path" ] && [ ! -L "$raw" ]; then
    path="$(pinning_canonicalize_existing_parent_path "$raw")"
  fi
  [ -n "$path" ] || return 1
  if _pinning_raw_path_has_traversal "$path"; then
    return 1
  fi
  printf '%s\n' "$path"
}

# Body temp paths used as durable bodies (e.g. PR / issue body file references).
# Matches both the raw `/tmp` and `/var/folders/.../T` forms, plus the macOS
# canonical aliases under `/private`. The dash-prefix `*-body*` glob is narrower
# than a bare `*body*` substring so unrelated paths like `/tmp/everybody.md`
# stay outside the workflow allow scope. Fail-closed on traversal so a
# body-temp raw path cannot be smuggled into the workflow allow predicate.
pinning_is_body_temp_path() {
  local path
  path="$(_pinning_canonical_policy_path_fail_closed "$1")" || return 1
  _pinning_path_category_glob_match "$path" "body_temp"
}

# Issue / PR body draft staging directory. Separate from body_temp so the
# helper name matches its taxonomy. macOS canonical alias under `/private` is
# treated equivalently.
pinning_is_issue_draft_path() {
  local path
  path="$(_pinning_canonical_policy_path_fail_closed "$1")" || return 1
  _pinning_path_category_glob_match "$path" "issue_draft"
}

# Raw-tolerant workflow policy shape classifier. Distinct from the fail-closed
# allow predicate (pinning_allows_workflow_pattern_c_for_path): this helper
# runs on the raw input string so the D-1 token-delta branch can route
# traversal raw paths whose shape would have matched a workflow policy
# category if they had been canonical. Shares the path-category glob source
# via _pinning_path_category_glob_match. The helper is intentionally kept
# separate from the allow predicate (single caller is OK) so the two
# opposite responsibilities — fail-closed allow vs traversal-tolerant shape —
# never share an interface. Used by D-1 only.
#
# Path lookup order:
#   1. Raw input — catches absolute traversal like `/tmp/<x>-body/../escape.md`
#      whose absolute prefix already matches a category glob.
#   2. Canonicalized input — catches relative traversal like
#      `./.claude/prds/../plans/foo.md` where the raw string cannot match
#      an absolute glob anchor but the canonical result does. Mirrors the
#      canonicalize pattern in pinning_allows_workflow_pattern_c_for_path so
#      the D-1 branch stays in lockstep with which paths the allow predicate
#      considers part of a workflow policy category.
_pinning_raw_path_is_workflow_policy_shape() {
  local raw="$1"
  local root
  root="$(pinning_project_root_path 2>/dev/null)" || root=""
  if _pinning_path_category_glob_match "$raw" "prd_or_plan" "$root" \
     || _pinning_path_category_glob_match "$raw" "body_temp" \
     || _pinning_path_category_glob_match "$raw" "issue_draft"; then
    return 0
  fi
  local path
  path="$(pinning_canonicalize_path "$raw")"
  if [ -z "$path" ] && [ ! -L "$raw" ]; then
    path="$(pinning_canonicalize_existing_parent_path "$raw")"
  fi
  [ -n "$path" ] || return 1
  if _pinning_path_category_glob_match "$path" "prd_or_plan" "$root" \
     || _pinning_path_category_glob_match "$path" "body_temp" \
     || _pinning_path_category_glob_match "$path" "issue_draft"; then
    return 0
  fi
  return 1
}

# Workflow allow predicate for PreToolUse hard-fail. Returns 0 when the
# canonicalized path is one of the policy categories (PRD / plan / body temp /
# issue-draft). Traversal raw paths are fail-closed so this never opens a
# bypass for volatile metadata. The body re-checks traversal after
# canonicalize because `realpath -m` does not always collapse `../` (e.g.
# when an intermediate symlink escapes the policy directory), so the second
# pass keeps the fail-closed contract under all canonicalize paths.
pinning_allows_workflow_pattern_c_for_path() {
  local raw="$1"
  if _pinning_raw_path_has_traversal "$raw"; then
    return 1
  fi
  local path root
  path="$(pinning_canonicalize_path "$raw")"
  if [ -z "$path" ] && [ ! -L "$raw" ]; then
    path="$(pinning_canonicalize_existing_parent_path "$raw")"
  fi
  [ -n "$path" ] || return 1
  if _pinning_raw_path_has_traversal "$path"; then
    return 1
  fi
  root="$(pinning_project_root_path 2>/dev/null)" || root=""
  if _pinning_path_category_glob_match "$path" "prd_or_plan" "$root" \
     || _pinning_path_category_glob_match "$path" "body_temp" \
     || _pinning_path_category_glob_match "$path" "issue_draft"; then
    return 0
  fi
  return 1
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

# Generic raw matcher for A/B — emits 3-column TSV records.
# PATTERN_C sub-pattern handling lives in `_pinning_pattern_c_records_sorted`,
# which emits the optional 4-th `sub_tag` column (workflow / volatile) so
# consumers can branch on the sub-pattern without re-parsing the matched
# token text.
_pinning_simple_records() {
  local scan_file="$1" code="$2" pattern="$3" label="$4"
  grep -noE "$pattern" "$scan_file" 2>/dev/null \
    | awk -F: -v code="$code" -v label="$label" '
        {
          lineno = $1
          tok = substr($0, length(lineno) + 2)
          print code "\t" label "\t" lineno ": " tok
        }
      ' || true
}

# Category C emitter that interleaves the workflow + volatile sub-pattern
# hits by line and same-line byte offset so the rendered record order
# matches the file's left-to-right scan order (the order a single combined
# grep would have produced). Without this, two separate sub-pattern grep
# calls would emit all workflow records before any volatile record even when
# the volatile token comes earlier in the file. Uses `grep -bno` to expose
# the byte offset for tie-breaking inside the same line and strips the
# sort-key columns before yielding the canonical TSV record format.
_pinning_pattern_c_records_sorted() {
  local scan_file="$1"
  # awk script body — single-quoted on purpose so awk vars ($1/$2/$0) are not
  # expanded by the shell. label / sub_tag are injected via `awk -v` below.
  # shellcheck disable=SC2016
  local _awk_emit='
        {
          lineno = $1
          byteoff = $2
          prefix_len = length(lineno) + length(byteoff) + 2
          tok = substr($0, prefix_len + 1)
          printf "%d\t%d\tC\t%s\t%d: %s\t%s\n", lineno, byteoff, label, lineno, tok, sub_tag
        }
      '
  {
    grep -bnoE "$PINNING_PATTERN_C_WORKFLOW" "$scan_file" 2>/dev/null \
      | awk -F: -v label="$PINNING_PATTERN_C_LABEL" -v sub_tag="workflow" "$_awk_emit" || true
    grep -bnoE "$PINNING_PATTERN_C_VOLATILE" "$scan_file" 2>/dev/null \
      | awk -F: -v label="$PINNING_PATTERN_C_LABEL" -v sub_tag="volatile" "$_awk_emit" || true
  } | sort -t$'\t' -k1,1n -k2,2n \
    | cut -f3-
}

# Structured findings API. Output: TSV records, one per match.
# Format: <category_code>\t<label>\t<line>:<token>[\t<sub>]
# - category_code: stable identifier (A/B/C) — callers branch on this
#   without parsing the human-readable label, which keeps display-string
#   changes from breaking branching logic.
# - label: human-readable category label (sourced from PINNING_PATTERN_*_LABEL)
# - line:token: 1-based line number from grep -n + matched token
# - sub: optional sub-category tag (currently "workflow" / "volatile" for
#   category C). Empty for A and B records. PreToolUse hard-fail consumers
#   branch on this tag instead of re-parsing the matched token.
pinning_findings_records() {
  local scan_file="$1"

  _pinning_simple_records "$scan_file" "A" "$PATTERN_A" "$PINNING_PATTERN_A_LABEL"
  _pinning_simple_records "$scan_file" "B" "$PATTERN_B" "$PINNING_PATTERN_B_LABEL"
  _pinning_pattern_c_records_sorted "$scan_file"
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

# PreToolUse hard-fail records (state-aware). PATTERN_A suppression mirrors the
# existing PRD/plan path policy. PATTERN_C workflow sub-pattern is suppressed
# only when the caller's path allows workflow tokens (PRD/plan + body temp +
# issue-draft). PATTERN_C volatile sub-pattern is never suppressed. Branching
# uses the stable sub-category tag emitted by `pinning_findings_records`
# (4th TSV column) so the token text is not re-parsed here.
_pinning_findings_records_for_state() {
  local scan_file="$1"
  local is_prd_or_plan="${2:-}"
  local allows_workflow="${3:-}"
  pinning_findings_records "$scan_file" \
    | awk -F'\t' \
        -v is_prd_or_plan="$is_prd_or_plan" \
        -v allows_workflow="$allows_workflow" '
      {
        code = $1; sub_tag = $4
        if (code == "A" && is_prd_or_plan != "") next
        if (code == "C" && allows_workflow != "" && sub_tag == "workflow") next
        print
      }
    '
}

# Delta helper for PreToolUse hard-fail (state-aware). Intermediate schema:
# OLD<TAB>code<TAB>token / NEW<TAB>code<TAB>label<TAB>line-entry<TAB>token.
# Delta identity is category code + token; label and line-entry are retained
# only so newly introduced records can be rendered without rescanning.
_pinning_new_findings_records_for_state() {
  local old_scan_file="$1"
  local new_scan_file="$2"
  local is_prd_or_plan="${3:-}"
  local allows_workflow="${4:-}"
  {
    _pinning_findings_records_for_state "$old_scan_file" "$is_prd_or_plan" "$allows_workflow" \
      | awk -F'\t' '{ token = $3; sub(/^[0-9]+: /, "", token); print "OLD\t" $1 "\t" token }'
    _pinning_findings_records_for_state "$new_scan_file" "$is_prd_or_plan" "$allows_workflow" \
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

# PreToolUse hard-fail records API (delta-aware). Used by Edit/Write/NotebookEdit
# branches where old + new scan files are both available. Path-aware semantics:
# - PRD/plan path: token delta (consistent with existing PRD/plan behavior).
# - traversal raw path whose shape matches a workflow policy category
#   (body temp / issue-draft / PRD-plan canonical alias): token delta with
#   allows_workflow="" so workflow tokens are not suppressed. The
#   workflow allow predicate fail-closes on traversal raw paths, so without
#   this branch an equal-count `category-B token → category-C workflow token`
#   replacement at a traversal raw path would slip past the outside
#   count-gate (new_count == old_count) and pin a workflow token into a
#   durably-shared body. The split helpers separate the trigger
#   (_pinning_raw_path_has_traversal + _pinning_raw_path_is_workflow_policy_shape)
#   from the fail-closed allow predicate so each helper keeps a single
#   responsibility. Token-delta applies to the full delta surface — equal-count
#   replacements and `old_count > new_count` edits that introduce a new token
#   are both denied, matching the security intent.
# - other non-PRD/plan path: outside count-gate — emit records only when the
#   workflow-suppressed new-count strictly exceeds the workflow-suppressed
#   old-count. This preserves the existing outside equal-count clean contract
#   for plain markdown / shell / notebook edits.
pinning_guard_findings_records_for_path() {
  local old_scan_file="$1"
  local new_scan_file="$2"
  local path="$3"
  local is_prd_or_plan="" allows_workflow=""
  is_prd_or_plan="$(_pinning_prd_or_plan_state_for_path "$path")"
  if pinning_allows_workflow_pattern_c_for_path "$path"; then
    allows_workflow="1"
  fi

  if [ -n "$is_prd_or_plan" ]; then
    _pinning_new_findings_records_for_state \
      "$old_scan_file" "$new_scan_file" "$is_prd_or_plan" "$allows_workflow"
    return
  fi

  if _pinning_raw_path_has_traversal "$path" \
     && _pinning_raw_path_is_workflow_policy_shape "$path"; then
    # is_prd_or_plan="" + allows_workflow="" — traversal raw paths must keep
    # the workflow deny contract (no PATTERN_A suppression, no workflow
    # suppression) so the token-delta surfaces the smuggled workflow token.
    _pinning_new_findings_records_for_state \
      "$old_scan_file" "$new_scan_file" "" ""
    return
  fi

  local old_count new_count
  old_count="$(_pinning_findings_records_for_state "$old_scan_file" "" "$allows_workflow" | wc -l | tr -d ' ')"
  new_count="$(_pinning_findings_records_for_state "$new_scan_file" "" "$allows_workflow" | wc -l | tr -d ' ')"
  if [ "$new_count" -gt "$old_count" ]; then
    _pinning_findings_records_for_state "$new_scan_file" "" "$allows_workflow"
  fi
}

# PreToolUse hard-fail records API for single-scan inputs (apply_patch only
# sees added lines, so delta logic does not apply). Path-aware suppression
# of PATTERN_A (PRD/plan) and PATTERN_C workflow sub-pattern matches the
# delta API above.
pinning_guard_findings_records_for_scan_path() {
  local scan_file="$1"
  local path="$2"
  local is_prd_or_plan="" allows_workflow=""
  is_prd_or_plan="$(_pinning_prd_or_plan_state_for_path "$path")"
  if pinning_allows_workflow_pattern_c_for_path "$path"; then
    allows_workflow="1"
  fi
  _pinning_findings_records_for_state "$scan_file" "$is_prd_or_plan" "$allows_workflow"
}

pinning_guard_findings_text_for_scan_path() {
  local scan_file="$1"
  local path="$2"
  pinning_guard_findings_records_for_scan_path "$scan_file" "$path" \
    | _pinning_render_records
}

# Text wrapper for the delta-aware PreToolUse hard-fail records API. Signature
# preserved so existing Edit/Write/NotebookEdit consumers keep working without
# code changes.
pinning_guard_findings_text_for_path() {
  local old_scan_file="$1"
  local new_scan_file="$2"
  local path="$3"
  pinning_guard_findings_records_for_path "$old_scan_file" "$new_scan_file" "$path" \
    | _pinning_render_records
}
