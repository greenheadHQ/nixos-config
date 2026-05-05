#!/usr/bin/env bash
# measure-anchoring-bias.sh
#
# Measure plan-with-questions anchoring-bias signals across Claude Code
# transcripts on Mac local + MiniPC.
#
# 4-axis grep (codex:rescue meta-consultation recommendation):
#   1. user choice capture
#   2. recommendation framing
#   3. post-hoc defect
#   4. redesign resistance
#
# Output: per-host candidate session counts + intersection metrics.
# Hardcoded measurement numbers are forbidden in skill docs — this script
# is the canonical source. The doc table is illustrative; PAT_* arrays here
# are authoritative.
#
# Scope: this script measures TRANSCRIPT anchoring signals only. PWQ source
# label sanitization (D4 정책 일관성 — source 본문에서 (Recommended) 라벨이
# 합의 PASS 컨텍스트로만 등장하는지 검증) is a separate baseline whose SSOT
# lives in modules/shared/programs/claude/files/skills/plan-with-questions/
# references/bias-measurement.md "Source label sanitization baseline (D4 정책
# 일관성)" section. Run that section's inline `rg` commands against the
# repo-tracked source tree by default; after merge + nrs, optionally re-check
# the deployed `~/.claude/skills/plan-with-questions/` tree. Keeping the two
# cadences separate avoids coupling D4 policy changes to transcript metric
# releases.
#
# Usage:
#   ./scripts/ai/measure-anchoring-bias.sh             # default mtime=-60
#   ./scripts/ai/measure-anchoring-bias.sh -d 30       # mtime=-30
#   ./scripts/ai/measure-anchoring-bias.sh --skip-ssh  # local only
#   ./scripts/ai/measure-anchoring-bias.sh --json      # JSON output
#
# Exit semantics:
#   - Metric collection failures (ssh down, transcripts absent, etc.):
#     return 0. Per-host failure surfaces as a structured object in --json
#     or `host|status=fail|<reason>` in plain text — never plain text inside
#     a JSON array.
#   - CLI usage errors (invalid --days digits, unsafe --ssh-host, unknown
#     flag): return 2 immediately (validation runs before any metric work).

set -uo pipefail

# ---------------------------------------------------------------------------
# CLI parsing with input validation (avoid shell injection via remote eval)
# ---------------------------------------------------------------------------

DAYS="60"
SKIP_SSH=0
JSON=0

# Detect local host kind (Darwin = Mac, Linux = MiniPC) for label + remote default.
case "$(uname -s)" in
    Darwin) LOCAL_LABEL="mac"; SSH_HOST_DEFAULT="minipc" ;;
    Linux)  LOCAL_LABEL="minipc"; SSH_HOST_DEFAULT="mac" ;;
    *)      LOCAL_LABEL="local"; SSH_HOST_DEFAULT="" ;;
esac
SSH_HOST="$SSH_HOST_DEFAULT"

usage() {
    cat <<'USAGE'
measure-anchoring-bias.sh — measure plan-with-questions anchoring-bias
signals across Claude Code transcripts (Mac local + MiniPC).

Usage:
  ./scripts/ai/measure-anchoring-bias.sh             # default mtime=-60
  ./scripts/ai/measure-anchoring-bias.sh -d 30       # mtime=-30
  ./scripts/ai/measure-anchoring-bias.sh --skip-ssh  # local only
  ./scripts/ai/measure-anchoring-bias.sh --json      # JSON output
  ./scripts/ai/measure-anchoring-bias.sh --ssh-host <host>

Output: per-host candidate session counts + intersection metrics.
Exit semantics: metric collection failures return 0; CLI usage errors
return 2. See file header comment for the full contract.
USAGE
    exit 0
}

validate_days() {
    case "$1" in
        ''|*[!0-9]*)
            echo "error: --days must be a positive integer (got: $1)" >&2
            exit 2
            ;;
    esac
    # Reject zero / leading-zero (e.g., 0, 00, 001) since `find -mtime -0` is degenerate
    # and JSON output would emit a non-canonical integer literal.
    if [ "$1" -lt 1 ] 2>/dev/null; then
        echo "error: --days must be >= 1 (got: $1)" >&2
        exit 2
    fi
    if [ "$1" != "$((10#$1))" ]; then
        echo "error: --days must not have leading zeros (got: $1)" >&2
        exit 2
    fi
}

