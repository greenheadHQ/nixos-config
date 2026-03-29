#!/usr/bin/env bash
# run-loop.sh — Description optimization loop via claude -p
#
# Orchestrates run-eval.sh and improve-description.sh in an iterative
# loop to find the best skill description. Uses train/test split to prevent
# overfitting. Drop-in replacement for skill-creator's run_loop.py,
# eliminating the ANTHROPIC_API_KEY requirement.
#
# Usage:
#   run-loop.sh --eval-set <json> --skill-path <dir>
#               [--max-iterations 5] [--runs-per-query 3] [--holdout 0.4]
#               [--num-workers 4] [--timeout 30] [--trigger-threshold 0.5]
#               [--description TEXT] [--apply] [--verbose]
#               [--report auto|none|PATH] [--results-dir DIR]
#
# Output: JSON results to stdout
#
# WHY in-place SKILL.md modification:
#   claude -p reads skill descriptions from .claude/skills/SKILL.md on disk.
#   No --description override CLI option exists, so in-place modification is
#   the only way to test different descriptions. trap restores the original
#   on exit or failure.

set -euo pipefail

# --- Constants ---
SPLIT_SEED=42

# --- Defaults ---
SKILL_PATH=""
EVAL_SET=""
MAX_ITERATIONS=5
RUNS_PER_QUERY=3
HOLDOUT="0.4"
NUM_WORKERS=4
TIMEOUT=30
TRIGGER_THRESHOLD="0.5"
DESCRIPTION_OVERRIDE=""
APPLY=false
VERBOSE=false
REPORT="none"
RESULTS_DIR=""
FINALIZED=false

# --- Locate sibling scripts ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Logging ---
log() { [[ "$VERBOSE" == "true" ]] && echo "$@" >&2 || true; }

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --eval-set|--queries) EVAL_SET="$2";           shift 2 ;;
    --skill-path)         SKILL_PATH="$2";         shift 2 ;;
    --max-iterations)     MAX_ITERATIONS="$2";     shift 2 ;;
    --runs-per-query|--reps) RUNS_PER_QUERY="$2";  shift 2 ;;
    --holdout)            HOLDOUT="$2";            shift 2 ;;
    --num-workers)        NUM_WORKERS="$2";        shift 2 ;;
    --timeout)            TIMEOUT="$2";            shift 2 ;;
    --trigger-threshold)  TRIGGER_THRESHOLD="$2";  shift 2 ;;
    --description)        DESCRIPTION_OVERRIDE="$2"; shift 2 ;;
    --apply)              APPLY=true;              shift ;;
    --verbose)            VERBOSE=true;            shift ;;
    --report)             REPORT="$2";             shift 2 ;;
    --results-dir)        RESULTS_DIR="$2";        shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# --- Validate args ---
if [[ -z "$SKILL_PATH" ]]; then
  echo "Error: --skill-path <dir> is required" >&2
  exit 1
fi

if [[ -z "$EVAL_SET" ]]; then
  echo "Error: --eval-set <json> is required" >&2
  exit 1
fi

if [[ ! -f "$SKILL_PATH/SKILL.md" ]]; then
  echo "Error: No SKILL.md found at $SKILL_PATH" >&2
  exit 1
fi

if [[ ! -f "$EVAL_SET" ]]; then
  echo "Error: eval set file not found: $EVAL_SET" >&2
  exit 1
fi

