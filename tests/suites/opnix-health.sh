# shellcheck shell=bash
# shellcheck disable=SC2154
test_opnix_health_check_lifecycle() {
  python3 "$REPO_ROOT/tests/opnix-health-check-tests.py"
}