validate_host() {
    # Permit alphanumeric, dot, hyphen, underscore; rejects shell metacharacters.
    case "$1" in
        ''|*[!A-Za-z0-9._-]*)
            echo "error: --ssh-host contains unsafe characters (got: $1)" >&2
            exit 2
            ;;
    esac
}

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--days)
            validate_days "${2:-}"
            DAYS="$2"
            shift 2
            ;;
        --skip-ssh) SKIP_SSH=1; shift ;;
        --json) JSON=1; shift ;;
        --ssh-host)
            validate_host "${2:-}"
            SSH_HOST="$2"
            shift 2
            ;;
        -h|--help) usage ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

# CLAUDE.md SSH-to-self prohibition: explicit alias denylist enforces the policy
# even when --ssh-host overrides the uname-derived default. uname-only check is
# necessary but not sufficient — the alias-level check covers the override path.
case "$LOCAL_LABEL" in
    mac)
        if [ "$SSH_HOST" = "mac" ]; then
            echo "error: ssh to local darwin host alias 'mac' is prohibited (CLAUDE.md policy)" >&2
            exit 2
        fi
        ;;
    minipc)
        if [ "$SSH_HOST" = "minipc" ]; then
            echo "error: ssh to local linux host alias 'minipc' is prohibited (CLAUDE.md policy)" >&2
            exit 2
        fi
        ;;
esac

# ---------------------------------------------------------------------------
# 4-axis grep patterns (canonical — doc table mirrors these for human ref)
# ---------------------------------------------------------------------------

# Note: PAT_choice and PAT_framing intentionally overlap on `추천`. choice
# captures any line where a user selection or recommendation token appears
# (regardless of who proposed it); framing isolates the LLM-side framing
# vocabulary. The intersection (choice ∩ framing) is meaningful — it flags
# transcripts where both user decision context and LLM recommendation
# language coexist, which is exactly the anchoring surface we measure.
PAT_choice='사용자 결정|사용자 확인 완료|선호|선택|추천|A 방식|B 방식|어느 쪽|AskUserQuestion|충분|인지'
PAT_framing='추천|권장|기본값|best|Recommended|강력히'
# review-implementation: legacy alias (standalone skill 폐지 #611, plan-with-questions/references/review-impl/*로 흡수). 과거 transcript history 매칭용으로 유지.
PAT_defect='DA Round|CONFIRMED_ISSUE|NEEDS_MORE_INFO|YAGNI|NGMI|REGRESSION|overbuilt|missing|conflicting|parallel-audit|review-implementation|review-impl'
PAT_resistance='사용자 결정에 따라|현상 유지|기각|생략|그래도|재설계.*거부|redesign.*reject|추천대로'

# Lookup helper since bash doesn't support indirect array reference uniformly.
pattern_for() {
    case "$1" in
        choice) printf '%s' "$PAT_choice" ;;
        framing) printf '%s' "$PAT_framing" ;;
        defect) printf '%s' "$PAT_defect" ;;
        resistance) printf '%s' "$PAT_resistance" ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Counting helpers — guard empty input list to prevent rg from scanning cwd
# ---------------------------------------------------------------------------

# count_matching <list-file> <pattern>
# Empty list emits 0; never invokes rg without explicit file operands.
count_matching() {
    local list="$1" pat="$2"
    if [ ! -s "$list" ]; then
        echo 0
        return
    fi
    tr '\n' '\0' < "$list" | xargs -0 rg -l -e "$pat" 2>/dev/null | wc -l | tr -d ' '
}

# filter_matching <input-list> <pattern> <output-list>
# Empty input → empty output; same guard as count_matching.
filter_matching() {
    local in="$1" pat="$2" out="$3"
    if [ ! -s "$in" ]; then
        : > "$out"
        return
    fi
    tr '\n' '\0' < "$in" | xargs -0 rg -l -e "$pat" 2>/dev/null > "$out"
}

# ---------------------------------------------------------------------------
# Output emitters — JSON-aware, never bleed plain text into JSON array
# ---------------------------------------------------------------------------

# escape_json <string> — minimal JSON string escape using jq.
# python3 isn't in the Darwin baseline; jq is.
# -R reads stdin as a raw string, -s slurps to a single value, `.` returns it as JSON
# (quoted, escaped). `-j` would strip the surrounding quotes (raw output), which we
# don't want — we need the quoted JSON string. `tr -d '\n'` strips jq's trailing
# newline so the result is safely embedded inside a JSON object.
escape_json() {
    printf '%s' "$1" | jq -Rs . | tr -d '\n'
}

emit_skip() {
    local label="$1" total="$2"
    if [ "$JSON" -eq 1 ]; then
        printf '{"host":"%s","days":%s,"total":%s,"status":"skip"}' "$label" "$DAYS" "$total"
    else
        echo "$label|status=skip|total=$total"
    fi
}

