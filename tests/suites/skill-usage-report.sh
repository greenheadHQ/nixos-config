# tests/suites/skill-usage-report.sh — skill usage report fixtures
# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164

_skill_usage_report_script() {
  printf '%s\n' "$REPO_ROOT/scripts/ai/skill-usage-report.sh"
}

_skill_usage_report_fixture() {
  printf '%s\n' "$FIXTURE_DIR/skill-usage-report.tsv"
}

_skill_usage_report_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    fail "neither sha256sum nor shasum available for skill-usage-report test hashing"
  fi
}

test_skill_usage_report_aggregates_sample_tsv() {
  local output expected
  output=$(bash "$(_skill_usage_report_script)" --log "$(_skill_usage_report_fixture)")
  expected=$(cat "$FIXTURE_DIR/skill-usage-report.expected")
  [[ "$output" == "$expected" ]] || fail "unexpected skill usage report output: $output"
}

test_skill_usage_report_since_filters_sample_tsv() {
  local output expected
  output=$(bash "$(_skill_usage_report_script)" --log "$(_skill_usage_report_fixture)" --since 2026-02-01)
  expected=$(cat "$FIXTURE_DIR/skill-usage-report.since.expected")
  [[ "$output" == "$expected" ]] || fail "unexpected filtered skill usage report output: $output"
}

# v2 JSONL fixture는 legacy TSV fixture와 같은 (ts, skill) 이벤트를 담는다 —
# malformed rows(wrong schema_version, invalid session_key, extra key, broken JSON)는 skip.
test_skill_usage_report_v2_jsonl_matches_legacy_aggregation() {
  local output expected
  output=$(bash "$(_skill_usage_report_script)" --log "$FIXTURE_DIR/skill-usage-report.v2.jsonl")
  expected=$(cat "$FIXTURE_DIR/skill-usage-report.expected")
  [[ "$output" == "$expected" ]] || fail "unexpected v2-only skill usage report output: $output"
}

# writer(log-skill.sh)와 parser(skill-usage-report.sh)의 스킬명 문법 계약 parity —
# 경계값이 양쪽에서 동일하게 수락/거부되는지 검증해 한쪽만 수정되는 drift를 잡는다.
test_skill_usage_report_skill_grammar_parity_with_writer() {
  local sandbox home log ok128 bad129 v2log output
  sandbox=$(new_sandbox)
  home="$sandbox/home"
  mkdir -p "$home/.claude"
  log="$home/.claude/skill-usage.log"
  ok128=$(printf 'a%.0s' {1..128})
  bad129=$(printf 'a%.0s' {1..129})

  # writer: 유효 경계(128자)는 기록, 초과(129자)·제어문자는 거부
  for skill in "run-da" "$ok128"; do
    printf '%s' "$(jq -cn --arg s "$skill" '{session_id:"sid-parity",tool_input:{skill:$s}}')" | \
      env HOOK_RUNTIME_LIB="$REPO_ROOT/modules/shared/programs/claude/files/lib/hook-runtime.sh" \
      HOME="$home" bash "$REPO_ROOT/modules/shared/programs/claude/files/hooks/log-skill.sh"
  done
  for skill in "$bad129" $'bad\nskill'; do
    printf '%s' "$(jq -cn --arg s "$skill" '{session_id:"sid-parity",tool_input:{skill:$s}}')" | \
      env HOOK_RUNTIME_LIB="$REPO_ROOT/modules/shared/programs/claude/files/lib/hook-runtime.sh" \
      HOME="$home" bash "$REPO_ROOT/modules/shared/programs/claude/files/hooks/log-skill.sh"
  done
  [[ "$(wc -l < "$log")" -eq 2 ]] || fail "writer grammar boundary mismatch: $(cat "$log")"

  # parser: writer가 기록한 두 행은 집계되고, 수기로 주입한 초과 길이 v2 행은 skip된다
  v2log="$sandbox/v2.jsonl"
  cp "$log" "$v2log"
  printf '%s\n' "$(jq -cn --arg s "$bad129" \
    '{schema_version:2,event_type:"skill_invocation",ts:1742302800,runtime:"claude-main",skill:$s,session_key:("ab" * 32)}')" >> "$v2log"
  output=$(bash "$(_skill_usage_report_script)" --log "$v2log")
  assert_contains "$output" "run-da"
  assert_contains "$output" "$ok128"
  assert_not_contains "$output" "$bad129"
}

test_skill_usage_report_mixed_log_matches_legacy_aggregation() {
  local output expected
  output=$(bash "$(_skill_usage_report_script)" --log "$FIXTURE_DIR/skill-usage-report.mixed.log")
  expected=$(cat "$FIXTURE_DIR/skill-usage-report.expected")
  [[ "$output" == "$expected" ]] || fail "unexpected mixed skill usage report output: $output"

  output=$(bash "$(_skill_usage_report_script)" --log "$FIXTURE_DIR/skill-usage-report.mixed.log" --since 2026-02-01)
  expected=$(cat "$FIXTURE_DIR/skill-usage-report.since.expected")
  [[ "$output" == "$expected" ]] || fail "unexpected filtered mixed skill usage report output: $output"
}

test_skill_usage_report_does_not_modify_input_log() {
  local sandbox copy before after
  sandbox=$(new_sandbox)
  copy="$sandbox/skill-usage.log"
  cat "$(_skill_usage_report_fixture)" "$FIXTURE_DIR/skill-usage-report.v2.jsonl" > "$copy"
  before=$(_skill_usage_report_sha256 "$copy")
  bash "$(_skill_usage_report_script)" --log "$copy" >/dev/null
  after=$(_skill_usage_report_sha256 "$copy")
  [[ "$before" == "$after" ]] || fail "expected report to leave input log bytes unchanged"
}

test_skill_usage_report_missing_log_errors() {
  local sandbox output
  sandbox=$(new_sandbox)

  if output=$(bash "$(_skill_usage_report_script)" --log "$sandbox/missing.log" 2>&1); then
    fail "expected missing skill usage log to fail"
  fi
  assert_contains "$output" "skill usage log not found"
  assert_contains "$output" "use --log PATH"
}
