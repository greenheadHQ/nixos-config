#!/usr/bin/env bash
# improve-description.sh — Description improvement via claude -p
#
# Drop-in replacement for skill-creator's improve_description.py.
# Uses claude -p instead of Anthropic Python SDK, eliminating the
# ANTHROPIC_API_KEY requirement.
#
# Usage:
#   improve-description.sh --skill-path <dir> --eval-results <json> [--history <json>]
#
# Output: JSON to stdout with { description, history }

set -euo pipefail

# --- Defaults ---
SKILL_PATH=""
EVAL_RESULTS=""
HISTORY=""

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skill-path)    SKILL_PATH="$2";    shift 2 ;;
    --eval-results)  EVAL_RESULTS="$2";  shift 2 ;;
    --history)       HISTORY="$2";       shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# --- Validate ---
if [[ -z "$SKILL_PATH" || -z "$EVAL_RESULTS" ]]; then
  echo "Error: --skill-path and --eval-results are required" >&2
  exit 1
fi

if [[ ! -f "$SKILL_PATH/SKILL.md" ]]; then
  echo "Error: No SKILL.md found at $SKILL_PATH" >&2
  exit 1
fi

# --- Extract skill metadata ---
# Use env vars for path passing to avoid shell injection in inline Python
skill_name=$(SKILL_FILE="$SKILL_PATH/SKILL.md" python3 -c "
import re, os
content = open(os.environ['SKILL_FILE']).read()
m = re.search(r'^name:\s*(.+)', content, re.MULTILINE)
print(m.group(1).strip().strip('\"').strip(\"'\") if m else 'unknown')
")

skill_content=$(cat "$SKILL_PATH/SKILL.md")

current_description=$(jq -r '.description' "$EVAL_RESULTS")

# --- Build scores summary ---
scores_summary=$(python3 -c "
import json
er = json.load(open('$EVAL_RESULTS'))
s = er['summary']
train = f\"{s['passed']}/{s['total']}\"
print(f'Train: {train}')
")

# --- Build failure analysis ---
failure_analysis=$(python3 -c "
import json
er = json.load(open('$EVAL_RESULTS'))
lines = []

failed = [r for r in er['results'] if r['should_trigger'] and not r['pass']]
false_t = [r for r in er['results'] if not r['should_trigger'] and not r['pass']]

if failed:
    lines.append('FAILED TO TRIGGER (should have triggered but didn\'t):')
    for r in failed:
        tc = r.get('trigger_count', 0)
        tr = r.get('total_runs', 1)
        lines.append(f'  - \"{r[\"query\"]}\" (triggered {tc}/{tr} times)')
    lines.append('')

if false_t:
    lines.append('FALSE TRIGGERS (triggered but shouldn\'t have):')
    for r in false_t:
        tc = r.get('trigger_count', 0)
        tr = r.get('total_runs', 1)
        lines.append(f'  - \"{r[\"query\"]}\" (triggered {tc}/{tr} times)')
    lines.append('')

print('\n'.join(lines))
")

# --- Build history section ---
history_section=""
if [[ -n "$HISTORY" && -f "$HISTORY" ]]; then
  history_section=$(python3 -c "
import json
history = json.load(open('$HISTORY'))
lines = []
if history:
    lines.append('PREVIOUS ATTEMPTS (do NOT repeat these — try something structurally different):\n')
    for h in history:
        tp = h.get('train_passed', h.get('passed', 0))
        tt = h.get('train_total', h.get('total', 0))
        score_str = f'train={tp}/{tt}'
        lines.append(f'<attempt {score_str}>')
        lines.append(f'Description: \"{h[\"description\"]}\"')
        if 'results' in h:
            lines.append('Train results:')
            for r in h['results']:
                status = 'PASS' if r['pass'] else 'FAIL'
                tc = r.get('trigger_count', r.get('triggers', 0))
                tr = r.get('total_runs', r.get('runs', 1))
                lines.append(f'  [{status}] \"{r[\"query\"][:80]}\" (triggered {tc}/{tr})')
        if h.get('note'):
            lines.append(f'Note: {h[\"note\"]}')
        lines.append('</attempt>\n')
print('\n'.join(lines))
")
fi

# --- Construct prompt (mirrors improve_description.py exactly) ---
prompt=$(cat <<PROMPT_EOF
You are optimizing a skill description for a Claude Code skill called "${skill_name}". A "skill" is sort of like a prompt, but with progressive disclosure -- there's a title and description that Claude sees when deciding whether to use the skill, and then if it does use the skill, it reads the .md file which has lots more details and potentially links to other resources in the skill folder like helper files and scripts and additional documentation or examples.

The description appears in Claude's "available_skills" list. When a user sends a query, Claude decides whether to invoke the skill based solely on the title and on this description. Your goal is to write a description that triggers for relevant queries, and doesn't trigger for irrelevant ones.

Here's the current description:
<current_description>
"${current_description}"
</current_description>

Current scores (${scores_summary}):
<scores_summary>
${failure_analysis}
${history_section}
</scores_summary>

Skill content (for context on what the skill does):
<skill_content>
${skill_content}
</skill_content>

Based on the failures, write a new and improved description that is more likely to trigger correctly. When I say "based on the failures", it's a bit of a tricky line to walk because we don't want to overfit to the specific cases you're seeing. So what I DON'T want you to do is produce an ever-expanding list of specific queries that this skill should or shouldn't trigger for. Instead, try to generalize from the failures to broader categories of user intent and situations where this skill would be useful or not useful. The reason for this is twofold:

1. Avoid overfitting
2. The list might get loooong and it's injected into ALL queries and there might be a lot of skills, so we don't want to blow too much space on any given description.

Concretely, your description should not be more than about 100-200 words, even if that comes at the cost of accuracy.

Here are some tips that we've found to work well in writing these descriptions:
- The skill should be phrased in the imperative -- "Use this skill for" rather than "this skill does"
- The skill description should focus on the user's intent, what they are trying to achieve, vs. the implementation details of how the skill works.
- The description competes with other skills for Claude's attention — make it distinctive and immediately recognizable.
- If you're getting lots of failures after repeated attempts, change things up. Try different sentence structures or wordings.

I'd encourage you to be creative and mix up the style in different iterations since you'll have multiple opportunities to try different approaches and we'll just grab the highest-scoring one at the end.

Please respond with only the new description text in <new_description> tags, nothing else.
PROMPT_EOF
)

# --- Call claude -p ---
echo "Improving description for: $skill_name" >&2

# SKILL_EVAL_MODE=1: PreToolUse hooks skip logging (#283)
raw_output=$(env -u CLAUDECODE -u ANTHROPIC_API_KEY SKILL_EVAL_MODE=1 \
  claude -p "$prompt" \
    --output-format json \
    --max-turns 1 \
    --no-session-persistence \
  2>/dev/null) || { echo "Error: claude -p failed" >&2; exit 1; }

# --- Parse response ---
new_description=$(echo "$raw_output" | jq -r '
  [.[] | select(.type == "result") | .result] | first // ""
' | python3 -c "
import sys, re
text = sys.stdin.read()
m = re.search(r'<new_description>(.*?)</new_description>', text, re.DOTALL)
if m:
    print(m.group(1).strip().strip('\"'))
else:
    # Fallback: try to extract from the raw text
    print(text.strip().strip('\"')[:1024])
")

char_count=${#new_description}
echo "Generated description: ${char_count} chars" >&2

# --- Handle >1024 char limit ---
if (( char_count > 1024 )); then
  echo "Description exceeds 1024 chars (${char_count}), requesting shortening..." >&2

  shorten_prompt="Your description is ${char_count} characters, which exceeds the hard 1024 character limit. Please rewrite it to be under 1024 characters while preserving the most important trigger words and intent coverage. Respond with only the new description in <new_description> tags."

  # Combine original prompt + response + shorten request
  combined_prompt="${prompt}

---
Previous response: ${new_description}
---
${shorten_prompt}"

  # SKILL_EVAL_MODE=1: PreToolUse hooks skip logging (#283)
  shorten_output=$(env -u CLAUDECODE -u ANTHROPIC_API_KEY SKILL_EVAL_MODE=1 \
    claude -p "$combined_prompt" \
      --output-format json \
      --max-turns 1 \
      --no-session-persistence \
    2>/dev/null) || true

  shortened=$(echo "$shorten_output" | jq -r '
    [.[] | select(.type == "result") | .result] | first // ""
  ' | python3 -c "
import sys, re
text = sys.stdin.read()
m = re.search(r'<new_description>(.*?)</new_description>', text, re.DOTALL)
print(m.group(1).strip().strip('\"') if m else text.strip()[:1024])
")

  if [[ -n "$shortened" ]]; then
    new_description="$shortened"
    echo "Shortened to: ${#new_description} chars" >&2
  else
    echo "Shortening failed, keeping original (${#new_description} chars, may exceed 1024)" >&2
  fi
fi

# --- Build output JSON ---
# Write description to temp file to avoid bash variable expansion issues
# (newlines, quotes, control characters in description break inline Python)
desc_tmpfile=$(mktemp)
printf '%s' "$new_description" > "$desc_tmpfile"

python3 -c "
import json, sys

description = open('$desc_tmpfile').read()
eval_results = json.load(open('$EVAL_RESULTS'))
history_file = '${HISTORY}'
history = json.load(open(history_file)) if history_file and history_file != '' else []

# Append current to history
history.append({
    'description': eval_results.get('description', ''),
    'passed': eval_results['summary']['passed'],
    'failed': eval_results['summary']['failed'],
    'total': eval_results['summary']['total'],
    'results': eval_results['results'],
})

output = {
    'description': description,
    'history': history,
}

print(json.dumps(output, indent=2, ensure_ascii=False))
"

rm -f "$desc_tmpfile"
