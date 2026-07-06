# tests/suites/claude-hook-runtime-adoption.sh — hook-runtime parser adoption fixtures
# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164

_chra_hook_runtime_lib() {
  printf '%s' "$REPO_ROOT/modules/shared/programs/claude/files/lib/hook-runtime.sh"
}

_chra_session_state_lib() {
  printf '%s' "$REPO_ROOT/modules/shared/programs/claude/files/lib/session-state.sh"
}

_chra_hook_path() {
  printf '%s' "$REPO_ROOT/modules/shared/programs/claude/files/hooks/$1"
}

_chra_run_hook() {
  local hook_name="$1" input="$2"
  shift 2
  printf '%s' "$input" | \
    env HOOK_RUNTIME_LIB="$(_chra_hook_runtime_lib)" "$@" bash "$(_chra_hook_path "$hook_name")" 2>&1
}

_chra_git_init() {
  local repo="$1"
  GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_NOSYSTEM=1 \
    git -C "$repo" -c init.templateDir= init -b main >/dev/null 2>&1
}

_chra_make_old_file() {
  local path="$1"
  printf '%s\n' "old transient buffer" > "$path"
  touch -d '10 days ago' "$path" 2>/dev/null || touch -t 200001010000 "$path"
}

_chra_marker_path() {
  local home="$1" cwd="$2"
  HOME="$home" SESSION_STATE_LIB="$(_chra_session_state_lib)" CWD_FOR_MARKER="$cwd" \
    bash -c '. "$SESSION_STATE_LIB"; marker_path_for_cwd "$CWD_FOR_MARKER"'
}

test_log_skill_hook_normal_input_logs_usage() {
  local sandbox home input out log line
  sandbox=$(new_sandbox)
  home="$sandbox/home"
  mkdir -p "$home/.claude"
  input=$(jq -n \
    --arg sid "sid-1" \
    --arg skill "managing-minipc" \
    --arg args "arg value" \
    '{session_id:$sid,tool_input:{skill:$skill,args:$args}}')
  out=$(_chra_run_hook "log-skill.sh" "$input" HOME="$home" USER="tester")
  [[ -z "$out" ]] || fail "expected log-skill normal input to produce no stdout, got: $out"
  log="$home/.claude/skill-usage.log"
  [ -f "$log" ] || fail "expected log-skill to create usage log"
  line=$(cat "$log")
  assert_contains "$line" $'tester\tsid-1'
  assert_contains "$line" $'\tmanaging-minipc\targ value'
}

test_log_skill_hook_empty_malformed_and_subagent_noop() {
  local sandbox home input out log
  sandbox=$(new_sandbox)
  home="$sandbox/home"
  mkdir -p "$home/.claude"
  log="$home/.claude/skill-usage.log"

  out=$(_chra_run_hook "log-skill.sh" "" HOME="$home" USER="tester")
  [[ -z "$out" ]] || fail "expected log-skill empty stdin to noop, got: $out"
  [ ! -e "$log" ] || fail "expected log-skill empty stdin not to create log"

  out=$(_chra_run_hook "log-skill.sh" '{"tool_input":' HOME="$home" USER="tester")
  [[ -z "$out" ]] || fail "expected log-skill malformed JSON to noop, got: $out"
  [ ! -e "$log" ] || fail "expected log-skill malformed JSON not to create log"

  input=$(jq -n '{agent_id:"agent-1",session_id:"sid-1",tool_input:{skill:"demo"}}')
  out=$(_chra_run_hook "log-skill.sh" "$input" HOME="$home" USER="tester")
  [[ -z "$out" ]] || fail "expected log-skill subagent input to noop, got: $out"
  [ ! -e "$log" ] || fail "expected log-skill subagent input not to create log"
}

