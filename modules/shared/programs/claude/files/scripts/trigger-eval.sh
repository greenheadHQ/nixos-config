#!/usr/bin/env bash
# trigger-eval.sh — Custom skill trigger evaluation
#
# Tests whether Claude correctly triggers (or avoids) a skill
# by running claude -p with --allowedTools "Skill" and checking
# the Skill tool call in JSON output.
#
# Usage:
#   trigger-eval.sh --skill <name> --queries <path> [--reps N] [--workers N] [--timeout N] [--threshold F]
#   trigger-eval.sh --queries <path>                 # auto-detect skill from queries.json parent dir
#   trigger-eval.sh --batch <dir>                    # run all skills with evals/ subdirs (dir must be the project root)
#
# Input (queries.json):
#   [{"query": "...", "should_trigger": true, "why": "..."}]
#
# Output: JSON results to stdout
#
# Environment:
#   CLAUDECODE is removed to allow nesting claude -p inside a Claude Code session.

set -euo pipefail

# --- Defaults ---
REPS=1
WORKERS=4
TIMEOUT=30
SKILL=""
QUERIES=""
THRESHOLD="0.5"
BATCH_DIR=""

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skill)    SKILL="$2";     shift 2 ;;
    --queries)  QUERIES="$2";   shift 2 ;;
    --reps)     REPS="$2";      shift 2 ;;
    --workers)  WORKERS="$2";   shift 2 ;;
    --timeout)  TIMEOUT="$2";   shift 2 ;;
    --threshold) THRESHOLD="$2"; shift 2 ;;
    --batch)    BATCH_DIR="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# --- Batch mode ---
