# tests/suites/atuin-clean-kr.sh — atuin-clean-kr 삭제 전 SQLite 백업 계약 (sourced)
# shellcheck shell=bash
# shellcheck disable=SC2154
test_atuin_clean_kr_backup_contract() {
  python3 "$REPO_ROOT/tests/atuin-clean-kr-tests.py"
}
