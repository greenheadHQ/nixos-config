#!/usr/bin/env bash
# run-loop.sh — Description optimization loop via claude -p
#
# Orchestrates trigger-eval.sh and improve-description.sh in an iterative
# loop to find the best skill description. Uses train/test split to prevent
# overfitting. Drop-in replacement for skill-creator's run_loop.py,
# eliminating the ANTHROPIC_API_KEY requirement.
#
# Usage:
#   run-loop.sh --skill-path <dir> --queries <json>
#               [--max-iterations 5] [--reps 3] [--holdout 0.4] [--apply]
#
# Output: JSON results to stdout + <skill-path>/evals/loop-results-<timestamp>.json
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
QUERIES=""
MAX_ITERATIONS=5
REPS=3
HOLDOUT="0.4"
APPLY=false
FINALIZED=false

# --- Locate sibling scripts ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skill-path)      SKILL_PATH="$2";      shift 2 ;;
    --queries)         QUERIES="$2";         shift 2 ;;
    --max-iterations)  MAX_ITERATIONS="$2";  shift 2 ;;
    --reps)            REPS="$2";            shift 2 ;;
    --holdout)         HOLDOUT="$2";         shift 2 ;;
    --apply)           APPLY=true;           shift ;;
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

if [[ -z "$QUERIES" ]]; then
  echo "Error: --queries <json> is required" >&2
  exit 1
fi

if [[ ! -f "$SKILL_PATH/SKILL.md" ]]; then
  echo "Error: No SKILL.md found at $SKILL_PATH" >&2
  exit 1
fi

if [[ ! -f "$QUERIES" ]]; then
  echo "Error: queries file not found: $QUERIES" >&2
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
# history.json: appended each iteration
# best_desc.txt: overwritten when best is updated
# current_desc.txt: overwritten each iteration
# original-skill.md: created once, used for restoration
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
current_description="$original_description"

# Save original and initial best description to temp files
printf '%s' "$original_description" > "$work_dir/original_desc.txt"
printf '%s' "$original_description" > "$work_dir/best_desc.txt"
printf '%s' "$original_description" > "$work_dir/current_desc.txt"

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

# --- Stratified split ---
# WHY python3: jq lacks random seed support for deterministic shuffle.
# Matches run_loop.py's seed=42 stratified split exactly. (DA NGMI #3)
if [[ "$HOLDOUT" != "0" ]]; then
  QUERIES_FILE="$QUERIES" HOLDOUT_VAL="$HOLDOUT" SEED="$SPLIT_SEED" \
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
  # No split: use all queries for training, skip test
  train_file="$QUERIES"
  test_file=""
  echo "No holdout: using all queries for training" >&2
fi

train_size=$(jq length "$train_file")
test_size=0
if [[ -n "$test_file" ]]; then
  test_size=$(jq length "$test_file")
fi

echo "Optimization loop: $skill_name ($MAX_ITERATIONS max iterations, reps=$REPS)" >&2
echo "" >&2

# --- Initialize tracking ---
best_test_passed=-1
best_iteration=0
history_json="[]"