test_nrs_session_cleanup_hook_empty_malformed_and_nonrepo_input_noop() {
  local sandbox home input out
  sandbox=$(new_sandbox)
  home="$sandbox/home"
  mkdir -p "$home"

  out=$(_chra_run_hook "nrs-session-cleanup.sh" "" HOME="$home")
  [[ -z "$out" ]] || fail "expected nrs cleanup empty stdin to noop, got: $out"

  out=$(_chra_run_hook "nrs-session-cleanup.sh" '{"cwd":' HOME="$home")
  [[ -z "$out" ]] || fail "expected nrs cleanup malformed JSON to noop, got: $out"

  input=$(jq -n --arg cwd "$sandbox/not-a-git-repo" '{cwd:$cwd}')
  out=$(_chra_run_hook "nrs-session-cleanup.sh" "$input" HOME="$home")
  [[ -z "$out" ]] || fail "expected nrs cleanup non-repo cwd to noop, got: $out"
}

test_plans_gc_hook_removes_old_transient_buffer() {
  local sandbox home repo old input out
  sandbox=$(new_sandbox)
  home="$sandbox/home"
  repo="$sandbox/repo"
  mkdir -p "$home" "$repo/.claude/plans"
  _chra_git_init "$repo"
  old="$repo/.claude/plans/demo-1a2b3c4d.md"
  _chra_make_old_file "$old"

  input=$(jq -n --arg cwd "$repo" '{cwd:$cwd}')
  out=$(_chra_run_hook "plans-gc.sh" "$input" HOME="$home")
  [[ -z "$out" ]] || fail "expected plans-gc normal input to produce no stdout, got: $out"
  [ ! -e "$old" ] || fail "expected plans-gc to remove old transient buffer"
}

test_plans_gc_hook_empty_and_malformed_input_noop() {
  local sandbox home repo keep out
  sandbox=$(new_sandbox)
  home="$sandbox/home"
  repo="$sandbox/repo"
  mkdir -p "$home" "$repo/.claude/plans"
  _chra_git_init "$repo"
  keep="$repo/.claude/plans/demo-1a2b3c4d.md"
  _chra_make_old_file "$keep"

  out=$(_chra_run_hook "plans-gc.sh" "" HOME="$home")
  [[ -z "$out" ]] || fail "expected plans-gc empty stdin to noop, got: $out"
  [ -f "$keep" ] || fail "expected plans-gc empty stdin not to remove files"

  out=$(_chra_run_hook "plans-gc.sh" '{"cwd":' HOME="$home")
  [[ -z "$out" ]] || fail "expected plans-gc malformed JSON to noop, got: $out"
  [ -f "$keep" ] || fail "expected plans-gc malformed JSON not to remove files"
}

test_record_last_session_hook_normal_input_writes_marker() {
  local sandbox home cwd sid input out marker
  sandbox=$(new_sandbox)
  home="$sandbox/home"
  cwd="$sandbox/project"
  sid="sid-abc_1"
  mkdir -p "$home" "$cwd"
  input=$(jq -n --arg sid "$sid" --arg cwd "$cwd" '{session_id:$sid,cwd:$cwd}')

  out=$(_chra_run_hook "record-last-session.sh" "$input" \
    HOME="$home" SESSION_STATE_LIB="$(_chra_session_state_lib)")
  [[ -z "$out" ]] || fail "expected record-last-session normal input to produce no stdout, got: $out"
  marker=$(_chra_marker_path "$home" "$cwd")
  assert_file_contains "$marker" "$sid"
}

test_record_last_session_hook_empty_malformed_and_subagent_noop() {
  local sandbox home cwd sid input out marker
  sandbox=$(new_sandbox)
  home="$sandbox/home"
  cwd="$sandbox/project"
  sid="sid-abc_1"
  mkdir -p "$home" "$cwd"
  marker=$(_chra_marker_path "$home" "$cwd")

  out=$(_chra_run_hook "record-last-session.sh" "" \
    HOME="$home" SESSION_STATE_LIB="$(_chra_session_state_lib)")
  [[ -z "$out" ]] || fail "expected record-last-session empty stdin to noop, got: $out"
  [ ! -e "$marker" ] || fail "expected record-last-session empty stdin not to create marker"

  out=$(_chra_run_hook "record-last-session.sh" '{"session_id":' \
    HOME="$home" SESSION_STATE_LIB="$(_chra_session_state_lib)")
  [[ -z "$out" ]] || fail "expected record-last-session malformed JSON to noop, got: $out"
  [ ! -e "$marker" ] || fail "expected record-last-session malformed JSON not to create marker"

  input=$(jq -n --arg sid "$sid" --arg cwd "$cwd" '{agent_id:"agent-1",session_id:$sid,cwd:$cwd}')
  out=$(_chra_run_hook "record-last-session.sh" "$input" \
    HOME="$home" SESSION_STATE_LIB="$(_chra_session_state_lib)")
  [[ -z "$out" ]] || fail "expected record-last-session subagent input to noop, got: $out"
  [ ! -e "$marker" ] || fail "expected record-last-session subagent input not to create marker"
}

