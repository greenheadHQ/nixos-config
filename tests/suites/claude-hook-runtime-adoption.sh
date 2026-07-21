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

test_log_skill_hook_normal_input_logs_v2_event() {
  local sandbox home input out log key line keyset
  sandbox=$(new_sandbox)
  home="$sandbox/home"
  mkdir -p "$home/.claude"
  # synthetic credential-shaped placeholder + tab/newline — raw args는 log에 절대 남지 않아야 한다
  input=$(jq -n \
    --arg sid "sid-raw-1" \
    --arg skill "managing-minipc" \
    --arg args $'--token FAKE-PLACEHOLDER-SECRET\tline2\nline3' \
    '{session_id:$sid,tool_input:{skill:$skill,args:$args}}')
  out=$(_chra_run_hook "log-skill.sh" "$input" HOME="$home" USER="tester")
  [[ -z "$out" ]] || fail "expected log-skill normal input to produce no stdout, got: $out"
  log="$home/.claude/skill-usage.log"
  key="$home/.claude/skill-usage.key"
  [ -f "$log" ] || fail "expected log-skill to create usage log"
  [ -f "$key" ] || fail "expected log-skill to create pseudonym key"
  [[ "$(wc -l < "$log")" -eq 1 ]] || fail "expected exactly one v2 event line"
  line=$(cat "$log")
  # 한 줄 valid JSON + exact 6-key set + exact types (Target event contract)
  printf '%s' "$line" | jq -e . >/dev/null || fail "expected v2 event to be valid JSON: $line"
  keyset=$(printf '%s' "$line" | jq -r 'keys_unsorted | join(",")')
  [[ "$keyset" == "schema_version,event_type,ts,runtime,skill,session_key" ]] || \
    fail "unexpected v2 key set: $keyset"
  printf '%s' "$line" | jq -e '
    .schema_version == 2
    and .event_type == "skill_invocation"
    and (.ts | type == "number")
    and .runtime == "claude-main"
    and .skill == "managing-minipc"
    and (.session_key | type == "string" and test("^[0-9a-f]{64}$"))
  ' >/dev/null || fail "v2 event contract violated: $line"
  # 금지 필드 부재: args placeholder / user / repo / raw session id / key material
  assert_not_contains "$line" "FAKE-PLACEHOLDER-SECRET"
  assert_not_contains "$line" "tester"
  assert_not_contains "$line" "sid-raw-1"
  assert_not_contains "$line" "$(cat "$key")"
  # log/key 모두 owner-only 0600
  [[ "$(_codex_config_file_mode "$log")" == "600" ]] || fail "expected usage log mode 600"
  [[ "$(_codex_config_file_mode "$key")" == "600" ]] || fail "expected pseudonym key mode 600"
}

test_log_skill_hook_repairs_loose_log_mode() {
  # 기존 파일은 umask가 지켜주지 않는다 — 0644로 남은 log를 600으로 교정한 뒤에만 기록해야 한다.
  local sandbox home out log
  sandbox=$(new_sandbox)
  home="$sandbox/home"
  mkdir -p "$home/.claude"
  log="$home/.claude/skill-usage.log"
  printf '%s\n' '{"schema_version":2,"event_type":"skill_invocation"}' > "$log"
  chmod 644 "$log"

  out=$(_chra_run_hook "log-skill.sh" \
    '{"session_id":"sid-mode-1","tool_input":{"skill":"run-da"}}' HOME="$home" USER="tester")
  [[ -z "$out" ]] || fail "unexpected hook output: $out"
  [[ "$(wc -l < "$log")" -eq 2 ]] || fail "expected appended event after mode repair"
  [[ "$(_codex_config_file_mode "$log")" == "600" ]] || fail "expected loose log mode repaired to 600"
}

test_log_skill_hook_skips_symlinked_key() {
  # 심링크로 치환된 key는 trust boundary 위반 — 이벤트를 포기하고 아무 것도 기록하지 않는다.
  local sandbox home out log key target
  sandbox=$(new_sandbox)
  home="$sandbox/home"
  mkdir -p "$home/.claude"
  key="$home/.claude/skill-usage.key"
  log="$home/.claude/skill-usage.log"
  target="$sandbox/planted-key"
  printf '%s' "abad1deaabad1deaabad1deaabad1deaabad1deaabad1deaabad1deaabad1dea" > "$target"
  ln -s "$target" "$key"

  out=$(_chra_run_hook "log-skill.sh" \
    '{"session_id":"sid-sym-1","tool_input":{"skill":"run-da"}}' HOME="$home" USER="tester")
  [[ -z "$out" ]] || fail "unexpected hook output: $out"
  [ ! -e "$log" ] || fail "expected no event when key is a symlink"
}

test_log_skill_hook_session_key_is_stable_pseudonym() {
  local sandbox home out log k1 k2 k3
  sandbox=$(new_sandbox)
  home="$sandbox/home"
  mkdir -p "$home/.claude"
  log="$home/.claude/skill-usage.log"

  out=$(_chra_run_hook "log-skill.sh" \
    '{"session_id":"sid-stable-1","tool_input":{"skill":"run-da"}}' HOME="$home" USER="tester")
  [[ -z "$out" ]] || fail "unexpected hook output: $out"
  out=$(_chra_run_hook "log-skill.sh" \
    '{"session_id":"sid-stable-1","tool_input":{"skill":"run-da"}}' HOME="$home" USER="tester")
  [[ -z "$out" ]] || fail "unexpected hook output: $out"
  out=$(_chra_run_hook "log-skill.sh" \
    '{"session_id":"sid-stable-2","tool_input":{"skill":"run-da"}}' HOME="$home" USER="tester")
  [[ -z "$out" ]] || fail "unexpected hook output: $out"

  k1=$(sed -n 1p "$log" | jq -r .session_key)
  k2=$(sed -n 2p "$log" | jq -r .session_key)
  k3=$(sed -n 3p "$log" | jq -r .session_key)
  [[ "$k1" == "$k2" ]] || fail "expected same session id to map to same session_key"
  [[ "$k1" != "$k3" ]] || fail "expected different session ids to map to different session_keys"
}

test_log_skill_hook_invalid_key_skips_event_without_fallback() {
  local sandbox home out log key
  sandbox=$(new_sandbox)
  home="$sandbox/home"
  mkdir -p "$home/.claude"
  log="$home/.claude/skill-usage.log"
  key="$home/.claude/skill-usage.key"
  # key 읽기/검증 실패 시 raw id fallback 없이 event를 건너뛴다
  printf 'not-64-lowercase-hex\n' > "$key"

  out=$(_chra_run_hook "log-skill.sh" \
    '{"session_id":"sid-raw-2","tool_input":{"skill":"run-da"}}' HOME="$home" USER="tester")
  [[ -z "$out" ]] || fail "expected invalid key to noop, got: $out"
  [ ! -e "$log" ] || fail "expected invalid key to skip event without raw-id fallback"
}

test_log_skill_hook_empty_malformed_and_subagent_noop() {
  local sandbox home input out log key
  sandbox=$(new_sandbox)
  home="$sandbox/home"
  mkdir -p "$home/.claude"
  log="$home/.claude/skill-usage.log"
  key="$home/.claude/skill-usage.key"

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
  [ ! -e "$key" ] || fail "expected noop paths not to create pseudonym key"
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