emit_fail() {
    local label="$1" reason="$2"
    if [ "$JSON" -eq 1 ]; then
        local esc
        esc=$(escape_json "$reason")
        printf '{"host":"%s","days":%s,"status":"fail","reason":%s}' "$label" "$DAYS" "$esc"
    else
        echo "$label|status=fail|reason=$reason"
    fi
}

emit_metrics() {
    local label="$1" total="$2" c="$3" f="$4" d="$5" r="$6" cd="$7" anchor="$8"
    if [ "$JSON" -eq 1 ]; then
        printf '{"host":"%s","days":%s,"status":"ok","total":%s,"choice":%s,"framing":%s,"defect":%s,"resistance":%s,"choice_and_defect":%s,"anchoring_candidate":%s}' \
            "$label" "$DAYS" "$total" "$c" "$f" "$d" "$r" "$cd" "$anchor"
    else
        echo "$label (mtime=-${DAYS}d)"
        echo "  total transcripts:           $total"
        echo "  axis-1 choice:               $c"
        echo "  axis-2 recommendation:       $f"
        echo "  axis-3 post-hoc defect:      $d"
        echo "  axis-4 redesign resistance:  $r"
        echo "  intersect choice ∩ defect:   $cd"
        echo "  full anchoring candidate:    $anchor"
        if [ "$total" -gt 0 ] && [ "$cd" -le "$total" ]; then
            local pct
            pct=$(awk "BEGIN { printf \"%.1f\", ($cd / $total) * 100 }")
            echo "  choice_then_defect_rate:     ${pct}%"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Local measurement
# ---------------------------------------------------------------------------

measure_host_local() {
    local label="$1"
    local scratch
    # mktemp -d failure (e.g., /tmp not writable, disk full) must fail closed via emit_fail
    # so that --json mode doesn't bleed an empty/garbled payload into the JSON array.
    if ! scratch=$(mktemp -d 2>/dev/null); then
        emit_fail "$label" "mktemp -d failed (TMPDIR not writable?)"
        return
    fi
    # Cleanup on function exit. Intentional expansion at trap-setup time so $scratch is fixed.
    # shellcheck disable=SC2064
    trap "rm -rf '$scratch'" RETURN

    find "$HOME/.claude/projects" -name '*.jsonl' -mtime "-${DAYS}" 2>/dev/null > "$scratch/all.txt"
    local total
    total=$(wc -l < "$scratch/all.txt" | tr -d ' ')

    if [ "$total" = "0" ]; then
        emit_skip "$label" "$total"
        return
    fi

    # Per-axis counts
    local c f d r
    c=$(count_matching "$scratch/all.txt" "$(pattern_for choice)")
    f=$(count_matching "$scratch/all.txt" "$(pattern_for framing)")
    d=$(count_matching "$scratch/all.txt" "$(pattern_for defect)")
    r=$(count_matching "$scratch/all.txt" "$(pattern_for resistance)")

    # Intersection: choice ∩ defect
    filter_matching "$scratch/all.txt" "$(pattern_for choice)" "$scratch/c.txt"
    local cd
    cd=$(count_matching "$scratch/c.txt" "$(pattern_for defect)")

    # Full anchoring candidate: choice ∩ framing ∩ defect ∩ resistance
    filter_matching "$scratch/c.txt" "$(pattern_for framing)" "$scratch/cf.txt"
    filter_matching "$scratch/cf.txt" "$(pattern_for defect)" "$scratch/cfd.txt"
    local anchor
    anchor=$(count_matching "$scratch/cfd.txt" "$(pattern_for resistance)")

    emit_metrics "$label" "$total" "$c" "$f" "$d" "$r" "$cd" "$anchor"
}

# ---------------------------------------------------------------------------
# Remote measurement — ssh argv-safe, no eval, remote script via stdin
# ---------------------------------------------------------------------------

measure_host_remote() {
    local label="$1" host="$2"

    # Build a remote script via UNQUOTED heredoc (`<<RSCRIPT`, no quoting on
    # the terminator). This is intentional: host-side variables `${DAYS}`,
    # `${PAT_*}` are expanded once into the script body before transmission,
    # and remote variable references are escaped as `\$` to defer to the
    # remote bash. The result is a static script string with patterns and
    # days inlined as literals — remote bash receives it via stdin and never
    # re-parses host variables.
    #
    # Safety: validate_days/validate_host gate the inlined values upstream;
    # eval is never invoked on either side.
    local remote_script
    remote_script=$(cat <<RSCRIPT
set -uo pipefail
TMP=\$(mktemp -d)
trap "rm -rf '\$TMP'" EXIT

find "\$HOME/.claude/projects" -name '*.jsonl' -mtime "-${DAYS}" 2>/dev/null > "\$TMP/all.txt"
total=\$(wc -l < "\$TMP/all.txt" | tr -d ' ')
if [ "\$total" = "0" ]; then
    echo "SKIP \$total"
    exit 0
fi

count_in() {
    local list="\$1" pat="\$2"
    [ ! -s "\$list" ] && { echo 0; return; }
    tr '\n' '\0' < "\$list" | xargs -0 rg -l -e "\$pat" 2>/dev/null | wc -l | tr -d ' '
}
filter_in() {
    local in="\$1" pat="\$2" out="\$3"
    [ ! -s "\$in" ] && { : > "\$out"; return; }
    tr '\n' '\0' < "\$in" | xargs -0 rg -l -e "\$pat" 2>/dev/null > "\$out"
}

P_C='${PAT_choice}'
P_F='${PAT_framing}'
P_D='${PAT_defect}'
P_R='${PAT_resistance}'

c=\$(count_in "\$TMP/all.txt" "\$P_C")
f=\$(count_in "\$TMP/all.txt" "\$P_F")
d=\$(count_in "\$TMP/all.txt" "\$P_D")
r=\$(count_in "\$TMP/all.txt" "\$P_R")

filter_in "\$TMP/all.txt" "\$P_C" "\$TMP/c.txt"
cd=\$(count_in "\$TMP/c.txt" "\$P_D")

filter_in "\$TMP/c.txt" "\$P_F" "\$TMP/cf.txt"
filter_in "\$TMP/cf.txt" "\$P_D" "\$TMP/cfd.txt"
anchor=\$(count_in "\$TMP/cfd.txt" "\$P_R")

echo "OK \$total \$c \$f \$d \$r \$cd \$anchor"
RSCRIPT
)

    # Argv-safe ssh; remote bash reads script from stdin (no eval, no shell expansion of script body).
    local result
    # Skip remote if host is empty (unknown OS) or matches local hostname (self-ssh).
    if [ -z "$host" ]; then
        emit_skip "$label" "0"
        return
    fi
    if [ "$host" = "$(hostname -s 2>/dev/null)" ] || [ "$host" = "$(hostname 2>/dev/null)" ]; then
        emit_fail "$label" "remote host matches local hostname (would self-ssh)"
        return
    fi
    # Bound failure: BatchMode prevents password prompts, ConnectTimeout/ConnectionAttempts
    # cap blackhole/Tailscale-down latency at ~5s instead of TCP default ~75s × 3.
    if ! result=$(ssh -o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1 \
        -- "$host" 'bash -s' <<<"$remote_script" 2>/dev/null); then
        emit_fail "$label" "ssh exec failed (host=$host)"
        return
    fi
    if [ -z "$result" ]; then
        emit_fail "$label" "ssh returned empty"
        return
    fi

    local marker rest
    marker=$(printf '%s' "$result" | awk 'NR==1{print $1; exit}')
    rest=$(printf '%s' "$result" | awk 'NR==1{$1=""; sub(/^ /,""); print; exit}')

    case "$marker" in
        SKIP)
            emit_skip "$label" "$rest"
            ;;
        OK)
            local total c f d r cd anchor
            read -r total c f d r cd anchor <<<"$rest"
            emit_metrics "$label" "$total" "$c" "$f" "$d" "$r" "$cd" "$anchor"
            ;;
        *)
            emit_fail "$label" "unexpected marker: $marker"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [ "$JSON" -eq 1 ]; then
    echo "["
    measure_host_local "$LOCAL_LABEL"
    if [ "$SKIP_SSH" -eq 0 ] && [ -n "$SSH_HOST" ]; then
        printf ',\n'
        measure_host_remote "$SSH_HOST" "$SSH_HOST"
    fi
    printf '\n]\n'
else
    echo "=== Anchoring-bias signal measurement ==="
    echo
    measure_host_local "$LOCAL_LABEL"
    if [ "$SKIP_SSH" -eq 0 ] && [ -n "$SSH_HOST" ]; then
        echo
        measure_host_remote "$SSH_HOST" "$SSH_HOST"
    fi
    echo
    echo "Notes:"
    echo "  - Counts are file-level (any line match within a transcript)."
    echo "  - 'anchoring candidate' requires all 4 axes in the same file —"
    echo "    strong signal but excludes legitimate plans where only some"
    echo "    axes appear (still informative as a lower bound)."
    echo "  - For line-ordering analysis (choice line BEFORE defect line),"
    echo "    extend with awk/jq — out of scope for this script."
fi
