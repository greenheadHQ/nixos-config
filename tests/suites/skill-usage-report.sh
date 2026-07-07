# tests/suites/skill-usage-report.sh - skill usage report fixtures
# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164

_skill_usage_report_script() {
  printf '%s\n' "$REPO_ROOT/scripts/ai/skill-usage-report.sh"
}

_skill_usage_report_fixture() {
  printf '%s\n' "$FIXTURE_DIR/skill-usage-report.tsv"
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

test_skill_usage_report_missing_log_errors() {
  local sandbox output
  sandbox=$(new_sandbox)

  if output=$(bash "$(_skill_usage_report_script)" --log "$sandbox/missing.log" 2>&1); then
    fail "expected missing skill usage log to fail"
  fi
  assert_contains "$output" "skill usage log not found"
  assert_contains "$output" "use --log PATH"
}