test_session_init_icons_hook_startup_creates_state_and_context() {
  local sandbox home cwd sid input out
  sandbox=$(new_sandbox)
  home="$sandbox/home"
  cwd="$sandbox/project"
  sid="sid-start_1"
  mkdir -p "$home" "$cwd"
  input=$(jq -n --arg sid "$sid" --arg cwd "$cwd" \
    '{session_id:$sid,source:"startup",cwd:$cwd,transcript_path:""}')

  out=$(_chra_run_hook "session-init-icons.sh" "$input" \
    HOME="$home" SESSION_STATE_LIB="$(_chra_session_state_lib)")
  assert_contains "$out" '"hookEventName": "SessionStart"'
  [ -f "$home/.claude/status-icons/$sid.json" ] || fail "expected session-init-icons to create state file"
  [ -f "$home/.claude/memos/$sid.md" ] || fail "expected session-init-icons to create memo file"
}

test_session_init_icons_hook_empty_and_malformed_input_noop() {
  local sandbox home out
  sandbox=$(new_sandbox)
  home="$sandbox/home"
  mkdir -p "$home"

  out=$(_chra_run_hook "session-init-icons.sh" "" \
    HOME="$home" SESSION_STATE_LIB="$(_chra_session_state_lib)")
  [[ -z "$out" ]] || fail "expected session-init-icons empty stdin to noop, got: $out"

  out=$(_chra_run_hook "session-init-icons.sh" '{"session_id":' \
    HOME="$home" SESSION_STATE_LIB="$(_chra_session_state_lib)")
  [[ -z "$out" ]] || fail "expected session-init-icons malformed JSON to noop, got: $out"
}

test_system_bash_guard_hook_denies_bash_write_and_edit_patterns() {
  local sandbox file input out
  sandbox=$(new_sandbox)

  input=$(jq -n --arg cmd "/bin/bash -lc true" '{tool_name:"Bash",tool_input:{command:$cmd}}')
  out=$(_chra_run_hook "system-bash-guard.sh" "$input")
  assert_contains "$out" '"permissionDecision": "deny"'

  input=$(jq -n --arg content $'#!/bin/bash\nprintf ok\n' '{tool_name:"Write",tool_input:{content:$content}}')
  out=$(_chra_run_hook "system-bash-guard.sh" "$input")
  assert_contains "$out" '"permissionDecision": "deny"'

  file="$sandbox/script.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'printf ok' > "$file"
  input=$(jq -n \
    --arg path "$file" \
    --arg old "#!/usr/bin/env bash" \
    --arg new "#!/bin/bash" \
    '{tool_name:"Edit",tool_input:{file_path:$path,old_string:$old,new_string:$new}}')
  out=$(_chra_run_hook "system-bash-guard.sh" "$input")
  assert_contains "$out" '"permissionDecision": "deny"'
}

test_system_bash_guard_hook_empty_and_malformed_input_noop() {
  local out
  out=$(_chra_run_hook "system-bash-guard.sh" "")
  [[ -z "$out" ]] || fail "expected system-bash-guard empty stdin to noop, got: $out"
  out=$(_chra_run_hook "system-bash-guard.sh" '{"tool_name":')
  [[ -z "$out" ]] || fail "expected system-bash-guard malformed JSON to noop, got: $out"
}
