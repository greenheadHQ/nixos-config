# shellcheck shell=bash
# SC2154: 공통 변수는 테스트 실행기가 정의한다.
# shellcheck disable=SC2154

_nfu_fixture() {
  local sandbox="$1" test_shell="$2" command
  # 고정 진입점이 바뀌면 실제 환경으로 실행이 새지 않도록 치환 전에 중단한다.
  [[ "$(grep -Fc 'FLAKE_PATH="@flakePath@"' "$REPO_ROOT/modules/shared/scripts/nfu.sh")" == 1 ]] || fail 'unknown nfu flake entrypoint'
  # shellcheck disable=SC2088  # 소스의 리터럴 경로를 찾는다.
  [[ "$(grep -Fc '~/.local/bin/nrs ' "$REPO_ROOT/modules/shared/scripts/nfu.sh")" == 1 ]] || fail 'unknown nfu switch entrypoint'
  mkdir -p "$sandbox/repo/scripts" "$sandbox/bin" "$sandbox/tmp"
  sed -e "s|@flakePath@|$sandbox/repo|g" \
    -e "s|~/.local/bin/nrs|\"$sandbox/bin/nrs\"|g" \
    "$REPO_ROOT/modules/shared/scripts/nfu.sh" > "$sandbox/repo/nfu.sh"
  cp "$REPO_ROOT/scripts/fix-fod-hashes.sh" "$sandbox/repo/scripts/fix-fod-hashes.sh"
  chmod +x "$sandbox/repo/scripts/fix-fod-hashes.sh"
  printf 'sha256-fixture1\n' > "$sandbox/repo/fixture.nix"
  : > "$sandbox/calls"
  ln -s "$test_shell" "$sandbox/bin/bash"
  cat > "$sandbox/bin/command-stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
command=${0##*/}
{
  printf '%s' "$command"
  if (( $# > 0 )); then printf ' <%s>' "$@"; fi
  printf '\n'
} >> "$NFU_FIXTURE_DIR/calls"
case "$command" in
  uname) [[ $# == 0 || "$*" == -s ]] && { printf 'Linux\n'; exit 0; } ;;
  hostname) [[ "$*" == -s ]] && { printf 'test-host\n'; exit 0; } ;;
  git)
    case "$*" in
      'diff --quiet'|'diff --cached --quiet'|'--no-pager diff flake.lock'|'checkout -- .') exit 0 ;;
      'diff --quiet flake.lock') exit 1 ;;
    esac
    if [[ "$1" == grep && $# == 8 ]]; then
      [[ "$2 $3 $4 $5 $7 $8" == '--untracked --exclude-standard -Fl -- -- *.nix' ]] || exit 97
      grep -Fqx -- "$6" fixture.nix || exit 1
      printf 'fixture.nix\n'
      exit 0
    fi
    ;;
  nrs) [[ "$1" == --force ]] && exit 0 ;;
  nix)
    [[ "$*" == 'flake update' ]] && exit 0
    if [[ "$1" == build && "$2" == '.#nixosConfigurations."test-host".config.system.build.toplevel' ]]; then
      shift 2
      dry_run=false
      while (( $# > 0 )); do
        case "$1" in
          --dry-run) dry_run=true ;;
          --no-link) ;;
          --cores) [[ $# -ge 2 ]] || exit 97; shift ;;
          *) exit 97 ;;
        esac
        shift
      done
      [[ "$dry_run" == true ]] && exit 0
      count=0
      [[ ! -f "$NFU_FIXTURE_DIR/count" ]] || read -r count < "$NFU_FIXTURE_DIR/count"
      count=$((count + 1))
      printf '%s\n' "$count" > "$NFU_FIXTURE_DIR/count"
      if (( NFU_FAIL_STATUS > 0 )); then
        printf 'fixture build failure\n'
        exit "$NFU_FAIL_STATUS"
      fi
      if (( count <= NFU_MISMATCH_ROUNDS )); then
        printf 'hash mismatch in fixed-output derivation\n  specified: sha256-fixture%s\n       got: sha256-fixture%s\n' "$count" "$((count + 1))"
        exit 1
      fi
      exit 0
    fi
    ;;
esac
printf 'unexpected fixture command\n' >&2
exit 97
STUB
  chmod +x "$sandbox/bin/command-stub"
  for command in git nix nrs uname hostname; do
    ln -s command-stub "$sandbox/bin/$command"
  done
}