if [[ -n "$BATCH_DIR" ]]; then
  results=()
  # Project-local skills (.claude/skills/)
  # Global skills source (modules/shared/.../skills/)
  for qfile in "$BATCH_DIR"/.claude/skills/*/evals/queries.json \
               "$BATCH_DIR"/modules/shared/programs/claude/files/skills/*/evals/queries.json; do
    [[ -f "$qfile" ]] || continue
    skill_dir="$(dirname "$(dirname "$qfile")")"
    skill_name="$(basename "$skill_dir")"
    result=$("$0" --skill "$skill_name" --queries "$qfile" --reps "$REPS" --workers "$WORKERS" --timeout "$TIMEOUT" --threshold "$THRESHOLD" 2>/dev/null)
    results+=("$result")
  done
  if [[ ${#results[@]} -eq 0 ]]; then
    echo "Error: no evals found under '$BATCH_DIR'." >&2
    echo "Pass the project root, not a skills subdirectory." >&2
    echo "Example: trigger-eval.sh --batch ." >&2
    exit 1
  fi
  printf '%s\n' "${results[@]}" | jq -s '.'
  exit 0
fi

# --- Validate args ---
if [[ -z "$QUERIES" ]]; then
  echo "Error: --queries <path> is required" >&2
  exit 1
fi

if [[ -z "$SKILL" ]]; then
  # Auto-detect from queries.json parent directory structure
  # .claude/skills/<name>/evals/queries.json → <name>
  skill_dir="$(dirname "$(dirname "$QUERIES")")"
  SKILL="$(basename "$skill_dir")"
fi

if [[ ! -f "$QUERIES" ]]; then
  echo "Error: queries file not found: $QUERIES" >&2
  exit 1
fi

# --- Core: run a single query ---
run_query() {
  local query="$1"
  local timeout="$2"

  # Remove CLAUDECODE (nesting guard) and ANTHROPIC_API_KEY (forces API key mode
  # with Sonnet default instead of subscription Opus) to ensure eval runs use
  # the user's subscription with their configured model.
  # Set SKILL_EVAL_MODE=1 so PreToolUse hooks skip logging (#283).
  local output
  output=$(env -u CLAUDECODE -u ANTHROPIC_API_KEY SKILL_EVAL_MODE=1 timeout "${timeout}s" \
    claude -p "$query" \
      --output-format json \
      --max-turns 1 \
      --allowedTools "Skill" \
      --no-session-persistence \
    2>/dev/null) || true

  # Parse: find the first Skill tool call
  local triggered_skill
  triggered_skill=$(echo "$output" | jq -r '
    [.[] | select(.type == "assistant") | .message.content[]?
     | select(.type == "tool_use" and .name == "Skill")
     | .input.skill] | first // "none"
  ' 2>/dev/null) || triggered_skill="error"

  echo "$triggered_skill"
}

export -f run_query

# --- Run all queries ---
query_count=$(jq length "$QUERIES")
total_runs=$((query_count * REPS))

# Build work items: index,rep pairs
work_items=()
for ((i = 0; i < query_count; i++)); do
  for ((r = 0; r < REPS; r++)); do
    work_items+=("$i")
  done
done

results_dir=$(mktemp -d)
trap 'rm -rf "$results_dir"' EXIT

echo "Evaluating skill: $SKILL ($query_count queries × $REPS reps = $total_runs runs)" >&2

# Parallel execution with worker limit
completed=0
pids=()
for idx in "${work_items[@]}"; do
  query=$(jq -r ".[$idx].query" "$QUERIES")

  (
    result=$(run_query "$query" "$TIMEOUT")
    echo "$result" >> "$results_dir/q${idx}.txt"
  ) &
  pids+=($!)

  # Worker limit
  if (( ${#pids[@]} >= WORKERS )); then
    wait "${pids[0]}" 2>/dev/null || true
    pids=("${pids[@]:1}")
    completed=$((completed + 1))
    printf "\r  [%d/%d] " "$completed" "$total_runs" >&2
  fi
done

# Wait for remaining
for pid in "${pids[@]}"; do
  wait "$pid" 2>/dev/null || true
  completed=$((completed + 1))
  printf "\r  [%d/%d] " "$completed" "$total_runs" >&2
done

echo "" >&2

# --- Aggregate results ---
export SKILL_VAR="$SKILL" QUERIES_VAR="$QUERIES" RESULTS_DIR_VAR="$results_dir" REPS_VAR="$REPS" THRESHOLD_VAR="$THRESHOLD"
jq -n --arg skill "$SKILL" --argjson reps "$REPS" '
  { skill_name: $skill, reps_per_query: $reps, results: [], summary: {} }
' | python3 -c "
import json, sys, os

skill = os.environ['SKILL_VAR']
queries = json.load(open(os.environ['QUERIES_VAR']))
results_dir = os.environ['RESULTS_DIR_VAR']
reps = int(os.environ['REPS_VAR'])
threshold = float(os.environ.get('THRESHOLD_VAR', '0.5'))

results = []
tp = tn = fp = fn = 0

for i, q in enumerate(queries):
    result_file = os.path.join(results_dir, f'q{i}.txt')
    triggers = []
    if os.path.exists(result_file):
        with open(result_file) as f:
            triggers = [line.strip() for line in f if line.strip()]

    trigger_count = sum(1 for t in triggers if t == skill)
    total_runs = len(triggers) if triggers else reps
    trigger_rate = trigger_count / total_runs if total_runs > 0 else 0

    should = q['should_trigger']
    if should:
        passed = trigger_rate >= threshold
        if passed:
            tp += 1
        else:
            fn += 1
    else:
        passed = trigger_rate < threshold
        if passed:
            tn += 1
        else:
            fp += 1

    results.append({
        'query': q['query'],
        'should_trigger': should,
        'triggered_skill': triggers[0] if triggers else 'none',
        'trigger_count': trigger_count,
        'total_runs': total_runs,
        'trigger_rate': trigger_rate,
        'pass': passed,
        'why': q.get('why', ''),
    })

total = len(results)
passed_count = sum(1 for r in results if r['pass'])
precision = tp / (tp + fp) if (tp + fp) > 0 else 1.0
recall = tp / (tp + fn) if (tp + fn) > 0 else 1.0
accuracy = (tp + tn) / total if total > 0 else 0.0
f1 = 2 * precision * recall / (precision + recall) if (precision + recall) > 0 else 0.0

output = {
    'skill_name': skill,
    'reps_per_query': reps,
    'results': results,
    'summary': {
        'total': total,
        'passed': passed_count,
        'failed': total - passed_count,
        'accuracy': round(accuracy, 4),
        'precision': round(precision, 4),
        'recall': round(recall, 4),
        'f1': round(f1, 4),
        'tp': tp, 'tn': tn, 'fp': fp, 'fn': fn,
    }
}

print(json.dumps(output, indent=2, ensure_ascii=False))
"
