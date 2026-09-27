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
# a stable field so callers can map by category code (A/B/C/D) instead of
# substring-matching the human-readable text.
# The D label carries its own retry hint because every consumer renders the
# label, so the guard/alert/commit-msg outputs all tell the author what to drop.
PINNING_PATTERN_A_LABEL="Round counter 박제: 'Round N'"
PINNING_PATTERN_B_LABEL="Bundle finding ID 박제: 'Bundle-N'"
PINNING_PATTERN_C_LABEL="DA 실행 키워드 박제"
PINNING_PATTERN_D_LABEL="Claude 세션 URL 박제: 세션 URL과 'Claude-Session:' 트레일러 줄을 빼고 다시 시도"

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

# Pattern D: Claude Code session URLs (issue #1422) — the claude.ai `/code/session_<id>`
# address that session attribution appends as a `Claude-Session:` commit trailer or a
# PR-body link. Only that path shape is matched, so other claude.ai addresses and
# documentation links pass. The id must be at least 20 ASCII alphanumerics: real session
# ids are 24 (observed in session links the harness hands out), and the margin keeps
# them caught if the length shifts slightly. Shorter or non-alphanumeric ids pass, so
# documentation placeholders such as `session_<id>`, `session_XXXXXXXX`,
# `session_abc123`, and `session_id` stay clean. The host is matched in lowercase only,
# as the harness emits it.
PATTERN_D='\bclaude\.ai/code/session_[A-Za-z0-9]{20,}'

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
    tests/fixtures/* | */tests/fixtures/*) return 1 ;;
    eval-workspace/* | */eval-workspace/*) return 1 ;;
    # DA scratch dynamic TMPDIR shapes — host trust model. extend with caution:
    # 새 TMPDIR scheme 추가는 정책 표면 영구 확장이라 PR review 시 명시 신호로 만든다.
    # macOS는 /tmp가 /private/tmp의 symlink, /var가 /private/var의 symlink.
    # realpath -m 등으로 canonicalize되면 /private/* 형태가 되므로 둘 다 매치 필요.
    /tmp/da-*/* | /private/tmp/da-*/*) return 1 ;;
    # TMPDIR이 임의 prefix를 두고 그 안에 da-* scratch를 만드는 케이스 (issue #852):
    # nix develop의 /tmp/nix-shell.<random>, Claude Code Bash tool의 /tmp/claude-<uid> 등.
    # case glob의 `*`는 `/`를 포함하므로 본 패턴은 실제로는 depth-unbounded 매칭이다
    # (예: /tmp/a/b/da-x/y.md도 매치). 그러나 attacker 모델이 아니라 host trust 범위
    # (개발자 host + lefthook 단일 user)라 안전. 향후 multi-tenant CI에서 호출되면 재검토 필요.
    /tmp/*/da-*/* | /private/tmp/*/da-*/*) return 1 ;;
    # macOS user-isolated TMPDIR (confstr _CS_DARWIN_USER_TEMP_DIR). /var/folders/<2>/<32>/T/는
    # 표준 고정 구조라 그 안에 추가 prefix가 끼는 케이스는 미관측. 발생 시 별도 arm 추가.
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

# Generic raw matcher for A/B/D — emits 3-column TSV records.
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
# - category_code: stable identifier (A/B/C/D) — callers branch on this
#   without parsing the human-readable label, which keeps display-string
#   changes from breaking branching logic.
# - label: human-readable category label (sourced from PINNING_PATTERN_*_LABEL)
# - line:token: 1-based line number from grep -n + matched token
# - sub: optional sub-category tag (currently "workflow" / "volatile" for
#   category C). Empty for A, B and D records. PreToolUse hard-fail consumers
#   branch on this tag instead of re-parsing the matched token.
pinning_findings_records() {
  local scan_file="$1"

  _pinning_simple_records "$scan_file" "A" "$PATTERN_A" "$PINNING_PATTERN_A_LABEL"
  _pinning_simple_records "$scan_file" "B" "$PATTERN_B" "$PINNING_PATTERN_B_LABEL"
  _pinning_pattern_c_records_sorted "$scan_file"
  _pinning_simple_records "$scan_file" "D" "$PATTERN_D" "$PINNING_PATTERN_D_LABEL"
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

pinning_match_count() {
  local scan_file="$1"
  pinning_findings_records "$scan_file" | wc -l | tr -d ' '
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

# ─── Bash --body-file / -F(--field) file-forwarding path extraction (issue #684) ───
# The Bash branch of pinning-guard.sh only scans the command string itself, so
# durable-text-producing commands that forward the body via a file
# (`gh pr create --body-file /tmp/b.md`, `gh api ... -F body=@/tmp/b.md`) pass
# unscanned. This extracts the referenced file path(s) from the command text so
# callers can rescan the file contents too.
#
# Not a full shell parser — a conservative (over-matching allowed) scan of a
# fixed flag inventory. Quoted values (single/double) have the quotes
# stripped; a quoted value containing whitespace is not supported (the
# command is naively split on whitespace first). Callers must treat anything
# but an existing regular file as a parse false-positive, not a scan target:
# gh cannot read a body from a missing path or a directory, and the flag
# inventory also matches other tools' flags (`awk -F/` yields `/`).
#
# Runs entirely in awk (no shell array/glob surface) so this stays safely
# sourceable from both bash (production hooks) and zsh (drift-check tooling).
#
# Matched shapes:
#   --body-file <path> / --body-file=<path>        (gh pr/issue)
#   --file <path> / --file=<path>                   (git commit)
#   -F <value> / --field <value>                    where <value> has no '=':
#     treated as a bare path (git commit -F <path>, or gh pr/issue's -F
#     shorthand for --body-file).
#   -F <value> / --field <value>                    where <value> is
#     `key=@<path>`: gh api's file-forwarding field shape — path is the part
#     after '@', with its own quotes stripped (`body=@"/tmp/b.md"`). A
#     `key=value` value with no '@' is not a file reference and is skipped.
#   -F<value> / -F=<value> / --field=<value>        attached forms of the above
#     (pflag and git parse-options both accept them).
# LC_ALL=C keeps macOS awk from aborting on invalid UTF-8 bytes in the command.
pinning_extract_body_file_paths() {
  local cmd="${1:-}"
  [ -n "$cmd" ] || return 0
  printf '%s\n' "$cmd" | LC_ALL=C awk -v sq="'" -v dq='"' '
    function strip_quotes(v,    n, first, last) {
      n = length(v)
      if (n < 2) return v
      first = substr(v, 1, 1)
      last = substr(v, n, 1)
      if ((first == dq && last == dq) || (first == sq && last == sq)) {
        return substr(v, 2, n - 2)
      }
      return v
    }
    function emit_field_or_path(v,    at) {
      if (index(v, "=") == 0) {
        print strip_quotes(v)
        return
      }
      at = index(v, "=@")
      if (at > 0) print strip_quotes(substr(v, at + 2))
    }
    {
      n = split($0, words, /[ \t]+/)
      i = 1
      while (i <= n) {
        w = words[i]
        if (w == "--body-file" || w == "--file") {
          if (i + 1 <= n) { print strip_quotes(words[i + 1]); i++ }
        } else if (w ~ /^--body-file=/) {
          sub(/^--body-file=/, "", w); print strip_quotes(w)
        } else if (w ~ /^--file=/) {
          sub(/^--file=/, "", w); print strip_quotes(w)
        } else if (w == "-F" || w == "--field") {
          if (i + 1 <= n) { emit_field_or_path(strip_quotes(words[i + 1])); i++ }
        } else if (w ~ /^--field=/) {
          sub(/^--field=/, "", w); emit_field_or_path(strip_quotes(w))
        } else if (w ~ /^-F./) {
          w = substr(w, 3); sub(/^=/, "", w); emit_field_or_path(strip_quotes(w))
        } else if (w == "--input") {
          # gh api --input: 요청 본문 전체를 파일로 넘긴다 (#1477).
          if (i + 1 <= n) { print strip_quotes(words[i + 1]); i++ }
        } else if (w ~ /^--input=/) {
          sub(/^--input=/, "", w); print strip_quotes(w)
        }
        i++
      }
    }
  '
}

# ─── Codex GitHub 앱 멘션 (#1477) ───
# Codex GitHub 앱(chatgpt-codex-connector)은 PR·이슈 코멘트의 봇 멘션을 작업 요청으로 읽어 클라우드
# 작업을 시작한다. 백틱이나 인용 안에 있어도 그렇다 (기록 코멘트의 백틱 멘션이 PR 생성 작업을 띄운
# 사례가 있다). 그래서 PR·이슈 본문과 코멘트를 게시하는 gh 명령에서 멘션을 막고, 재리뷰 요청 한
# 형태만 명령 문자열에서 허용한다. 봇 계정 이름 멘션(@chatgpt-codex-connector)도 같이 막는다.
# A–D 범주와 달리 저장소 파일·커밋 메시지는 검사하지 않는다 — 스킬 문서와 커밋은 그 형태를
# 설명해야 한다.
# hook은 셸 확장 전 문자열을 보므로 변수로 넘긴 본문 경로(`body=@"$BODY_FILE"`)와 stdin 본문
# (`--input -`), 인코딩하거나 조립한 멘션은 읽지 못한다. A–D 검사와 같은 한계라 1차 방어선은 PR
# 스킬 지침이다.
PINNING_CODEX_MENTION_LABEL="Codex 봇 멘션: 백틱이나 인용 안에 있어도 봇이 작업 요청으로 읽는다"

# 셸 명령 문자열 lexer (awk 프로그램, #1477). 아래 함수들이 mode만 바꿔 쓴다.
#   scope    — "<게시> <gh api 쓰기> <판정 불확실>"을 0/1 세 칸 한 줄로 낸다.
#   findings — 명령 문자열의 봇 멘션 findings. 재리뷰 요청 허용 형태의 본문 위치만 뺀다.
#   body     — 본문 파일의 봇 멘션 findings. 허용 형태 없이 모두 잡는다.
# 게시 판정은 따옴표를 푼 단어와 세그먼트(구분자 사이 단순 명령)로 한다. 그래서 따옴표 안의
# 구분자(`--jq '.a | .b'`), 커밋 메시지나 따옴표 있는 구분자의 heredoc 본문에 적힌 명령 이름을
# 명령으로 오인하지 않는다.
# - gh 호출: 세그먼트 안 어느 자리의 gh·gh-auth 단어든(경로 포함, 대소문자 무시; `sudo gh`·`env gh`도)
#   거기서부터 cobra처럼 하위 명령을 찾는다 — `gh -R o/r pr comment`도 잡는다. pr의 create·new·
#   edit·comment·review·revert·close·reopen, issue의 create·new·edit·comment·close·reopen, gh api
#   쓰기가 게시다.
# - gh api 쓰기: pflag 규칙(-X=POST, -XPOST, -iX POST, --field=k=v 등)으로 읽는다. REST는 메서드가
#   GET·HEAD·DELETE가 아니거나, 메서드 없이 필드·--input이 있으면 쓰기다. GraphQL은 조회도 POST라
#   query 값(문자열·주석 밖)의 mutation, 파일에서 읽는 필드, --input, 값을 알 수 없는 query를 쓰기로
#   본다. 메서드·query·플래그 이름이 변수면 쓰기로 본다.
# - 셸 명령을 받아 실행하는 명령(bash -c, ssh, eval 등)의 인자·here-string·heredoc 본문에 gh 호출이
#   보이면 다시 분석하지 않고 게시로 본다. 그런 명령이 파이프로 입력을 받거나 인자를 명령 치환·
#   변수로 만들면(`cat <<EOF | ssh host bash`, `bash -c "$(cat <<EOF ...)"`) 무엇이 실행될지 따지지
#   않고, 명령 문자열 어디든 gh 호출이 보이면 게시로 본다. 명령어 자리가 변수면(`$GH pr comment`)
#   뒤따르는 하위 명령과 인자로 판정한다.
# - 허용 형태는 heredoc이 없는 명령에서, 명령 위치의 `gh pr comment`로만 인정한다. here-string(<<<),
#   산술 시프트, 따옴표 안의 << 는 heredoc이 아니다.
# 명령 문자열의 멘션은 게시 여부와 관계없이 전체를 본다. 파이프(`echo ... | gh pr comment -F -`)처럼
# 다른 명령의 출력이 본문이 되는 경로가 있기 때문이다.
# 셸마다 해석이 갈리는 문법(큰따옴표 안 ${ }의 작은따옴표)이나 짝이 맞지 않는 따옴표·괄호·heredoc을
# 만나면 판정 불확실로 보고 허용 형태를 인정하지 않는다. PINNING_LEXER_MAX_BYTES보다 긴 명령은 lexer
# 없이 판정 불확실로 본다 (macOS awk는 MB 단위 입력에 수십 초가 걸린다).
# LC_ALL=C로 돌려 잘못된 UTF-8 바이트에서도 멈추지 않는다. 프로그램 안에는 작은따옴표를 쓰지 않는다.
# shellcheck disable=SC2016  # awk 프로그램 본문이라 셸 확장을 막으려고 작은따옴표로 감싼다.
_PINNING_SH_LEXER_AWK='
    # 프레임: T 명령 문맥(최상위와 $( ), <( ), >( ) 안), B 백틱, D 큰따옴표, P ${ }, A 산술, H 따옴표
    # 없는 구분자의 heredoc 본문. 단어는 T·B·H 프레임에 속하고 D·P·A의 글자는 아래 프레임의 단어에
    # 붙는다. 작은따옴표와 ANSI-C 따옴표는 프레임 대신 sqm·ansi 상태로 다룬다.
    function reset_word(d) { cw[d] = ""; cwn[d] = 0; cwon[d] = 0; cwdyn[d] = 0; cwq[d] = 0; cwat[d] = ""; cwlong[d] = 0 }
    function push(t, dollar_,    below) {
      below = sp > 0 ? ft[sp] : "T"
      sp++; ft[sp] = t; fdollar[sp] = dollar_; par[sp] = 0
      if (t == "T" || t == "B" || t == "H") {
        own[sp] = sp; sn[sp] = 0; reset_word(sp); hdnext[sp] = 0; rtnext[sp] = 0; segid[sp] = ++segctr
        pipe_in[sp] = 0
      } else {
        own[sp] = own[sp - 1]
      }
      if (t == "P") pctx[sp] = below == "P" ? pctx[sp - 1] : below
    }
    function pop() {
      if (ft[sp] == "T" || ft[sp] == "B") { end_word(sp); end_seg(sp) }
      sp--
    }
    function add(c, k, i,    o) {
      o = own[sp]
      cwon[o] = 1
      if (cwn[o] < WCAP) { cw[o] = cw[o] c; cwn[o]++ } else cwlong[o] = 1
      if (c == "@" && k > 0 && cwat[o] == "") cwat[o] = k ":" i
    }
    function mark_dyn(    o) { o = own[sp]; cwon[o] = 1; cwdyn[o] = 1; add("$", 0, 0) }
    function mark_q(    o) { o = own[sp]; cwon[o] = 1; cwq[o] = 1 }
    function end_word(d,    j) {
      if (!cwon[d]) return
      if (ft[d] == "H") { reset_word(d); return }
      if (hdnext[d]) {
        hq_n++; hq_delim[hq_n] = cw[d]; hq_quoted[hq_n] = cwq[d]; hq_dash[hq_n] = hdnext[d] == 2
        hq_seg[hq_n] = segid[d]; hdnext[d] = 0; saw_hd = 1
      } else {
        j = ++sn[d]
        sv[d, j] = cw[d]; sdy[d, j] = cwdyn[d] || cwlong[d]; sat[d, j] = cwat[d]
        sk[d, j] = rtnext[d] == 2 ? "h" : rtnext[d] ? "r" : "w"
        rtnext[d] = 0
      }
      reset_word(d)
    }
    # piped가 참이면 이 세그먼트의 출력이 다음 세그먼트로 파이프된다(|, |&).
    function end_seg(d, piped) {
      if (ft[d] == "H") return
      if (sn[d] > 0) classify(d)
      pipe_in[d] = piped ? 1 : 0
      sn[d] = 0; hdnext[d] = 0; rtnext[d] = 0; segid[d] = ++segctr
    }
    function lower_base(w,    b) {
      b = w
      sub(/.*\//, "", b)
      return tolower(b)
    }
    function is_gh(w,    b) { b = lower_base(w); return b == "gh" || b == "gh-auth" }
    function is_runner(w) {
      return lower_base(w) ~ /^(bash|sh|zsh|dash|ksh|mksh|fish|eval|ssh|su|runuser|script|watch|parallel|tmux|nix-shell)$/
    }
    # 셸 명령을 받아 실행하는 명령(셸 실행기)의 인자, here-string, heredoc 본문에 gh 호출이 보이면
    # 게시로 본다. 셸 실행기가 파이프로 입력을 받거나 인자가 명령 치환·변수로 만들어지면 무엇이
    # 실행될지 따지지 않고 END에서 명령 문자열 전체로 판정한다. 그 안의 명령은 다시 분석하지 않는다.
    # 스크립트 안에서 따옴표로 감싼 gh도 잡도록 따옴표를 gh 앞뒤 경계로 본다.
    function has_gh_text(s) { return s ~ GH_TEXT_RE }
    function classify(d,    j, np, t, cmdpos, hstr, runner) {
      np = 0; hstr = 0; runner = 0
      for (j = 1; j <= sn[d]; j++) {
        if (sk[d, j] == "h") { if (has_gh_text(sv[d, j])) hstr = 1; continue }
        if (sk[d, j] != "w") continue
        np++; pw[np] = sv[d, j]; pd[np] = sdy[d, j]; pa[np] = sat[d, j]
      }
      if (np == 0) return
      check_allowed(np)
      cmdpos = 1
      while (cmdpos <= np && pw[cmdpos] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) cmdpos++
      for (t = 1; t <= np; t++) {
        if (pd[t]) {
          # 명령어 자리가 변수면($GH pr comment, $SHELL -c ...) 뒤따르는 하위 명령과 인자로 판정한다.
          if (t == cmdpos) { gh_invocation(t, np, 1); if (runner_args(t, np)) posts = 1 }
          continue
        }
        if (is_gh(pw[t])) gh_invocation(t, np, 0)
        else if (is_runner(pw[t])) { runner = 1; if (runner_args(t, np)) posts = 1 }
      }
      if (!runner) return
      runner_seg[segid[d]] = 1
      if (hstr) posts = 1
      if (pipe_in[d]) piped_runner = 1
    }
    # 동적 인자(명령 치환·변수·ANSI-C, 잘린 긴 단어)는 정적 텍스트만으로 알 수 없어 END로 넘긴다.
    function runner_args(t, np,    u) {
      for (u = t + 1; u <= np; u++) {
        if (has_gh_text(pw[u])) return 1
        if (pd[u]) dyn_runner = 1
      }
      return 0
    }
    # 재리뷰 요청 허용 형태: [NAME=값...] gh [-R 저장소] pr [-R 저장소] comment [PR 하나]
    # [-R 저장소...] --body <재리뷰 요청 문구>. -b와 --body=도 받고, 본문 인자는 정확히 한 번이다.
    # 문구는 따옴표를 푼 값이 정확히 @codex review(소문자)여야 하고, 그 @ 위치만 allowed에 넣는다.
    function check_allowed(np,    u, w, st, npos, nbody, bpos) {
      u = 1
      while (u <= np && pw[u] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) u++
      if (u > np || pd[u] || pw[u] !~ /^(.*\/)?gh(-auth)?$/) return
      st = 0; npos = 0; nbody = 0; bpos = ""
      for (u++; u <= np; u++) {
        w = pw[u]
        if (w == "-R" || w == "--repo") { u++; if (u > np) return; continue }
        if (substr(w, 1, 7) == "--repo=") continue
        if (st == 0) { if (pd[u] || w != "pr") return; st = 1; continue }
        if (st == 1) { if (pd[u] || w != "comment") return; st = 2; continue }
        if (w == "--body" || w == "-b") {
          u++
          if (u > np || pd[u] || pw[u] != "@codex review") return
          nbody++; bpos = pa[u]; continue
        }
        if (substr(w, 1, 7) == "--body=") {
          if (pd[u] || substr(w, 8) != "@codex review") return
          nbody++; bpos = pa[u]; continue
        }
        if (substr(w, 1, 1) == "-") return
        if (++npos > 1) return
      }
      if (st == 2 && nbody == 1 && bpos != "") allowed[bpos] = 1
    }
    # gh의 명령 경로는 cobra처럼 찾는다: 등호 없는 모르는 플래그는 다음 단어를 값으로 먹는다.
    # 그래서 `gh -R o/r pr comment`처럼 플래그가 하위 명령 앞에 와도 경로를 찾는다.
    function gh_invocation(t, np, dyncmd,    u, w, ncmd, c1, c2, c1d, c2d, c1i) {
      ncmd = 0
      for (u = t + 1; u <= np && ncmd < 2; u++) {
        w = pw[u]
        if (w == "--" && !pd[u]) break
        if (substr(w, 1, 1) == "-" && w != "-") {
          if (substr(w, 1, 2) == "--") { if (index(w, "=") == 0 && w != "--help" && w != "--version") u++ }
          else if (length(w) == 2 && w != "-h") u++
          continue
        }
        ncmd++
        if (ncmd == 1) { c1 = w; c1d = pd[u]; c1i = u } else { c2 = w; c2d = pd[u] }
      }
      if (ncmd == 0) return
      if (dyncmd && (c1d || c1 !~ /^(pr|issue|api)$/)) return
      if (c1d) { posts = 1; return }
      if (c1 == "pr" || c1 == "issue") {
        if (ncmd < 2) return
        if (c2d) { posts = 1; return }
        if (c2 ~ /^(create|new|edit|comment|close|reopen)$/ || (c1 == "pr" && c2 ~ /^(review|revert)$/)) posts = 1
        return
      }
      if (c1 == "api" && api_writes(t, np, c1i)) { posts = 1; apiw = 1 }
    }
    # gh api 호출이 GitHub에 내용을 쓰는지. pflag 규칙으로 인자를 읽는다(-X=POST, -XPOST, -iX POST,
    # --method=POST, --field=k=v 등).
    function api_writes(t, np, api_i,    u, w, d, name, val, vd, eq, s, ch, rest, have_ep, ep, epd, endf) {
      am = ""; amdyn = 0; afields = 0; afilef = 0; ainput = 0; aqdyn = 0; aqmut = 0; aunk = 0
      have_ep = 0; endf = 0
      for (u = t + 1; u <= np; u++) {
        if (u == api_i) continue
        w = pw[u]; d = pd[u]
        if (endf || substr(w, 1, 1) != "-" || w == "-") {
          if (!have_ep) { have_ep = 1; ep = w; epd = d }
          else if (d) aunk = 1
          continue
        }
        if (w == "--") { endf = 1; continue }
        if (substr(w, 1, 2) == "--") {
          name = substr(w, 3); eq = index(name, "=")
          if (eq) { val = substr(name, eq + 1); name = substr(name, 1, eq - 1); vd = d }
          if (index(name, "$")) { aunk = 1; continue }
          if (name ~ /^(method|field|raw-field|header|input|jq|template|cache|hostname|preview)$/) {
            if (!eq) { u++; if (u > np) break; val = pw[u]; vd = pd[u] }
            api_opt(name, val, vd)
          }
          continue
        }
        s = substr(w, 2)
        while (s != "") {
          ch = substr(s, 1, 1); rest = substr(s, 2)
          if (ch == "$") { aunk = 1; break }
          if (ch ~ /^[XfFHqtp]$/) {
            if (rest != "") { if (substr(rest, 1, 1) == "=") rest = substr(rest, 2); val = rest; vd = d }
            else { u++; if (u > np) break; val = pw[u]; vd = pd[u] }
            api_opt(ch == "X" ? "method" : ch == "f" ? "raw-field" : ch == "F" ? "field" : "other", val, vd)
            break
          }
          s = rest
        }
      }
      if (aunk) return 1
      if (have_ep && !epd && ep == "graphql") return ainput || afilef || aqdyn || aqmut
      if (amdyn) return 1
      if (am != "") return !(am == "GET" || am == "HEAD" || am == "DELETE")
      return afields || ainput
    }
    function api_opt(name, val, vd,    eq, key, v) {
      if (name == "method") { am = toupper(val); amdyn = vd; return }
      if (name == "input") { ainput = 1; return }
      if (name != "field" && name != "raw-field") return
      afields = 1
      eq = index(val, "=")
      if (eq) { key = substr(val, 1, eq - 1); v = substr(val, eq + 1) } else { key = val; v = "" }
      if (name == "field" && substr(v, 1, 1) == "@") afilef = 1
      if (vd && (key == "query" || index(key, "$"))) { aqdyn = 1; return }
      if (key != "query") return
      if (name == "field" && substr(v, 1, 1) == "@") aqdyn = 1
      else if (gql_mutation(v)) aqmut = 1
    }
    # GraphQL 문서에 mutation 연산이 있는지. 문자열과 # 주석 안의 낱말은 세지 않는다.
    function gql_mutation(q,    n, Q, i, c, instr) {
      if (index(q, "mutation") == 0) return 0
      n = split(q, Q, "")
      instr = 0
      for (i = 1; i <= n; i++) {
        c = Q[i]
        if (instr == 1) { if (c == "\\") i++; else if (c == dq) instr = 0; continue }
        if (instr == 2) { if (c == dq && Q[i + 1] == dq && Q[i + 2] == dq) { instr = 0; i += 2 }; continue }
        if (c == "#") { while (i <= n && Q[i] != "\n") i++; continue }
        if (c == dq) { if (Q[i + 1] == dq && Q[i + 2] == dq) { instr = 2; i += 2 } else instr = 1; continue }
        if (c == "m" && substr(q, i, 8) == "mutation" && (i == 1 || Q[i - 1] !~ /[A-Za-z0-9_]/) && Q[i + 8] !~ /[A-Za-z0-9_]/) return 1
      }
      return 0
    }
    function dollar(k, i, c2) {
      if (c2 == "(") {
        mark_dyn()
        if (C[i + 2] == "(") { push("A", 0); return i + 2 }
        push("T", 1); return i + 1
      }
      if (c2 == "{") { mark_dyn(); push("P", 0); return i + 1 }
      if (ft[sp] == "T" || ft[sp] == "B") {
        if (c2 == sq) { mark_dyn(); ansi = 1; return i + 1 }
        if (c2 == dq) { mark_q(); push("D", 0); return i + 1 }
      }
      if (c2 ~ /^[A-Za-z0-9_@*#?$!-]$/) { mark_dyn(); return i }
      add("$", k, i); return i
    }
    function redir(k, i, c, c2,    o) {
      o = sp
      if (c2 == "(") { mark_dyn(); push("T", 1); return i + 1 }
      if (cwon[o] && !cwq[o] && !cwdyn[o] && cw[o] ~ /^[0-9]+$/) reset_word(o)
      else end_word(o)
      if (c == ">") {
        if (c2 == ">" || c2 == "|" || c2 == "&") i++
        rtnext[o] = 1; return i
      }
      if (c2 == "<") {
        if (C[i + 2] == "<") { rtnext[o] = 2; return i + 2 }
        if (C[i + 2] == "-") { hdnext[o] = 2; return i + 2 }
        hdnext[o] = 1; return i + 1
      }
      if (c2 == "&" || c2 == ">") i++
      rtnext[o] = 1; return i
    }
    function lex_T(k, i, n, c, c2) {
      if (c == " " || c == "\t") { end_word(sp); return i }
      if (c == "\\") {
        if (i == n) { cont = 1; return i }
        mark_q(); add(c2, k, i + 1); return i + 1
      }
      if (c == sq) { mark_q(); sqm = 1; return i }
      if (c == dq) { mark_q(); push("D", 0); return i }
      if (c == "`") {
        if (ft[sp] == "B") { pop(); return i }
        mark_dyn(); push("B", 0); return i
      }
      if (c == "$") return dollar(k, i, c2)
      if (c == "#" && !cwon[sp]) return comment_end(i, n)
      if (c == ";") { end_word(sp); end_seg(sp); return i }
      if (c == "&") {
        if (c2 == ">") { end_word(sp); i++; if (C[i + 1] == ">") i++; rtnext[sp] = 1; return i }
        end_word(sp); end_seg(sp); if (c2 == "&") i++
        return i
      }
      if (c == "|") {
        end_word(sp)
        if (c2 == "|") { end_seg(sp); return i + 1 }
        end_seg(sp, 1); if (c2 == "&") i++
        return i
      }
      if (c == "(") {
        end_word(sp); end_seg(sp)
        if (c2 == "(") { push("A", 0); return i + 1 }
        par[sp]++; return i
      }
      if (c == ")") {
        end_word(sp); end_seg(sp)
        if (par[sp] > 0) par[sp]--
        else if (ft[sp] == "T" && fdollar[sp]) pop()
        else confused = 1
        return i
      }
      if (c == "<" || c == ">") return redir(k, i, c, c2)
      add(c, k, i); return i
    }
    # 주석은 줄 끝까지다. 백틱 치환 안에서는 셸이 닫는 백틱을 먼저 찾으므로 이스케이프되지 않은
    # 백틱 앞에서 끝난다.
    function comment_end(i, n,    j) {
      if (ft[sp] != "B") return n
      for (j = i + 1; j <= n; j++) {
        if (C[j] == "\\") { j++; continue }
        if (C[j] == "`") return j - 1
      }
      return n
    }
    function lex_D(k, i, n, c, c2) {
      if (c == dq) { pop(); return i }
      if (c == "\\") {
        if (i == n) { cont = 1; return i }
        if (c2 == "$" || c2 == "`" || c2 == dq || c2 == "\\") { add(c2, k, i + 1); return i + 1 }
        add(c, k, i); return i
      }
      if (c == "$") return dollar(k, i, c2)
      if (c == "`") { mark_dyn(); push("B", 0); return i }
      add(c, k, i); return i
    }
    function lex_P(k, i, n, c, c2) {
      if (c == "}") { pop(); return i }
      if (c == "\\") {
        if (i == n) { cont = 1; return i }
        add(c2, k, i + 1); return i + 1
      }
      if (c == sq) {
        if (pctx[sp] != "D" && pctx[sp] != "H") { sqm = 1; return i }
        # 큰따옴표 안 ${ }의 작은따옴표는 bash가 인용으로, zsh·POSIX가 글자로 읽는다.
        if (pctx[sp] == "D") confused = 1
      }
      if (c == dq) { push("D", 0); return i }
      if (c == "$") return dollar(k, i, c2)
      if (c == "`") { push("B", 0); return i }
      add(c, k, i); return i
    }
    # 산술 확장 $(( )) 과 산술 명령 (( )). << 는 시프트 연산자다.
    function lex_A(k, i, n, c, c2) {
      if (c == "(") { par[sp]++; return i }
      if (c == ")") {
        if (par[sp] > 0) { par[sp]--; return i }
        if (c2 == ")") { pop(); return i + 1 }
        confused = 1; pop(); return i
      }
      if (c == "\\") { if (i == n) cont = 1; else i++; return i }
      if (c == sq) { sqm = 1; return i }
      if (c == dq) { push("D", 0); return i }
      if (c == "$") return dollar(k, i, c2)
      if (c == "`") { push("B", 0); return i }
      add(c, k, i); return i
    }
    # 따옴표 없는 구분자의 heredoc 본문: 큰따옴표 안처럼 $, 백틱, 역슬래시만 특별하다.
    function lex_H(k, i, n, c, c2) {
      if (c == "\\") {
        if (i == n) { cont = 1; return i }
        if (c2 == "$" || c2 == "`" || c2 == "\\") return i + 1
        return i
      }
      if (c == "$") return dollar(k, i, c2)
      if (c == "`") { push("B", 0); return i }
      return i
    }
    # ANSI-C 따옴표의 이스케이프. 제어문자(\n, \t 등)와 코드 표기(\x41, \101, \u 뒤 16진수)는 값을
    # 풀지 않고 공백 하나로 넣어 단어 경계로만 쓴다. 반환값은 마지막으로 먹은 글자 위치다.
    function ansi_esc(k, i, n, c2,    j, m, lim, cls) {
      if (c2 ~ /^[abeEfnrtv]$/) { add(" ", k, i + 1); return i + 1 }
      if (c2 == "c") { add(" ", k, i + 1); return i + 1 < n ? i + 2 : i + 1 }
      if (c2 == "\\" || c2 == sq || c2 == dq || c2 == "?") { add(c2, k, i + 1); return i + 1 }
      if (c2 ~ /^[0-7]$/) { j = i + 1; lim = 3; cls = "^[0-7]$" }
      else if (c2 == "x") { j = i + 2; lim = 2; cls = "^[0-9A-Fa-f]$" }
      else if (c2 == "u") { j = i + 2; lim = 4; cls = "^[0-9A-Fa-f]$" }
      else if (c2 == "U") { j = i + 2; lim = 8; cls = "^[0-9A-Fa-f]$" }
      else { add("\\", k, i); add(c2, k, i + 1); return i + 1 }
      for (m = 0; m < lim && j <= n && C[j] ~ cls; m++) j++
      add(" ", k, i + 1)
      return j - 1
    }
    function lex_line(k,    n, i, c, c2, t) {
      # heredoc 본문 줄에 $, 백틱, 역슬래시가 없으면 볼 것이 없다.
      if (ft[sp] == "H" && !sqm && !ansi && LX[k] !~ /[$`\\]/) return
      n = split(LX[k], C, "")
      for (i = 1; i <= n; i++) {
        c = C[i]; c2 = i < n ? C[i + 1] : ""
        if (sqm) { if (c == sq) sqm = 0; else add(c, k, i); continue }
        if (ansi) {
          if (c == "\\") { if (i < n) i = ansi_esc(k, i, n, c2) }
          else if (c == sq) ansi = 0
          else add(c, k, i)
          continue
        }
        t = ft[sp]
        if (t == "T" || t == "B") i = lex_T(k, i, n, c, c2)
        else if (t == "D") i = lex_D(k, i, n, c, c2)
        else if (t == "P") i = lex_P(k, i, n, c, c2)
        else if (t == "A") i = lex_A(k, i, n, c, c2)
        else i = lex_H(k, i, n, c, c2)
      }
    }
    function at_eol(k,    t) {
      if (sqm || ansi) { add("\n", k, 0); return }
      t = ft[sp]
      if (t == "T" || t == "B") {
        end_word(sp); end_seg(sp)
        if (hq_n > 0) { if (in_hd) { confused = 1; hq_n = 0 } else hq_ready = 1 }
        return
      }
      if (t == "D" || t == "P" || t == "A") add("\n", k, 0)
    }
    function delim_line(s, delim, dash) {
      if (dash) sub(/^\t+/, "", s)
      return s == delim
    }
    function lex_heredoc(a, b, script,    j, base) {
      if (script) {
        for (j = a; j <= b; j++) if (has_gh_text(LX[j])) { posts = 1; break }
      }
      in_hd = 1
      push("H", 0); base = sp
      for (j = a; j <= b; j++) {
        lex_line(j)
        if (!cont) at_eol(j)
        cont = 0
      }
      if (sqm || ansi) { confused = 1; sqm = 0; ansi = 0 }
      while (sp > base) { confused = 1; pop() }
      pop()
      in_hd = 0
    }
    function lex_all(    k, h, e, joined) {
      sp = 0; sqm = 0; ansi = 0; cont = 0; hq_n = 0; hq_ready = 0; in_hd = 0
      push("T", 0)
      k = 1
      while (k <= nlx) {
        lex_line(k)
        if (!cont) at_eol(k)
        cont = 0
        k++
        if (hq_ready) {
          hq_ready = 0
          for (h = 1; h <= hq_n; h++) {
            # 따옴표 없는 구분자의 본문에서 홀수 개 역슬래시로 끝나는 줄은 다음 줄과 이어지므로,
            # 이어진 줄은 종결자가 아니다.
            e = k; joined = 0
            while (e <= nlx && (joined || !delim_line(LX[e], hq_delim[h], hq_dash[h]))) {
              joined = !hq_quoted[h] && LX[e] ~ /(^|[^\\])(\\\\)*\\$/
              e++
            }
            if (e > nlx) confused = 1
            if (e > k) {
              if (hq_quoted[h]) { if (runner_seg[hq_seg[h]]) lex_heredoc_script(k, e - 1) }
              else lex_heredoc(k, e - 1, runner_seg[hq_seg[h]])
            }
            k = e + 1
          }
          hq_n = 0
        }
      }
      if (sqm || ansi) confused = 1
      while (sp > 1) { confused = 1; pop() }
      end_word(1); end_seg(1)
      if (confused || saw_hd) { split("", allowed) }
    }
    function lex_heredoc_script(a, b,    j) {
      for (j = a; j <= b; j++) if (has_gh_text(LX[j])) { posts = 1; return }
    }
    # 봇 멘션 목록. use_allowed가 참이면 허용 형태의 본문 위치는 뺀다.
    function scan_mentions(use_allowed,    k, rest, off, p, p2, nm, col, tok, after, found) {
      found = 0
      for (k = 1; k <= nl; k++) {
        rest = tolower(L[k]); off = 0
        while (1) {
          p = index(rest, "@codex"); p2 = index(rest, "@chatgpt-codex-connector")
          if (!p && !p2) break
          if (p && (!p2 || p < p2)) nm = 6
          else { p = p2; nm = 24 }
          col = off + p
          if (!(use_allowed && ((k ":" col) in allowed))) {
            # 멘션 뒤 요청어 한 단어까지 보여 준다. ASCII만 이어 붙여 멀티바이트 경계를 자르지 않는다.
            tok = substr(L[k], col, nm)
            after = substr(L[k], col + nm, 64)
            if (match(after, /^[A-Za-z0-9_-]*( [A-Za-z0-9_-]+)?/)) tok = tok substr(after, 1, RLENGTH)
            if (!found) { printf "\n  - %s", label; found = 1 }
            printf "\n%s%d: %s", indent, k, tok
          }
          off += p; rest = substr(rest, p + 1)
        }
      }
    }
    { L[++nl] = $0 }
    END {
      WCAP = 4096
      GH_TEXT_RE = "(^|[^A-Za-z0-9_.-])gh(-auth)?([ \t\n;&|)<>`" sq dq "]|$)"
      if (mode == "body") { scan_mentions(0); exit 0 }
      for (k = 1; k <= nl; k++) LX[k] = L[k]
      nlx = nl
      lex_all()
      if ((piped_runner || dyn_runner) && !posts) for (k = 1; k <= nl; k++) if (has_gh_text(L[k])) { posts = 1; break }
      if (mode == "findings") { scan_mentions(1); exit 0 }
      printf "%d %d %d\n", posts, apiw, confused
    }
  '

# lexer에 넘길 명령의 최대 길이(바이트). 넘으면 lexer 없이 판정 불확실로 본다.
PINNING_LEXER_MAX_BYTES=262144

# awk가 실패하면 비0으로 끝난다. hook의 stderr를 오염시키지 않도록 awk 오류는 버린다.
_pinning_sh_lexer() {
  local mode="$1"
  shift
  LC_ALL=C awk -v mode="$mode" -v sq="'" -v dq='"' \
    -v indent="$PINNING_REPORT_INDENT" -v label="$PINNING_CODEX_MENTION_LABEL" \
    "$_PINNING_SH_LEXER_AWK" "$@" 2>/dev/null
}

_pinning_too_long_for_lexer() {
  local LC_ALL=C
  [ "${#1}" -gt "$PINNING_LEXER_MAX_BYTES" ]
}

# gh를 부를 수 있는 명령인지 빠르게 거른다. 따옴표·역슬래시로 끊은 이름(`g\h`, `g''h`)도 통과시킨다.
_pinning_may_call_gh() {
  local probe="$1"
  probe="${probe//\\/}"
  probe="${probe//\"/}"
  probe="${probe//\'/}"
  case "$probe" in
    *[Gg][Hh]*) return 0 ;;
  esac
  return 1
}

# "<게시> <gh api 쓰기> <판정 불확실>". lexer 출력이 형식에 맞지 않으면 판정 불확실로 본다.
_pinning_gh_profile() {
  local profile
  if _pinning_too_long_for_lexer "$1"; then
    printf '0 0 1\n'
    return 0
  fi
  profile="$(printf '%s\n' "$1" | _pinning_sh_lexer scope)" || profile=""
  case "$profile" in
    [01]" "[01]" "[01]) printf '%s\n' "$profile" ;;
    *) printf '0 0 1\n' ;;
  esac
}

# 판정이 불확실한 명령(닫히지 않은 따옴표·괄호, 끝나지 않은 heredoc 등)은 문자열로 보수적으로 판정한다.
_pinning_gh_text_fallback() {
  case "$1" in
    *"gh pr "* | *"gh issue "* | *"gh api"* | *"gh -"* | *"gh-auth "*) return 0 ;;
  esac
  return 1
}

# gh api 호출 중 GitHub에 내용을 쓰는 것이 있는지 (#1477). 읽기 조회는 jq 필터 등에 무엇이 있어도
# 게시되지 않으므로 제외한다. 판정 기준은 위 lexer 설명을 따른다. hook은 이 함수 대신
# pinning_codex_mention_scope를 쓴다. 이 함수는 gh api 쓰기 판정만 따로 확인하는 테스트·진단용이다.
pinning_gh_api_posts_content() {
  local cmd="${1:-}" posts="" api="" confused=""
  _pinning_may_call_gh "$cmd" || return 1
  read -r posts api confused <<<"$(_pinning_gh_profile "$cmd")"
  [ "$api" = 1 ] && return 0
  if [ "$confused" = 1 ]; then
    case "$cmd" in
      *"gh api"* | *"gh-auth api"* | *"gh -"*" api "*) return 0 ;;
    esac
  fi
  return 1
}

# 멘션 검사 대상 명령: PR·이슈 본문과 코멘트를 게시하는 gh 명령과 gh api 쓰기.
# git commit과 gh pr merge(병합 커밋 메시지)는 대상이 아니다.
pinning_codex_mention_scope() {
  local cmd="${1:-}" posts="" api="" confused=""
  _pinning_may_call_gh "$cmd" || return 1
  read -r posts api confused <<<"$(_pinning_gh_profile "$cmd")"
  [ "$posts" = 1 ] && return 0
  [ "$confused" = 1 ] && _pinning_gh_text_fallback "$cmd" && return 0
  return 1
}

# 멘션 findings. 출력은 A–D의 렌더 형식(라벨 한 줄 + `<line>: <token>`)을 따르고, 없으면 빈 출력이다.
# awk가 실패하면 비0으로 끝난다.
#   $1 scan_file
#   $2 mode — command: 명령 문자열. 재리뷰 요청 허용 형태의 본문(`--body '@codex review'`)만 빼고
#             검사한다. 명령에 heredoc이 있거나, lexer가 판정을 확신하지 못하거나, 명령이
#             PINNING_LEXER_MAX_BYTES보다 길면 빼지 않는다.
#           — body: --body-file 등으로 넘긴 본문. 허용 형태 없이 모든 멘션을 잡는다. NUL 바이트는
#             지우고 본다 (macOS awk는 NUL에서 줄을 끊는다).
# 대소문자를 가리지 않는다. 줄 번호는 입력의 실제 줄이다.
pinning_codex_mention_findings_text() {
  local scan_file="$1" mode=body size=0
  if [ "${2:-body}" = "command" ]; then
    mode=findings
    size=$(LC_ALL=C wc -c < "$scan_file") || return 1
    [ "$((size + 0))" -gt "$PINNING_LEXER_MAX_BYTES" ] && mode=body
  fi
  if [ "$mode" = body ]; then
    LC_ALL=C tr -d '\000' < "$scan_file" | _pinning_sh_lexer body
  else
    _pinning_sh_lexer findings "$scan_file"
  fi
}

# 멘션 deny 사유. surface/target은 A–D deny와 같은 뜻이고 findings는 위 함수의 출력이다.
pinning_codex_mention_deny_reason() {
  local surface="$1" target="$2" findings="$3"
  printf "[pinning-guard] %s on %s mentions the Codex GitHub app:%s\n%s" \
    "$surface" "$target" "$findings" \
    "재리뷰 요청은 heredoc 없는 명령에서 gh pr comment <PR> -R OWNER/REPO --body '@codex review' 형태로만 보낸다. 그 밖의 게시물에는 멘션 없이 'Codex 봇'처럼 쓴다. 조회 필터처럼 게시하지 않는 부분의 멘션이면 게시 명령과 나눠 실행한다. Codex에 작업을 맡기려던 것이면 사용자에게 넘긴다."
}
