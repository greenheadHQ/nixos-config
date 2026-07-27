# tests/suites/delegation-alert.sh — 도메인 테스트 정의 (sourced; aggregator가 lib/test-common.sh 후 source)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# shellcheck disable=SC2154,SC2164

# delegation-alert.sh PreToolUse hook에 JSON stdin을 흘려, 메인 에이전트의 턴별 직접 편집
# 경고 임계와 세션/프롬프트 격리를 검증한다. 상태는 CLAUDE_DELEGATION_STATE_DIR를
# new_sandbox 아래로 지정해 실제 $HOME을 건드리지 않는다.

_delegation_alert_raw() {
  local state_dir="$1" input="$2"
  printf '%s' "$input" | \
    env HOOK_RUNTIME_LIB="$REPO_ROOT/modules/shared/programs/claude/files/lib/hook-runtime.sh" \
      CLAUDE_DELEGATION_STATE_DIR="$state_dir" \
      bash "$REPO_ROOT/modules/shared/programs/claude/files/hooks/delegation-alert.sh" 2>&1
}

_delegation_alert_call() {
  local state_dir="$1" session_id="$2" prompt_id="$3"
  local tool_name="${4:-Edit}" agent_id="${5:-}"
  local input
  input=$(jq -n \
    --arg session_id "$session_id" \
    --arg prompt_id "$prompt_id" \
    --arg tool_name "$tool_name" \
    --arg agent_id "$agent_id" \
    '{
      session_id: $session_id,
      prompt_id: $prompt_id,
      tool_name: $tool_name
    } + (if $agent_id == "" then {} else {agent_id: $agent_id} end)')
  _delegation_alert_raw "$state_dir" "$input"
}

test_delegation_alert_first_four_edits_are_silent() {
  local sandbox state_dir out call
  sandbox=$(new_sandbox)
  state_dir="$sandbox/state"
  for call in 1 2 3 4; do
    out=$(_delegation_alert_call "$state_dir" "session-a" "prompt-a")
    [[ -z "$out" ]] || fail "expected edit $call to be silent, got: $out"
  done
}

test_delegation_alert_fifth_edit_warns_without_permission_decision() {
  local sandbox state_dir out call
  sandbox=$(new_sandbox)
  state_dir="$sandbox/state"
  for call in 1 2 3 4; do
    out=$(_delegation_alert_call "$state_dir" "session-a" "prompt-a")
    [[ -z "$out" ]] || fail "expected edit $call to be silent, got: $out"
  done
  out=$(_delegation_alert_call "$state_dir" "session-a" "prompt-a")
  jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"
    and (.hookSpecificOutput.additionalContext | contains("이번 턴의 직접 편집이 5회입니다"))' \
    <<<"$out" >/dev/null || fail "expected fifth edit additionalContext, got: $out"
  if jq -e 'has("permissionDecision") or (.hookSpecificOutput | has("permissionDecision"))' \
    <<<"$out" >/dev/null 2>&1; then
    fail "permissionDecision must not be present: $out"
  fi
}

test_delegation_alert_prompt_change_resets_counter() {
  local sandbox state_dir out call
  sandbox=$(new_sandbox)
  state_dir="$sandbox/state"
  for call in 1 2 3 4; do
    out=$(_delegation_alert_call "$state_dir" "session-a" "prompt-old")
    [[ -z "$out" ]] || fail "expected old prompt edit $call to be silent, got: $out"
  done
  for call in 1 2 3 4; do
    out=$(_delegation_alert_call "$state_dir" "session-a" "prompt-new")
    [[ -z "$out" ]] || fail "expected reset prompt edit $call to be silent, got: $out"
  done
  out=$(_delegation_alert_call "$state_dir" "session-a" "prompt-new")
  assert_contains "$out" "이번 턴의 직접 편집이 5회입니다"
}

test_delegation_alert_subagent_calls_are_ignored() {
  local sandbox state_dir out call
  sandbox=$(new_sandbox)
  state_dir="$sandbox/state"
  for call in 1 2 3 4 5 6; do
    out=$(_delegation_alert_call "$state_dir" "session-a" "prompt-a" "Edit" "agent-1")
    [[ -z "$out" ]] || fail "expected subagent edit $call to be silent, got: $out"
  done
  [[ ! -e "$state_dir/session-a" ]] || fail "subagent calls must not create state"
}

test_delegation_alert_bash_does_not_increment_counter() {
  local sandbox state_dir out call
  sandbox=$(new_sandbox)
  state_dir="$sandbox/state"
  for call in 1 2 3 4 5 6; do
    out=$(_delegation_alert_call "$state_dir" "session-a" "prompt-a" "Bash")
    [[ -z "$out" ]] || fail "expected Bash call $call to be silent, got: $out"
  done
  for call in 1 2 3 4; do
    out=$(_delegation_alert_call "$state_dir" "session-a" "prompt-a")
    [[ -z "$out" ]] || fail "expected counted edit $call to be silent after Bash calls, got: $out"
  done
  out=$(_delegation_alert_call "$state_dir" "session-a" "prompt-a")
  assert_contains "$out" "이번 턴의 직접 편집이 5회입니다"
}

test_delegation_alert_missing_prompt_id_creates_no_state() {
  local sandbox state_dir input out
  sandbox=$(new_sandbox)
  state_dir="$sandbox/state"
  input=$(jq -n '{session_id:"session-a",tool_name:"Edit"}')
  out=$(_delegation_alert_raw "$state_dir" "$input")
  [[ -z "$out" ]] || fail "expected missing prompt_id to be silent, got: $out"
  [[ ! -e "$state_dir/session-a" ]] || fail "missing prompt_id must not create state"
}

test_delegation_alert_sessions_count_independently() {
  local sandbox state_dir out call
  sandbox=$(new_sandbox)
  state_dir="$sandbox/state"
  for call in 1 2 3 4; do
    out=$(_delegation_alert_call "$state_dir" "session-a" "prompt-a")
    [[ -z "$out" ]] || fail "expected session-a edit $call to be silent, got: $out"
    out=$(_delegation_alert_call "$state_dir" "session-b" "prompt-b")
    [[ -z "$out" ]] || fail "expected session-b edit $call to be silent, got: $out"
  done
  out=$(_delegation_alert_call "$state_dir" "session-b" "prompt-b")
  assert_contains "$out" "이번 턴의 직접 편집이 5회입니다"
  assert_file_contains "$state_dir/session-a" "prompt-a 4"
}

test_delegation_alert_unsafe_session_id_creates_no_state() {
  local sandbox state_dir out
  sandbox=$(new_sandbox)
  state_dir="$sandbox/state"
  out=$(_delegation_alert_call "$state_dir" "../escape" "prompt-a")
  [[ -z "$out" ]] || fail "expected unsafe session_id to be silent, got: $out"
  [[ ! -e "$state_dir" ]] || fail "unsafe session_id must not create a state directory"
}