# --- Main loop ---
for ((iteration = 1; iteration <= MAX_ITERATIONS; iteration++)); do
  echo "=== Iteration $iteration/$MAX_ITERATIONS ===" >&2

  # A. Train eval
  echo "  Training eval..." >&2
  train_results=$("$SCRIPT_DIR/trigger-eval.sh" \
    --queries "$train_file" --skill "$skill_name" --reps "$REPS" 2>/dev/null) || {
    echo "  Error: trigger-eval.sh failed for train set" >&2
    continue
  }

  train_passed=$(printf '%s' "$train_results" | jq '.summary.passed')
  train_total=$(printf '%s' "$train_results" | jq '.summary.total')
  train_failed=$(printf '%s' "$train_results" | jq '.summary.failed')
  echo "  Train: $train_passed/$train_total passed" >&2

  # Inject current description into eval results for improve-description.sh
  current_description=$(cat "$work_dir/current_desc.txt")
  printf '%s' "$train_results" | \
    jq --arg desc "$current_description" '. + {description: $desc}' \
    > "$work_dir/eval-results.json"

  # B. Early exit if all train pass
  if [[ "$train_failed" == "0" ]]; then
    echo "  All train queries passed! Early exit." >&2

    # Still run test eval for the final score
    if [[ -n "$test_file" ]]; then
      echo "  Final test eval..." >&2
      test_results=$("$SCRIPT_DIR/trigger-eval.sh" \
        --queries "$test_file" --skill "$skill_name" --reps "$REPS" 2>/dev/null) || true
      test_passed=$(printf '%s' "$test_results" | jq '.summary.passed // 0')
      test_total=$(printf '%s' "$test_results" | jq '.summary.total // 0')
      echo "  Test: $test_passed/$test_total passed" >&2

      if (( test_passed > best_test_passed )); then
        best_test_passed=$test_passed
        best_iteration=$iteration
        cp "$work_dir/current_desc.txt" "$work_dir/best_desc.txt"
      fi
    else
      best_iteration=$iteration
      cp "$work_dir/current_desc.txt" "$work_dir/best_desc.txt"
    fi

    # Record in history
    history_json=$(printf '%s' "$history_json" | \
      ITER="$iteration" DESC_FILE="$work_dir/current_desc.txt" \
      TRAIN_P="$train_passed" TRAIN_F="$train_failed" TRAIN_T="$train_total" \
      TEST_P="${test_passed:-}" TEST_T="${test_total:-}" \
      python3 -c "
import json, os, sys
h = json.loads(sys.stdin.read())
desc = open(os.environ['DESC_FILE']).read().strip()
entry = {
    'iteration': int(os.environ['ITER']),
    'description': desc,
    'train_passed': int(os.environ['TRAIN_P']),
    'train_failed': int(os.environ['TRAIN_F']),
    'train_total': int(os.environ['TRAIN_T']),
}
tp = os.environ.get('TEST_P', '')
tt = os.environ.get('TEST_T', '')
if tp and tt:
    entry['test_passed'] = int(tp)
    entry['test_total'] = int(tt)
h.append(entry)
print(json.dumps(h, ensure_ascii=False))
")

    exit_reason="all_passed (iteration $iteration)"
    break
  fi

  # C. Improve description
  echo "  Improving description..." >&2

  # improve-description.sh에 전달할 history는 자체 출력에서 누적됨
  # (history.json은 line 388에서 improve_output.history로 관리)
  improve_args=(
    --skill-path "$SKILL_PATH"
    --eval-results "$work_dir/eval-results.json"
  )
  if [[ -f "$work_dir/improve_history.json" ]]; then
    improve_args+=(--history "$work_dir/improve_history.json")
  fi

  improve_output=$("$SCRIPT_DIR/improve-description.sh" "${improve_args[@]}" 2>/dev/null) || {
    echo "  Error: improve-description.sh failed" >&2
    continue
  }

  # D. Extract new description → temp file
  printf '%s' "$improve_output" | jq -r '.description' > "$work_dir/new_desc.txt"
  new_desc_len=$(wc -c < "$work_dir/new_desc.txt" | tr -d ' ')
  echo "  New description: ${new_desc_len} chars" >&2

  # Update current description
  cp "$work_dir/new_desc.txt" "$work_dir/current_desc.txt"

  # E. Replace SKILL.md description (in-place)
  replace_description "$SKILL_PATH/SKILL.md" "$work_dir/current_desc.txt"

  # F. Test eval
  test_passed=0
  test_total=0
  if [[ -n "$test_file" ]]; then
    echo "  Test eval..." >&2
    test_results=$("$SCRIPT_DIR/trigger-eval.sh" \
      --queries "$test_file" --skill "$skill_name" --reps "$REPS" 2>/dev/null) || {
      echo "  Error: trigger-eval.sh failed for test set" >&2
      continue
    }

    test_passed=$(printf '%s' "$test_results" | jq '.summary.passed')
    test_total=$(printf '%s' "$test_results" | jq '.summary.total')
    echo "  Test: $test_passed/$test_total passed" >&2

    # G. Track best by TEST score
    # WHY test-first: train score would select descriptions overfit to training
    # queries. Test set is unseen by the improvement model, serving as a
    # generalization proxy. (DA READABILITY #4)
    if (( test_passed > best_test_passed )); then
      best_test_passed=$test_passed
      best_iteration=$iteration
      cp "$work_dir/current_desc.txt" "$work_dir/best_desc.txt"
      echo "  New best! (test=$test_passed/$test_total)" >&2
    fi
  else
    # No test set: track by train score
    if (( train_passed > best_test_passed )); then
      best_test_passed=$train_passed
      best_iteration=$iteration
      cp "$work_dir/current_desc.txt" "$work_dir/best_desc.txt"
    fi
  fi

  # H. Record in history
  history_json=$(printf '%s' "$history_json" | \
    ITER="$iteration" DESC_FILE="$work_dir/current_desc.txt" \
    TRAIN_P="$train_passed" TRAIN_F="$train_failed" TRAIN_T="$train_total" \
    TEST_P="$test_passed" TEST_T="$test_total" \
    python3 -c "
import json, os, sys
h = json.loads(sys.stdin.read())
desc = open(os.environ['DESC_FILE']).read().strip()
entry = {
    'iteration': int(os.environ['ITER']),
    'description': desc,
    'train_passed': int(os.environ['TRAIN_P']),
    'train_failed': int(os.environ['TRAIN_F']),
    'train_total': int(os.environ['TRAIN_T']),
    'test_passed': int(os.environ['TEST_P']),
    'test_total': int(os.environ['TEST_T']),
}
h.append(entry)
print(json.dumps(h, ensure_ascii=False))
")

  # Update improve-description.sh history from its output
  # (accumulates past descriptions with scores for the next iteration)
  printf '%s' "$improve_output" | jq '.history' > "$work_dir/improve_history.json"

  echo "" >&2
done

# Default exit_reason if loop ran to completion without setting it
exit_reason="${exit_reason:-max_iterations ($MAX_ITERATIONS)}"

if [[ "$history_json" == "[]" ]]; then
  echo "Error: no iteration completed successfully" >&2
  exit 1
fi

echo "=== Loop complete ===" >&2

# --- Finalize ---
if [[ "$APPLY" == "true" ]]; then
  replace_description "$SKILL_PATH/SKILL.md" "$work_dir/best_desc.txt"
  FINALIZED=true
  echo "Applied best description to SKILL.md (iteration $best_iteration)" >&2
else
  cp "$work_dir/original-skill.md" "$SKILL_PATH/SKILL.md"
  FINALIZED=true
  echo "Restored original SKILL.md (use --apply to keep best)" >&2
fi

# --- Build results JSON ---
results_json=$(EXIT_REASON="$exit_reason" BEST_ITER="$best_iteration" \
  ORIG_FILE="$work_dir/original_desc.txt" BEST_FILE="$work_dir/best_desc.txt" \
  HOLDOUT_VAL="$HOLDOUT" TRAIN_SZ="$train_size" TEST_SZ="$test_size" \
  python3 -c "
import json, os, sys
history = json.loads(sys.stdin.read())
orig = open(os.environ['ORIG_FILE']).read().strip()
best = open(os.environ['BEST_FILE']).read().strip()
best_iter = int(os.environ['BEST_ITER'])

# Find best iteration's scores
best_entry = next((h for h in history if h['iteration'] == best_iter), {})
best_train = f\"{best_entry.get('train_passed', '?')}/{best_entry.get('train_total', '?')}\"
best_test = f\"{best_entry.get('test_passed', '?')}/{best_entry.get('test_total', '?')}\"

output = {
    'exit_reason': os.environ['EXIT_REASON'],
    'original_description': orig,
    'best_description': best,
    'best_score': best_test if int(os.environ['TEST_SZ']) > 0 else best_train,
    'best_train_score': best_train,
    'best_test_score': best_test if int(os.environ['TEST_SZ']) > 0 else None,
    'best_iteration': best_iter,
    'iterations_run': len(history),
    'holdout': float(os.environ['HOLDOUT_VAL']),
    'train_size': int(os.environ['TRAIN_SZ']),
    'test_size': int(os.environ['TEST_SZ']),
    'history': history,
}
print(json.dumps(output, indent=2, ensure_ascii=False))
" <<< "$history_json")

# Output to stdout
printf '%s\n' "$results_json"

# Save to evals directory
timestamp=$(date +%Y%m%d-%H%M%S)
results_file="$SKILL_PATH/evals/loop-results-${timestamp}.json"
mkdir -p "$SKILL_PATH/evals"
printf '%s\n' "$results_json" > "$results_file"
echo "Results saved to: $results_file" >&2

echo "" >&2
echo "Exit reason: $exit_reason" >&2
echo "Best: iteration $best_iteration" >&2