_nfu_run() {
  local sandbox="$1" test_shell="$2" entry="$3"
  shift 3
  nfu_status=0
  nfu_output=$(PATH="$sandbox/bin:$PATH" TMPDIR="$sandbox/tmp" \
    NFU_FIXTURE_DIR="$sandbox" NFU_MISMATCH_ROUNDS="${nfu_mismatches:-0}" \
    NFU_FAIL_STATUS="${nfu_fail_status:-0}" \
    "$test_shell" "$sandbox/repo/$entry" "$@" 2>&1) || nfu_status=$?
}

_nfu_check_retries() {
  local test_shell="$1" sandbox cache nfu_output nfu_status nfu_mismatches=3
  local build='nix <build> <.#nixosConfigurations."test-host".config.system.build.toplevel>'
  for cache in enabled disabled; do
    sandbox=$(new_sandbox)
    _nfu_fixture "$sandbox" "$test_shell"
    if [[ "$cache" == enabled ]]; then
      _nfu_run "$sandbox" "$test_shell" nfu.sh -a --cores 2
    else
      _nfu_run "$sandbox" "$test_shell" nfu.sh -a --cores 2 --no-cache-check
    fi
    [[ "$nfu_status" == 0 ]] || fail 'nfu retry flow failed'
    assert_line_count "$sandbox/calls" "$build <--no-link> <--cores> <2>" 4
    assert_line_count "$sandbox/calls" "$build <--dry-run> <--cores> <2>" "$([[ "$cache" == enabled ]] && printf 1 || printf 0)"
    assert_line_count "$sandbox/calls" 'nrs <--force> <--cores> <2>' 1
    assert_line_count "$sandbox/calls" 'git <checkout> <--> <.>' 0
    assert_file_contains "$sandbox/repo/fixture.nix" 'sha256-fixture4'
  done
}

test_nfu_cores_reaches_all_builds() {
  _nfu_check_retries "$BASH"
}

_nfu_check_default() {
  local test_shell="$1" sandbox entry nfu_output nfu_status
  local build='nix <build> <.#nixosConfigurations."test-host".config.system.build.toplevel>'
  for entry in nfu.sh scripts/fix-fod-hashes.sh; do
    sandbox=$(new_sandbox)
    _nfu_fixture "$sandbox" "$test_shell"
    if [[ "$entry" == nfu.sh ]]; then
      _nfu_run "$sandbox" "$test_shell" "$entry" -a
      assert_line_count "$sandbox/calls" 'nrs <--force>' 1
    else
      _nfu_run "$sandbox" "$test_shell" "$entry"
      assert_not_contains "$(cat "$sandbox/calls")" nrs
    fi
    [[ "$nfu_status" == 0 ]] || fail 'default build settings failed'
    assert_line_count "$sandbox/calls" "$build <--dry-run>" 1
    assert_line_count "$sandbox/calls" "$build <--no-link>" 1
    assert_not_contains "$nfu_output" 'unbound variable'
  done
}

test_nfu_cores_preserves_default_settings() {
  _nfu_check_default "$BASH"
}

