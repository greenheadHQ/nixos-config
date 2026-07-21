# tests/suites/skill-usage-report.sh - skill usage report fixtures
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
  assert_not_contains "$output" "extra-key-must-be-rejected"
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
