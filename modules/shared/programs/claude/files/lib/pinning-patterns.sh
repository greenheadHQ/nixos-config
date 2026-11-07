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
# 고정된 파일 전달 옵션의 정적 단어만 추출한다. 작은/큰따옴표와 escape를 처리하고,
# 확장이 필요한 단어는 건너뛴다. 중첩 치환은 경계만 찾으며 내용을 실행하지 않는다.
# 전체 셸 문법이나 heredoc·실행 중 cwd 변경을 해석하지 않으므로, 없는 경로를 건너뛰는
# 기존 호출부 계약을 유지한다. 공백·따옴표는 경로에 포함할 수 있지만 개행은 미지원이다.
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
#     after '@'. A `key=value` value with no '@' is not a file reference and
#     is skipped.
pinning_extract_body_file_paths() {
  local cmd="${1:-}"
  [ -n "$cmd" ] || return 0
  # 정적 셸 단어만 읽는다. 인용/escape는 해제하되 확장은 실행하지 않는다.
  # 동적 단어·미완성 인용·개행 포함 경로는 반환하지 않는다. 줄 단위 경로를 받는
  # 호출부의 없는 파일 건너뜀/읽기 실패 거부 정책은 그대로 유지한다.
  # 닫힌 치환 본문은 직접 게시 명령만 별도로 검사한다. here-doc의 종료/작업 폴더/
  # 함수·별칭·임의 wrapper는 해석하지 않으며 here-doc 내부 본문은 검사에서 제외한다.
  printf '%s\n' "$cmd" | awk -v sq="'" -v dq='"' '
    function finish_word(end) {
      if (started) {
        if (!redirect_target) {
          words[++count] = word
          literal[count] = !dynamic
          unknown_shape[count] = shape_unknown
          assignment[count] = substr(command, word_start, end - word_start) ~ /^[A-Za-z_][A-Za-z0-9_]*=/
        }
        redirect_target = 0
      }
      word = ""; started = dynamic = brace_depth = shape_unknown = 0
    }
    function separator(c, at) {
      finish_word(at)
      words[++count] = c
      literal[count] = 0
      boundary[count] = index(";|&()\n", c) > 0
      if (boundary[count]) redirect_target = 0
    }
    # 일반 리디렉션의 대상은 argv가 아니다. 붙어 있는 인용 없는 IO 번호만 함께 뺀다.
    # 대상 안의 명령 치환 스코프는 토큰화 중 이미 수집하므로 그대로 남는다.
    function start_redirection(at, allow_fd) {
      if (allow_fd && started && substr(command, word_start, at - word_start) ~ /^[0-9]+$/) {
        word = ""; started = dynamic = brace_depth = shape_unknown = 0
      } else finish_word(at)
      redirect_target = 1
    }
    # 확장 시작 기호와 다음 문자 사이에서 실제로 제거되는 줄연속만 잇는다.
    function join_continuations_after(position) {
      while (substr(command, position + 1, 2) == "\\\n") {
        command = substr(command, 1, position) substr(command, position + 3)
      }
    }
    function backtick_script(raw, outer_quote,    i, c, following, result) {
      for (i = 1; i <= length(raw); i++) {
        c = substr(raw, i, 1)
        following = substr(raw, i + 1, 1)
        if (c == "\\" && (following == "\\" || following == "$" || following == "`" ||
            following == "\n" || (outer_quote == dq && following == dq))) {
          if (following != "\n") result = result following
          i++
        } else result = result c
      }
      return result
    }
    function skip_backticks(start, collect, outer_quote,    i, c) {
      for (i = start + 1; i <= length(command); i++) {
        c = substr(command, i, 1)
        if (c == "\\") i++
        else if (c == "`") {
          if (collect) scopes[++scope_count] = backtick_script(substr(command, start + 1, i - start - 1), outer_quote)
          return i
        }
      }
      return i
    }
    # ANSI-C 인용은 escape를 포함한 끝 경계만 찾는다. 값은 해독하지 않고 동적으로 둔다.
    function skip_ansi_quote(start,    i, c) {
      for (i = start + 1; i <= length(command); i++) {
        c = substr(command, i, 1)
        if (c == "\\") i++
        else if (c == sq) return i
      }
      return i
    }
    # 치환값은 만들지 않는다. 완전히 닫힌 실행 본문만 별도 스코프로 검사한다.
    # 그 본문 안의 자식은 다음 토큰화에서 찾으므로 중복 등록하지 않는다.
    function skip_expansion(start, collect, arithmetic,    opening, closing, depth, quote, i, c, following, command_scope, before, word_boundary) {
      opening = substr(command, start, 1)
      closing = opening == "(" ? ")" : "}"
      command_scope = opening == "(" && !arithmetic && !(substr(command, start - 1, 1) == "$" && substr(command, start + 1, 1) == "(")
      before = scope_count
      depth = word_boundary = 1
      for (i = start + 1; i <= length(command); i++) {
        c = substr(command, i, 1)
        if (quote != sq && index("$<>", c) > 0) join_continuations_after(i)
        following = substr(command, i + 1, 1)
        if (quote == sq) {
          if (c == sq) quote = ""
          word_boundary = 0
        } else if (c == "\\") {
          if (following == "\n") {
            command = substr(command, 1, i - 1) substr(command, i + 2)
            i--
            continue
          }
          i++
          word_boundary = 0
        } else if (quote == "" && c == "$" && following == sq) {
          i = skip_ansi_quote(i + 1)
          word_boundary = 0
        } else if (opening == "(" && quote == "" && c == "(" && following == "(") {
          # 산술식의 <<는 heredoc이 아니다. 평가 없이 괄호 경계만 소비한다.
          i = skip_expansion(i, collect && !command_scope, 1)
          word_boundary = 0
        } else if (command_scope && quote == "" && c == "#" && word_boundary) {
          while (i <= length(command) && substr(command, i, 1) != "\n") i++
        } else if (command_scope && quote == "" && c == "<" && following == "<") {
          if (substr(command, i, 3) == "<<<") { i += 2; word_boundary = 1; continue }
          # 종료 구분자를 해석하지 않고 남은 입력을 불투명하게 둔다. 데이터 속의
          # 닫는 괄호나 명령을 실행 스코프로 승격시키지 않는다.
          scope_count = before
          return length(command) + 1
        } else if (c == "`") {
          i = skip_backticks(i, collect && !command_scope, quote)
          word_boundary = 0
        } else if ((c == "$" && (following == "(" || following == "{")) ||
            (quote == "" && (c == "<" || c == ">") && following == "(")) {
          i = skip_expansion(i + 1, collect && !command_scope)
          word_boundary = 0
        } else if (quote == dq) {
          if (c == dq) quote = ""
          word_boundary = 0
        } else if (c == sq || c == dq) {
          quote = c
          word_boundary = 0
        } else if (opening == "(" && c == opening) {
          depth++
          word_boundary = 1
        } else if (c == closing && --depth == 0) {
          if (collect && command_scope) scopes[++scope_count] = substr(command, start + 1, i - start - 1)
          return i
        } else word_boundary = index(" \t\r\n;|&()<>", c) > 0
      }
      # 열린 부모가 닫히지 않았으면 그 안에서 찾은 자식도 실행 본문이 아니다.
      scope_count = before
      return i
    }
    function brace_range(raw, value) {
      # Bash 범위는 원문, zsh 범위는 인용/escape 해제 후 값으로 판별한다.
      # zsh는 끝점/간격이 빈 숫자 범위에서도 중괄호를 제거한다.
      return raw ~ /^[+-]?[0-9]+\.\.[+-]?[0-9]+(\.\.[+-]?[0-9]+)?$/ ||
        raw ~ /^[a-zA-Z]\.\.[a-zA-Z]\.\.[+-]?[0-9]+$/ ||
        value ~ /^.\.\..$/ ||
        (value != ".." && value ~ /^-?[0-9]*\.\.-?[0-9]*(\.\.-?[0-9]*)?$/)
    }
    function tokenize(    i, c, following, quote, range) {
      for (i = 1; i <= length(command); i++) {
        c = substr(command, i, 1)
        if (!started) { word_start = i; word_scopes_before = scope_count }
        # 확장 시작 기호의 다음 문자를 판별하기 전에 줄연속을 잇는다.
        # 이미 escape된 기호는 앞선 반복에서 소비됐고 작은따옴표는 보존한다.
        if (quote != sq && index("$<>", c) > 0) join_continuations_after(i)
        following = substr(command, i + 1, 1)
        if (quote == sq) {
          if (c == sq) quote = ""
          else word = word c
          if (c == "\n") dynamic = 1
          continue
        }
        if (c == "\\") {
          if (following == "") { dynamic = 1; scope_count = word_scopes_before; break }
          # 줄 연속은 제거될 뿐 새 단어를 시작하지 않는다. 범위 판정에 쓰는
          # 원문에서도 같은 구간을 제거한다. 작은따옴표 내부는 위에서 보존된다.
          if (following == "\n") {
            command = substr(command, 1, i - 1) substr(command, i + 2)
            i--
            continue
          }
          started = 1
          if (quote == dq && following != "$" && following != "`" && following != dq && following != "\\" && following != "\n") {
            word = word c
          } else {
            if (following != "\n") word = word following
            i++
          }
          continue
        }
        if (quote == dq && c == dq) { quote = ""; continue }
        if (quote == "" && (c == sq || c == dq)) { quote = c; started = 1; continue }
        if (c == "`" || (c == "$" && (following ~ /[[:alnum:]_@*#?$!{(^=~+-]/ ||
            (quote == "" && (following == sq || following == dq))))) {
          started = dynamic = 1
          # 확장 구간은 내부 표식으로만 남긴다. 변수 이름을 정적 endpoint
          # 조각으로 오인하거나, 동적 옵션 이름을 정적 이름으로 잇지 않는다.
          word = word "\001"
          if (c == "`") i = skip_backticks(i, 1, quote)
          else if (following == "(" || following == "{") i = skip_expansion(i + 1, 1)
          else if (following == sq) { shape_unknown = 1; i = skip_ansi_quote(i + 1) }
          else if (following == dq) shape_unknown = 1
          else {
            if (following ~ /^[@*#?$!0-9-]$/) { i++; continue }
            while (substr(command, i + 1, 1) ~ /^[\^=~+]$/) i++
            if (substr(command, i + 1, 1) ~ /^[A-Za-z_]$/) {
              do { i++ } while (substr(command, i + 1, 1) ~ /^[A-Za-z0-9_]$/)
            }
          }
          if (i > length(command)) scope_count = word_scopes_before
          continue
        }
        if (quote == "") {
          if (c == "(" && following == "(") {
            separator(c, i)
            i = skip_expansion(i, 1, 1)
            separator(")", i + 1)
            continue
          }
          if (scope > 1 && c == "<" && following == "<") {
            if (substr(command, i, 3) == "<<<") { start_redirection(i, 1); i += 2; continue }
            unsupported_scope = 1
            break
          }
          if ((c == "<" || c == ">") && following == "(") {
            started = dynamic = 1
            word = word "\001"
            i = skip_expansion(i + 1, 1)
            if (i > length(command)) scope_count = word_scopes_before
            continue
          }
          if (c == "&" && following == ">") {
            start_redirection(i, 0)
            i++
            if (substr(command, i + 1, 1) == ">") i++
            continue
          }
          if ((c == "<" || c == ">") && !(c == "<" && following == "<")) {
            start_redirection(i, 1)
            if (following == c || following == "&" || (c == ">" && following == "|") ||
                (c == "<" && following == ">")) i++
            continue
          }
          if (index(" \t\r\n", c) > 0) {
            if (c == "\n") separator(c, i)
            else finish_word(i)
            continue
          }
          if (index(";|&()<>", c) > 0) {
            separator(c, i)
            continue
          }
          if (c == "#" && !started) {
            while (i <= length(command) && substr(command, i, 1) != "\n") i++
            separator("\n", i)
            continue
          }
          # 리터럴 중괄호/닫는 대괄호는 파일명의 일부다. 인용되지 않은 쉼표
          # 목록 또는 범위가 있는 중괄호만 확장으로 본다.
          if (c == "{") {
            brace_start[++brace_depth] = length(word) + 2
            brace_raw_start[brace_depth] = i + 1
            brace_comma[brace_depth] = 0
          } else if (c == "," && brace_depth > 0) {
            brace_comma[brace_depth] = 1
          } else if (c == "}" && brace_depth > 0) {
            range = substr(word, brace_start[brace_depth])
            if (brace_comma[brace_depth] ||
                brace_range(substr(command, brace_raw_start[brace_depth], i - brace_raw_start[brace_depth]), range)) dynamic = 1
            brace_depth--
          }
          if (index("*?[", c) > 0 || (c == "~" && !started)) dynamic = 1
        }
        started = 1
        if (c == "\n") dynamic = 1
        word = word c
      }
      if (quote != "") { dynamic = 1; scope_count = word_scopes_before }
      finish_word(length(command) + 1)
    }
    function emit_field_or_path(v,    at) {
      if (index(v, "=") == 0) {
        print v
        return
      }
      at = index(v, "=@")
      if (at > 0) print substr(v, at + 2)
    }
    function api_value_option(option) {
      return option ~ /^(-[XFHqptf]|--(method|hostname|header|field|raw-field|input|jq|template|cache|preview))$/
    }
    # 옵션 모양의 제목·메시지 등은 데이터다. 실제 명령/동작에 맞는 값만
    # 소비하며, merge -m 및 review -a/-r 같은 불리언은 다음 단어를 삼키지 않는다.
    function nonbody_value_option(kind, option) {
      if (kind == "api") return api_value_option(option)
      if (kind == "git") return option ~ /^(-[mctCU]|--(message|template|reuse-message|reedit-message|author|date|cleanup|fixup|squash|trailer|unified|inter-hunk-context|pathspec-from-file|git-dir|work-tree|namespace|config-env))$/
      if (kind == "") return 0
      if (option ~ /^(-[bR]|--(body|repo))$/) return 1
      if (kind ~ / comment$/) return option == "--attach"
      if (kind == "pr review") return 0
      if (kind == "pr merge") return option ~ /^(-[At]|--(author-email|match-head-commit|subject))$/
      if (kind ~ / create$/ && option ~ /^(-[almpTt]|--(assignee|attach|label|milestone|project|recover|template|title))$/) return 1
      if (kind ~ / edit$/ && option ~ /^(-[mt]|--(add-assignee|add-label|add-project|attach|milestone|remove-assignee|remove-label|remove-project|title))$/) return 1
      if (kind == "pr create") return option ~ /^(-[BHr]|--(base|head|reviewer))$/
      if (kind == "pr edit") return option ~ /^(-B|--(base|add-reviewer|remove-reviewer))$/
      if (kind == "issue create") return option ~ /^--(blocked-by|blocking|parent|type)$/
      if (kind == "issue edit") return option ~ /^--(add-blocked-by|add-blocking|add-sub-issue|parent|remove-blocked-by|remove-blocking|remove-sub-issue|type)$/
      return 0
    }
    function scan_options(first, last, kind,    i, w) {
      i = first
      while (i <= last) {
        w = words[i]
        if (!literal[i]) { i++; continue }
        if (kind == "git" && w == "--") break
        if (w == "--body-file" || w == "--file" || w == "-F" || w == "--field") {
          if (i + 1 <= last) {
            i++
            if (literal[i] && words[i] != "") {
              if (w == "-F" || w == "--field") emit_field_or_path(words[i])
              else print words[i]
            }
          }
        } else if (w ~ /^--body-file=/) {
          sub(/^--body-file=/, "", w); if (w != "") print w
        } else if (w ~ /^--file=/) {
          sub(/^--file=/, "", w); if (w != "") print w
        } else if (nonbody_value_option(kind, w)) i++
        i++
      }
    }
    # 내부 스코프에서는 실제 명령 위치만 본다. printf 등에 전달된 옵션 모양의
    # 데이터는 게시 인자가 아니다. 함수·별칭·임의 wrapper와 작업 폴더는 해석하지 않는다.
    function git_commit_command(i, last,    option) {
      for (; i <= last; i++) {
        option = words[i]
        # 값의 확장은 명령 식별을 막지 않는다. 옵션 이름은 표식 앞에서
        # 정적으로 확인하고, 본문 경로의 literal 조건은 별도로 유지한다.
        if (option ~ /^(-[Cc].+|--(git-dir|work-tree|namespace|config-env|exec-path)=)/) continue
        if (!literal[i]) return 0
        if (option == "commit") { git_options_start = i + 1; return 1 }
        if (option ~ /^(-C|-c|--git-dir|--work-tree|--namespace|--config-env)$/) { i++; continue }
        if (option ~ /^(-p|-P|--paginate|--no-pager|--no-replace-objects|--no-lazy-fetch|--no-optional-locks|--no-advice|--bare|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs)$/) continue
        return 0
      }
      return 0
    }
    function api_endpoint(i, last,    option) {
      for (; i <= last; i++) {
        option = words[i]
        if (option ~ /^(-[XFHqptf].+|--(method|hostname|header|field|raw-field|input|jq|template|cache|preview)=)/) continue
        if (literal[i] && option == "--") return i < last && !unknown_shape[i + 1] ? words[i + 1] : ""
        if (literal[i] && api_value_option(option)) { i++; continue }
        if (literal[i] && option ~ /^(-i|--include|--paginate|--slurp|--silent|--verbose|--allow-escape-sequences)$/) continue
        if (unknown_shape[i]) return ""
        return substr(option, 1, 1) == "-" ? "" : option
      }
      return ""
    }
    function publishing_command(first, last,    i, section, action, endpoint, executable) {
      i = first
      git_options_start = data_only_command = 0
      while (i <= last && assignment[i]) i++
      if (literal[i] && words[i] == "command") {
        i++
        if (literal[i] && words[i] == "-p") i++
        if (literal[i] && words[i] == "--") i++
      }
      if (i > last || !literal[i]) return ""
      data_only_command = words[i] == "printf"
      executable = words[i]
      if (substr(executable, 1, 1) == "/") sub(/^.*\//, "", executable)
      if (executable == "git") return git_commit_command(i + 1, last) ? "git" : ""
      if (words[i] != "gh" || !literal[i + 1]) return ""
      section = words[i + 1]; action = words[i + 2]
      if (section == "pr") return literal[i + 2] && action ~ /^(create|edit|comment|review|merge)$/ ? section " " action : ""
      if (section == "issue") return literal[i + 2] && action ~ /^(create|edit|comment)$/ ? section " " action : ""
      if (section != "api") return ""
      endpoint = api_endpoint(i + 2, last)
      return endpoint ~ /issues\/.*comments/ || endpoint ~ /pulls\/.*(comments|reviews)/ ? "api" : ""
    }
    function scan_scope(restricted,    first, last, kind) {
      first = 1
      for (last = 1; last <= count + 1; last++) {
        if (last > count || boundary[last]) {
          kind = publishing_command(first, last - 1)
          # printf 데이터는 제외하되, 인자 안에서 수집한 실행 스코프는 별도로 검사한다.
          if (!data_only_command && (!restricted || kind != ""))
            scan_options(kind == "git" ? git_options_start : first, last - 1, kind)
          first = last + 1
        }
      }
    }
    { command = command (NR > 1 ? "\n" : "") $0 }
    END {
      scopes[1] = command; scope_count = 1
      for (scope = 1; scope <= scope_count; scope++) {
        command = scopes[scope]
        delete scopes[scope]
        for (key in words) delete words[key]
        for (key in literal) delete literal[key]
        for (key in unknown_shape) delete unknown_shape[key]
        for (key in assignment) delete assignment[key]
        for (key in boundary) delete boundary[key]
        word = ""; count = started = dynamic = brace_depth = shape_unknown = unsupported_scope = redirect_target = 0
        before = scope_count
        tokenize()
        if (unsupported_scope) scope_count = before
        else scan_scope(scope > 1)
      }
    }
  '
}