_nfu_check_option_order() {
  local test_shell="$1" sandbox entry mode expected_cores dry_count nrs_call nfu_output nfu_status
  local nfu_mismatches=3
  local build='nix <build> <.#nixosConfigurations."test-host".config.system.build.toplevel>'
  local args=()
  for entry in nfu.sh scripts/fix-fod-hashes.sh; do
    for mode in cached reverse repeated; do
      args=()
      [[ "$entry" != nfu.sh ]] || args+=(-a)
      expected_cores=2
      dry_count=0
      nrs_call='nrs <--force> <--cores> <2>'
      case "$mode" in
        cached) args+=(--cores 2); dry_count=1 ;;
        reverse) args+=(--no-cache-check --cores 2) ;;
        repeated)
          args+=(--cores 2 --cores 3 --no-cache-check)
          expected_cores=3
          nrs_call='nrs <--force> <--cores> <2> <--cores> <3>'
          ;;
      esac
      sandbox=$(new_sandbox)
      _nfu_fixture "$sandbox" "$test_shell"
      _nfu_run "$sandbox" "$test_shell" "$entry" "${args[@]}"
      [[ "$nfu_status" == 0 ]] || fail 'core option ordering failed'
      assert_line_count "$sandbox/calls" "$build <--no-link> <--cores> <$expected_cores>" 4
      assert_line_count "$sandbox/calls" "$build <--dry-run> <--cores> <$expected_cores>" "$dry_count"
      if [[ "$entry" == nfu.sh ]]; then
        assert_line_count "$sandbox/calls" "$nrs_call" 1
      else
        assert_not_contains "$(cat "$sandbox/calls")" nrs
      fi
    done
  done
}

test_nfu_cores_preserves_option_order_and_last_value() {
  _nfu_check_option_order "$BASH"
}

_nfu_check_invalid() {
  local test_shell="$1" sandbox entry value nfu_output nfu_status
  local args=()
  for entry in nfu.sh scripts/fix-fod-hashes.sh; do
    for value in missing '' 0 -1 01 2.5 text --no-cache-check; do
      args=()
      [[ "$entry" != nfu.sh ]] || args+=(-a)
      args+=(--cores)
      [[ "$value" == missing ]] || args+=("$value")
      sandbox=$(new_sandbox)
      _nfu_fixture "$sandbox" "$test_shell"
      _nfu_run "$sandbox" "$test_shell" "$entry" "${args[@]}"
      [[ "$nfu_status" == 1 ]] || fail 'invalid core count must fail'
      assert_contains "$nfu_output" '--cores: positive integer required'
      [[ ! -s "$sandbox/calls" ]] || fail 'invalid core count started external work'
    done
  done
}

test_nfu_cores_rejects_invalid_before_work() {
  _nfu_check_invalid "$BASH"
}

_nfu_check_failure() {
  local test_shell="$1" sandbox mode expected_status build_count nfu_output nfu_status
  local nfu_fail_status nfu_mismatches
  local build='nix <build> <.#nixosConfigurations."test-host".config.system.build.toplevel>'
  for mode in error interrupt exhausted; do
    nfu_fail_status=0
    nfu_mismatches=0
    expected_status=1
    build_count=1
    case "$mode" in
      error) nfu_fail_status=1 ;;
      interrupt) nfu_fail_status=130; expected_status=130 ;;
      exhausted) nfu_mismatches=4; build_count=4 ;;
    esac
    sandbox=$(new_sandbox)
    _nfu_fixture "$sandbox" "$test_shell"
    _nfu_run "$sandbox" "$test_shell" nfu.sh -a --cores 2 --no-cache-check
    [[ "$nfu_status" == "$expected_status" ]] || fail 'FOD failure status was lost'
    assert_line_count "$sandbox/calls" "$build <--no-link> <--cores> <2>" "$build_count"
    assert_not_contains "$(cat "$sandbox/calls")" nrs
    assert_line_count "$sandbox/calls" 'git <checkout> <--> <.>' 1
  done
}

test_nfu_fod_failure_prevents_switch() {
  _nfu_check_failure "$BASH"
}

test_nfu_cores_supports_system_bash32() {
  if [[ ! -x /bin/bash ]] || ! /bin/bash -c '[[ ${BASH_VERSINFO[0]} == 3 && ${BASH_VERSINFO[1]} == 2 ]]'; then
    echo 'N/A: system Bash 3.2 is unavailable' >&2
    return 0
  fi
  _nfu_check_retries /bin/bash
  _nfu_check_default /bin/bash
  _nfu_check_option_order /bin/bash
  _nfu_check_invalid /bin/bash
  _nfu_check_failure /bin/bash
}