# --- Extract skill name ---
skill_name=$(SKILL_FILE="$SKILL_PATH/SKILL.md" python3 -c "
import re, os
content = open(os.environ['SKILL_FILE']).read()
m = re.search(r'^name:\s*(.+)', content, re.MULTILINE)
print(m.group(1).strip().strip('\"').strip(\"'\") if m else 'unknown')
")

# --- Setup temp dir ---
# Temp file lifecycle:
# train.json, test.json: created once before loop
# eval-results.json: overwritten each iteration
# iter-N-train.json, iter-N-test.json: per-iteration full eval results
# best_desc.txt: overwritten when best is updated
# current_desc.txt: overwritten each iteration
# original-skill.md: created once, used for restoration
# improve_history.json: accumulated improve-description.sh history
work_dir=$(mktemp -d)
cleanup() {
  [[ -d "$work_dir" ]] || return 0
  if [[ -f "$work_dir/original-skill.md" && "$FINALIZED" != "true" ]]; then
    cp "$work_dir/original-skill.md" "$SKILL_PATH/SKILL.md"
    echo "Restored original SKILL.md" >&2
  fi
  rm -rf "$work_dir"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# --- Backup SKILL.md ---
cp "$SKILL_PATH/SKILL.md" "$work_dir/original-skill.md"

# --- Extract current description ---
extract_description() {
  local skill_md="$1"
  SKILL_FILE="$skill_md" python3 -c "
import os
lines = open(os.environ['SKILL_FILE']).readlines()
in_front, in_desc, desc_lines = False, False, []
for line in lines:
    if line.strip() == '---':
        if in_desc: break
        in_front = not in_front
        continue
    if in_front and line.startswith('description:'):
        rest = line[len('description:'):].strip()
        if rest == '|' or rest == '>':
            in_desc = True
        elif rest:
            print(rest.strip('\"').strip(\"'\"))
        continue
    if in_front and in_desc:
        if line[0:1] not in (' ', '\t'):
            break
        desc_lines.append(line.strip())
if desc_lines:
    print('\n'.join(desc_lines))
"
}

original_description=$(extract_description "$SKILL_PATH/SKILL.md")
if [[ -z "$original_description" ]]; then
  echo "Error: SKILL.md is missing a frontmatter description field: $SKILL_PATH/SKILL.md" >&2
  exit 1
fi

# Use --description override if provided
if [[ -n "$DESCRIPTION_OVERRIDE" ]]; then
  current_description="$DESCRIPTION_OVERRIDE"
else
  current_description="$original_description"
fi

# Save descriptions to temp files
printf '%s' "$original_description" > "$work_dir/original_desc.txt"
printf '%s' "$current_description" > "$work_dir/best_desc.txt"
printf '%s' "$current_description" > "$work_dir/current_desc.txt"

# --- Replace SKILL.md description ---
# WHY in-place: claude -p reads .claude/skills/SKILL.md directly.
# No --description override exists in claude -p CLI. (DA NGMI #1 verified)
replace_description() {
  local skill_md="$1"
  local new_desc_file="$2"

  SKILL_MD="$skill_md" DESC_FILE="$new_desc_file" python3 -c "
import os
skill_md = os.environ['SKILL_MD']
new_desc = open(os.environ['DESC_FILE']).read().strip()
lines = open(skill_md).readlines()
result, in_front, in_desc = [], False, False
for line in lines:
    stripped = line.strip()
    if stripped == '---':
        if in_desc: in_desc = False
        in_front = not in_front
        result.append(line)
        continue
    if in_front and line.startswith('description:'):
        result.append('description: |\n')
        for dl in new_desc.split('\n'):
            result.append(f'  {dl}\n')
        in_desc = True
        continue
    if in_front and in_desc:
        if line[0:1] not in (' ', '\t', ''):
            in_desc = False
            result.append(line)
        continue
    result.append(line)
open(skill_md, 'w').writelines(result)
"
}

# If starting with an override, apply it to SKILL.md immediately
if [[ -n "$DESCRIPTION_OVERRIDE" ]]; then
  replace_description "$SKILL_PATH/SKILL.md" "$work_dir/current_desc.txt"
fi

# --- run-eval.sh wrapper ---
run_eval() {
  local queries_file="$1"
  "$SCRIPT_DIR/run-eval.sh" \
    --queries "$queries_file" \
    --skill "$skill_name" \
    --reps "$RUNS_PER_QUERY" \
    --workers "$NUM_WORKERS" \
    --timeout "$TIMEOUT" \
    --threshold "$TRIGGER_THRESHOLD" \
    2>/dev/null
}

# --- Stratified split ---
# WHY python3: jq lacks random seed support for deterministic shuffle.
# Matches run_loop.py's seed=42 stratified split exactly. (DA NGMI #3)
if [[ "$HOLDOUT" != "0" ]]; then
  QUERIES_FILE="$EVAL_SET" HOLDOUT_VAL="$HOLDOUT" SEED="$SPLIT_SEED" \
    TRAIN_FILE="$work_dir/train.json" TEST_FILE="$work_dir/test.json" \
    python3 -c "
import json, random, os
random.seed(int(os.environ['SEED']))
queries = json.load(open(os.environ['QUERIES_FILE']))
holdout = float(os.environ['HOLDOUT_VAL'])
trigger = [q for q in queries if q['should_trigger']]
no_trigger = [q for q in queries if not q['should_trigger']]
random.shuffle(trigger)
random.shuffle(no_trigger)
n_t = min(max(1, int(len(trigger) * holdout)), max(0, len(trigger) - 1)) if trigger else 0
n_n = min(max(1, int(len(no_trigger) * holdout)), max(0, len(no_trigger) - 1)) if no_trigger else 0
test = trigger[:n_t] + no_trigger[:n_n]
train = trigger[n_t:] + no_trigger[n_n:]
if not train:
    raise SystemExit('Error: holdout split produced no training queries; lower --holdout or use --holdout 0')
json.dump(train, open(os.environ['TRAIN_FILE'], 'w'), ensure_ascii=False, indent=2)
json.dump(test, open(os.environ['TEST_FILE'], 'w'), ensure_ascii=False, indent=2)
print(f'Split: {len(train)} train, {len(test)} test (holdout={holdout})', end='')
" >&2
  echo "" >&2
  train_file="$work_dir/train.json"
  test_file="$work_dir/test.json"
else
  train_file="$EVAL_SET"
  test_file=""
  log "No holdout: using all queries for training"
fi

train_size=$(jq length "$train_file")
test_size=0
if [[ -n "$test_file" ]]; then
  test_size=$(jq length "$test_file")
fi

log "Optimization loop: $skill_name ($MAX_ITERATIONS max iterations, runs-per-query=$RUNS_PER_QUERY)"
log ""

# --- Setup report (live) ---
report_path=""
if [[ "$REPORT" != "none" ]]; then
  if [[ "$REPORT" == "auto" ]]; then
    timestamp_r=$(date +%Y%m%d_%H%M%S)
    # Auto report goes to evals/ (not work_dir, which is deleted by cleanup)
    mkdir -p "$SKILL_PATH/evals"
    report_path="$SKILL_PATH/evals/skill_report_${skill_name}_${timestamp_r}.html"
  else
    report_path="$REPORT"
  fi
  mkdir -p "$(dirname "$report_path")"
  echo "<html><body><h1>Starting optimization loop...</h1><meta http-equiv='refresh' content='5'></body></html>" > "$report_path"
  if [[ "$REPORT" == "auto" ]]; then
    if command -v open &>/dev/null; then open "$report_path"
    elif command -v xdg-open &>/dev/null; then xdg-open "$report_path"
    fi 2>/dev/null || true
  fi
fi

# --- Initialize tracking ---
best_test_passed=-1
best_iteration=0
best_train_fallback=-1
iterations_completed=0

# --- Main loop ---
for ((iteration = 1; iteration <= MAX_ITERATIONS; iteration++)); do
  log "=== Iteration $iteration/$MAX_ITERATIONS ==="

  # A. Train eval
  log "  Training eval..."
  train_results=$(run_eval "$train_file") || {
    log "  Error: run-eval.sh failed for train set"
    continue
  }

  train_passed=$(printf '%s' "$train_results" | jq '.summary.passed')
  train_total=$(printf '%s' "$train_results" | jq '.summary.total')
  train_failed=$(printf '%s' "$train_results" | jq '.summary.failed')
  log "  Train: $train_passed/$train_total passed"

  # Inject current description into eval results for improve-description.sh
  # Also serves as the per-iteration record for report history
  current_description=$(cat "$work_dir/current_desc.txt")
  printf '%s' "$train_results" | \
    jq --arg desc "$current_description" '. + {description: $desc}' \
    > "$work_dir/eval-results.json"

  # Save description-enriched results for report history
  cp "$work_dir/eval-results.json" "$work_dir/iter-${iteration}-train.json"

  # B. Test eval (holdout only) — same description X as train
  # WHY test-before-improve: train and test must use the same description so that
  # each iteration's results are self-consistent. Matches run_loop.py's approach
  # of evaluating all queries (train+test) in a single call before improving.
  test_passed=0
  test_total=0
  if [[ -n "$test_file" ]]; then
    log "  Test eval..."
    # WHY || true: test eval failure should not block the iteration — improve
    # still uses train results only. Skipping improve on test failure would stall
    # the loop on the same description. (Codex review R1 regression fix)
    test_results=$(run_eval "$test_file") || true
    if [[ -n "$test_results" ]] && printf '%s' "$test_results" | jq -e '.summary' >/dev/null 2>&1; then
      printf '%s' "$test_results" > "$work_dir/iter-${iteration}-test.json"
      test_passed=$(printf '%s' "$test_results" | jq '.summary.passed')
      test_total=$(printf '%s' "$test_results" | jq '.summary.total')
      log "  Test: $test_passed/$test_total passed"

      # WHY test-based selection: train score would select descriptions overfit to
      # training queries. Test set is unseen by the improvement model, serving as
      # a generalization proxy.
      if (( test_passed > best_test_passed )); then
        best_test_passed=$test_passed
        best_iteration=$iteration
        cp "$work_dir/current_desc.txt" "$work_dir/best_desc.txt"
        log "  New best! (test=$test_passed/$test_total)"
      fi
    else
      log "  Warning: test eval failed, skipping holdout scoring"
      # WHY best_test_passed < 0 guard: if any test eval succeeded (best_test_passed >= 0),
      # the test-based best is authoritative — train fallback must not override it.
      # Without this guard, a mixed scenario (some tests pass, some fail) could replace
      # the test-based best with a train-based one, causing best_description/best_test_score mismatch.
      if (( best_test_passed < 0 && train_passed > best_train_fallback )); then
        best_train_fallback=$train_passed
        best_iteration=$iteration
        cp "$work_dir/current_desc.txt" "$work_dir/best_desc.txt"
      fi
    fi
  else
    if (( train_passed > best_test_passed )); then
      best_test_passed=$train_passed
      best_iteration=$iteration
      cp "$work_dir/current_desc.txt" "$work_dir/best_desc.txt"
    fi
  fi

  # Mark iteration eval as complete (train+test results recorded).
  # Written before improve so that improve failure does not orphan best_iteration.
  # (Codex review R1 bookkeeping fix)
  touch "$work_dir/iter-${iteration}-complete"
  iterations_completed=$iteration

  # C. Early exit if all train pass
  if [[ "$train_failed" == "0" ]]; then
    log "  All train queries passed! Early exit."
    exit_reason="all_passed (iteration $iteration)"
    break
  fi

  # D. Improve description
  log "  Improving description..."

  improve_args=(
    --skill-path "$SKILL_PATH"
    --eval-results "$work_dir/eval-results.json"
  )
  if [[ -f "$work_dir/improve_history.json" ]]; then
    improve_args+=(--history "$work_dir/improve_history.json")
  fi

  improve_output=$("$SCRIPT_DIR/improve-description.sh" "${improve_args[@]}" 2>/dev/null) || {
    log "  Error: improve-description.sh failed"
    continue
  }

  # E. Extract + apply new description
  printf '%s' "$improve_output" | jq -r '.description' > "$work_dir/new_desc.txt"
  new_desc_len=$(wc -c < "$work_dir/new_desc.txt" | tr -d ' ')
  log "  New description: ${new_desc_len} chars"

  cp "$work_dir/new_desc.txt" "$work_dir/current_desc.txt"
  replace_description "$SKILL_PATH/SKILL.md" "$work_dir/current_desc.txt"

  # F. Update improve-description.sh history
  printf '%s' "$improve_output" | jq '.history' > "$work_dir/improve_history.json"

  # G. Update live report (if enabled)
  if [[ -n "$report_path" && -f "$report_path" ]]; then
    # Build partial results for in-progress report
    partial_json=$(WORK_DIR="$work_dir" ITERS="$iteration" \
      ORIG_FILE="$work_dir/original_desc.txt" BEST_FILE="$work_dir/best_desc.txt" \
      python3 -c "
import json, os
from pathlib import Path
work = os.environ['WORK_DIR']
iters = int(os.environ['ITERS'])
orig = open(os.environ['ORIG_FILE']).read().strip()
best = open(os.environ['BEST_FILE']).read().strip()
history = []
for i in range(1, iters + 1):
    tf = Path(work) / f'iter-{i}-train.json'
    xf = Path(work) / f'iter-{i}-test.json'
    cf = Path(work) / f'iter-{i}-complete'
    if not tf.exists() or not cf.exists(): continue
    td = json.loads(tf.read_text())
    ts = td.get('summary', {})
    xs, xr = {}, []
    if xf.exists() and xf.stat().st_size > 0:
        try:
            xd = json.loads(xf.read_text())
            xs, xr = xd.get('summary', {}), xd.get('results', [])
        except: pass
    history.append({
        'iteration': i, 'description': td.get('description', ''),
        'train_passed': ts.get('passed', 0), 'train_failed': ts.get('failed', 0),
        'train_total': ts.get('total', 0), 'train_results': td.get('results', []),
        'test_passed': xs.get('passed'), 'test_total': xs.get('total'),
        'test_results': xr if xr else None,
        'passed': ts.get('passed', 0), 'total': ts.get('total', 0), 'results': td.get('results', []),
    })
print(json.dumps({'original_description': orig, 'best_description': best,
    'best_score': 'in progress', 'iterations_run': len(history), 'history': history}, ensure_ascii=False))
" 2>/dev/null) || true
    if [[ -n "$partial_json" ]]; then
      printf '%s' "$partial_json" | python3 "$SCRIPT_DIR/generate-report.py" - \
        -o "$report_path" --skill-name "$skill_name" --live 2>/dev/null || true
    fi
  fi

  log ""
done

# Default exit_reason
exit_reason="${exit_reason:-max_iterations ($MAX_ITERATIONS)}"

if (( iterations_completed == 0 )); then
  echo "Error: no iteration completed successfully" >&2
  exit 1
fi

# Guard: if holdout was requested but no valid test score obtained,
# mark as unavailable so serializer uses train score instead
TEST_SCORE_AVAILABLE=true
if [[ -n "$test_file" && $best_test_passed -lt 0 ]]; then
  log "Warning: no valid holdout score obtained — best_score based on train only"
  TEST_SCORE_AVAILABLE=false
  best_test_passed=0
fi

log "=== Loop complete ==="

# --- Finalize ---
if [[ "$APPLY" == "true" ]]; then
  replace_description "$SKILL_PATH/SKILL.md" "$work_dir/best_desc.txt"
  FINALIZED=true
  log "Applied best description to SKILL.md (iteration $best_iteration)"
else
  cp "$work_dir/original-skill.md" "$SKILL_PATH/SKILL.md"
  FINALIZED=true
  log "Restored original SKILL.md (use --apply to keep best)"
fi

# --- Build results JSON (with per-query results for report) ---
results_json=$(WORK_DIR="$work_dir" EXIT_REASON="$exit_reason" \
  BEST_ITER="$best_iteration" BEST_TEST_PASSED="$best_test_passed" \
  TEST_SCORE_AVAILABLE="$TEST_SCORE_AVAILABLE" \
  ITERS_COMPLETED="$iterations_completed" \
  ORIG_FILE="$work_dir/original_desc.txt" BEST_FILE="$work_dir/best_desc.txt" \
  HOLDOUT_VAL="$HOLDOUT" TRAIN_SZ="$train_size" TEST_SZ="$test_size" \
  python3 -c "
import json, os, sys
from pathlib import Path

work = os.environ['WORK_DIR']
orig = open(os.environ['ORIG_FILE']).read().strip()
best = open(os.environ['BEST_FILE']).read().strip()
best_iter = int(os.environ['BEST_ITER'])
iters = int(os.environ['ITERS_COMPLETED'])
test_sz = int(os.environ['TEST_SZ'])

history = []
for i in range(1, iters + 1):
    train_f = Path(work) / f'iter-{i}-train.json'
    test_f = Path(work) / f'iter-{i}-test.json'

    complete_f = Path(work) / f'iter-{i}-complete'
    if not train_f.exists() or not complete_f.exists():
        continue  # skip partial iterations (improve/test failed mid-iteration)

    train_data = json.loads(train_f.read_text())
    train_results = train_data.get('results', [])
    train_summary = train_data.get('summary', {})

    test_results = []
    test_summary = {}
    if test_f.exists() and test_f.stat().st_size > 0:
        try:
            test_data = json.loads(test_f.read_text())
            test_results = test_data.get('results', [])
            test_summary = test_data.get('summary', {})
        except json.JSONDecodeError:
            pass  # test eval failed — empty/corrupt file

    desc = train_data.get('description', '')

    entry = {
        'iteration': i,
        'description': desc,  # same description used for both train and test
        'train_passed': train_summary.get('passed', 0),
        'train_failed': train_summary.get('failed', 0),
        'train_total': train_summary.get('total', 0),
        'train_results': train_results,
        'test_passed': test_summary.get('passed'),
        'test_failed': test_summary.get('failed'),
        'test_total': test_summary.get('total'),
        'test_results': test_results if test_results else None,
        # backward compat
        'passed': train_summary.get('passed', 0),
        'failed': train_summary.get('failed', 0),
        'total': train_summary.get('total', 0),
        'results': train_results,
    }
    history.append(entry)

# best_score uses shell-computed values (not reconstructed from files)
best_test_passed = int(os.environ['BEST_TEST_PASSED'])
test_score_available = os.environ.get('TEST_SCORE_AVAILABLE', 'true') == 'true'
best_entry = next((h for h in history if h['iteration'] == best_iter), {})
best_train = f\"{best_entry.get('train_passed', '?')}/{best_entry.get('train_total', '?')}\"
best_test_total = best_entry.get('test_total', test_sz) or test_sz
best_test_str = f\"{best_test_passed}/{best_test_total}\" if test_score_available and test_sz > 0 else None

# Use train score when holdout eval never succeeded
use_test = test_score_available and test_sz > 0

output = {
    'exit_reason': os.environ['EXIT_REASON'],
    'original_description': orig,
    'best_description': best,
    'best_score': best_test_str if use_test else best_train,
    'best_train_score': best_train,
    'best_test_score': best_test_str,
    'best_iteration': best_iter,
    'iterations_run': len(history),
    'holdout': float(os.environ['HOLDOUT_VAL']),
    'train_size': int(os.environ['TRAIN_SZ']),
    'test_size': test_sz,
    'history': history,
}
print(json.dumps(output, indent=2, ensure_ascii=False))
")

# Output to stdout
printf '%s\n' "$results_json"

# --- Save results ---
if [[ -n "$RESULTS_DIR" ]]; then
  timestamp=$(date +%Y-%m-%d_%H%M%S)
  out_dir="$RESULTS_DIR/$timestamp"
  mkdir -p "$out_dir"
  printf '%s\n' "$results_json" > "$out_dir/results.json"
  log "Results saved to: $out_dir/results.json"

else
  # Default: save to evals directory
  timestamp=$(date +%Y%m%d-%H%M%S)
  results_file="$SKILL_PATH/evals/loop-results-${timestamp}.json"
  mkdir -p "$SKILL_PATH/evals"
  printf '%s\n' "$results_json" > "$results_file"
  log "Results saved to: $results_file"
fi

# --- Generate final report ---
if [[ -n "$report_path" ]]; then
  printf '%s' "$results_json" | python3 "$SCRIPT_DIR/generate-report.py" - \
    -o "$report_path" --skill-name "$skill_name" 2>/dev/null || true
  log "Report: $report_path"
  # Also copy to results-dir if provided
  if [[ -n "$RESULTS_DIR" && -d "$out_dir" ]]; then
    cp "$report_path" "$out_dir/report.html" 2>/dev/null || true
  fi
fi

log ""
log "Exit reason: $exit_reason"
log "Best: iteration $best_iteration"
