# tests/suites/shottr-defaults.sh — Shottr defaults deadline/circuit-breaker fixtures
# shellcheck shell=bash
# shellcheck disable=SC2154

test_shottr_defaults_helper_behavior() {
  local sandbox timeout_bin defaults_bin timeout_log defaults_log output helper
  sandbox="$(new_sandbox)"
  timeout_bin="$sandbox/timeout"
  defaults_bin="$sandbox/defaults"
  timeout_log="$sandbox/timeout.log"
  defaults_log="$sandbox/defaults.log"
  output="$sandbox/output.log"
  helper="$REPO_ROOT/modules/darwin/programs/shottr/defaults-helper.sh"

  cat >"$timeout_bin" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_TIMEOUT_LOG"
if [ "${FAKE_TIMEOUT_STATUS:-0}" -ne 0 ]; then
  exit "$FAKE_TIMEOUT_STATUS"
fi
[ "$1" = "-k" ] && [ "$2" = "5s" ] && [ "$3" = "30s" ] || exit 98
shift 3
exec "$@"
EOF
  cat >"$defaults_bin" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_DEFAULTS_LOG"
if [ "${FAKE_DEFAULTS_STATUS:-0}" -ne 0 ]; then
  exit "$FAKE_DEFAULTS_STATUS"
fi
if [ "$1" = "read" ]; then
  printf '%s\n' '/declared/folder'
fi
EOF
  chmod +x "$timeout_bin" "$defaults_bin"
  : >"$timeout_log"
  : >"$defaults_log"
  export FAKE_TIMEOUT_LOG="$timeout_log" FAKE_DEFAULTS_LOG="$defaults_log"

  # An inherited activation environment must not disable the TCC deadline.
  export SHOTTR_DEFAULTS_KILL_AFTER=0 SHOTTR_DEFAULTS_DEADLINE=0
  # shellcheck source=/dev/null
  source "$helper"
  [ "$SHOTTR_DEFAULTS_KILL_AFTER" = "5s" ] \
    || fail "inherited environment changed the defaults kill-after bound"
  [ "$SHOTTR_DEFAULTS_DEADLINE" = "30s" ] \
    || fail "inherited environment changed the defaults deadline"

  SHOTTR_DEFAULTS_WRITES_BLOCKED=0
  export FAKE_TIMEOUT_STATUS=124
  shottr_defaults_read current_folder \
    "$timeout_bin" "$defaults_bin" cc.ffitch.shottr defaultFolder >"$output"
  [ "$SHOTTR_DEFAULTS_WRITES_BLOCKED" = "1" ] || fail "read timeout must block later writes"
  unset FAKE_TIMEOUT_STATUS
  shottr_defaults_write \
    "$timeout_bin" "$defaults_bin" cc.ffitch.shottr saveFormat Auto >>"$output"
  [ "$(wc -l <"$timeout_log" | tr -d '[:space:]')" = "1" ] \
    || fail "blocked read must prevent a later defaults write"
  assert_contains "$(cat "$output")" "defaults read defaultFolder timed out"

  : >"$timeout_log"
  : >"$defaults_log"
  : >"$output"
  SHOTTR_DEFAULTS_WRITES_BLOCKED=0
  export FAKE_TIMEOUT_STATUS=137
  shottr_defaults_write \
    "$timeout_bin" "$defaults_bin" cc.ffitch.shottr kc-license -string fixture-secret >"$output"
  [ "$SHOTTR_DEFAULTS_WRITES_BLOCKED" = "1" ] || fail "write timeout must block later writes"
  unset FAKE_TIMEOUT_STATUS
  shottr_defaults_write \
    "$timeout_bin" "$defaults_bin" cc.ffitch.shottr kc-vault -string second-secret >>"$output"
  [ "$(wc -l <"$timeout_log" | tr -d '[:space:]')" = "1" ] \
    || fail "blocked write must prevent a later defaults write"
  assert_contains "$(cat "$output")" "defaults write kc-license timed out"
  assert_not_contains "$(cat "$output")" "fixture-secret"
  assert_not_contains "$(cat "$output")" "second-secret"

  : >"$timeout_log"
  : >"$defaults_log"
  : >"$output"
  SHOTTR_DEFAULTS_WRITES_BLOCKED=0
  export FAKE_DEFAULTS_STATUS=1
  shottr_defaults_write \
    "$timeout_bin" "$defaults_bin" cc.ffitch.shottr saveFormat Auto >"$output"
  unset FAKE_DEFAULTS_STATUS
  shottr_defaults_write \
    "$timeout_bin" "$defaults_bin" cc.ffitch.shottr scrollingManualEnabled -bool true >>"$output"
  [ "$SHOTTR_DEFAULTS_WRITES_BLOCKED" = "0" ] || fail "ordinary defaults failure must not trip TCC breaker"
  [ "$(wc -l <"$defaults_log" | tr -d '[:space:]')" = "2" ] \
    || fail "ordinary failure must allow the next declared write"
  if grep -Fv -- '-k 5s 30s ' "$timeout_log" | grep -q .; then
    fail "every defaults access must retain the outer deadline"
  fi

  for timeout_status in 124 137; do
    : > "$timeout_log"
    : > "$defaults_log"
    : > "$output"
    SHOTTR_DEFAULTS_WRITES_BLOCKED=0
    export FAKE_TIMEOUT_STATUS="$timeout_status"
    shottr_defaults_write_stdin \
      "$timeout_bin" "$defaults_bin" "$sandbox/preferences" kc-license \
      < <(builtin printf '%s' 'stdin-timeout-secret') > "$output"
    [ "$SHOTTR_DEFAULTS_WRITES_BLOCKED" = "1" ] \
      || fail "stdin writer timeout $timeout_status must block later writes"
    unset FAKE_TIMEOUT_STATUS
    shottr_defaults_write_stdin \
      "$timeout_bin" "$defaults_bin" "$sandbox/preferences" kc-vault \
      < <(builtin printf '%s' 'stdin-blocked-secret') >> "$output"
    [ "$(wc -l < "$timeout_log" | tr -d '[:space:]')" = "1" ] \
      || fail "stdin writer timeout must prevent a later secret write"
    assert_contains "$(cat "$output")" "defaults write kc-license timed out"
    assert_not_contains "$(cat "$timeout_log")" "stdin-timeout-secret"
    assert_not_contains "$(cat "$timeout_log")" "stdin-blocked-secret"
  done

  : > "$timeout_log"
  : > "$defaults_log"
  : > "$output"
  SHOTTR_DEFAULTS_WRITES_BLOCKED=0
  export FAKE_DEFAULTS_STATUS=1
  shottr_defaults_write_stdin \
    "$timeout_bin" "$defaults_bin" "$sandbox/preferences" kc-license \
    < <(builtin printf '%s' 'stdin-ordinary-failure') > "$output"
  unset FAKE_DEFAULTS_STATUS
  shottr_defaults_write_stdin \
    "$timeout_bin" "$defaults_bin" "$sandbox/preferences" kc-vault \
    < <(builtin printf '%s' 'stdin-next-write') >> "$output"
  [ "$SHOTTR_DEFAULTS_WRITES_BLOCKED" = "0" ] \
    || fail "ordinary stdin writer failure must not trip TCC breaker"
  [ "$(wc -l < "$timeout_log" | tr -d '[:space:]')" = "2" ] \
    || fail "ordinary stdin writer failure must allow the next declared write"
}

test_shottr_secret_writer_uses_stdin_without_argv() (
  local sandbox timeout_bin writer_bin timeout_pid_file writer_pid_file
  local received_file writer_env_file hold_file output helper sentinel call_pid timeout_pid writer_pid
  local arg received
  sandbox="$(new_sandbox)"
  timeout_bin="$sandbox/timeout"
  writer_bin="$sandbox/writer"
  timeout_pid_file="$sandbox/timeout.pid"
  writer_pid_file="$sandbox/writer.pid"
  received_file="$sandbox/received"
  writer_env_file="$sandbox/writer.env"
  hold_file="$sandbox/hold"
  output="$sandbox/output.log"
  helper="$REPO_ROOT/modules/darwin/programs/shottr/defaults-helper.sh"
  sentinel='issue-1093-secret-argv-sentinel'

  # shellcheck disable=SC2329 # invoked by the EXIT trap on fixture failure
  cleanup_shottr_secret_writer_fixture() {
    local pid pid_file
    rm -f "$hold_file"
    for pid_file in "$writer_pid_file" "$timeout_pid_file"; do
      [ -s "$pid_file" ] || continue
      pid="$(cat "$pid_file")"
      case "$pid" in
        ''|*[!0-9]*) continue ;;
      esac
      kill -TERM "$pid" 2>/dev/null || true
    done
    if [ -n "${call_pid:-}" ]; then
      kill -TERM "$call_pid" 2>/dev/null || true
      wait "$call_pid" 2>/dev/null || true
    fi
  }
  trap cleanup_shottr_secret_writer_fixture EXIT

  cat > "$timeout_bin" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = "-k" ] && [ "$2" = "5s" ] && [ "$3" = "30s" ] || exit 98
shift 3
exec 3<&0
"$@" <&3 &
child=$!
printf '%s\n' "$$" > "$FAKE_TIMEOUT_PID_FILE"
wait "$child"
EOF
  cat > "$writer_bin" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat > "$FAKE_WRITER_RECEIVED_FILE"
printf '%s\n' \
  "kc_license=${kc_license+set}" \
  "kc_vault=${kc_vault+set}" \
  "KC_LICENSE=${KC_LICENSE+set}" \
  "KC_VAULT=${KC_VAULT+set}" \
  > "$FAKE_WRITER_ENV_FILE"
printf '%s\n' "$$" > "$FAKE_WRITER_PID_FILE"
while [ -e "$FAKE_WRITER_HOLD_FILE" ]; do
  sleep 0.05
done
EOF
  chmod +x "$timeout_bin" "$writer_bin"
  : > "$hold_file"
  export FAKE_TIMEOUT_PID_FILE="$timeout_pid_file"
  export FAKE_WRITER_PID_FILE="$writer_pid_file"
  export FAKE_WRITER_RECEIVED_FILE="$received_file"
  export FAKE_WRITER_ENV_FILE="$writer_env_file"
  export FAKE_WRITER_HOLD_FILE="$hold_file"
  export kc_license="$sentinel" kc_vault="$sentinel"
  export KC_LICENSE="$sentinel" KC_VAULT="$sentinel"
  set -a

  # shellcheck source=/dev/null
  source "$helper"
  declare -F shottr_defaults_write_stdin >/dev/null \
    || fail "Shottr secret writer must expose the stdin-only public seam"
  SHOTTR_DEFAULTS_WRITES_BLOCKED=0
  (
    shottr_defaults_write_stdin \
      "$timeout_bin" "$writer_bin" "$sandbox/preferences" kc-license \
      < <(builtin printf '%s' "$sentinel")
  ) > "$output" 2>&1 &
  call_pid=$!

  for _ in {1..100}; do
    [ -s "$timeout_pid_file" ] && [ -s "$writer_pid_file" ] && break
    sleep 0.05
  done
  [ -s "$timeout_pid_file" ] && [ -s "$writer_pid_file" ] \
    || fail "stdin writer fixture did not expose live supervisor and writer PIDs"
  timeout_pid="$(cat "$timeout_pid_file")"
  writer_pid="$(cat "$writer_pid_file")"

  for pid in "$timeout_pid" "$writer_pid"; do
    while IFS= read -r -d '' arg; do
      case "$arg" in
        *"$sentinel"*) fail "secret sentinel leaked into process argv for PID $pid" ;;
      esac
    done < <("$CLAUDE_RC_REAL_PID_ARGV_HELPER" "$pid")
  done

  received="$(cat "$received_file")"
  [ "$received" = "$sentinel" ] || fail "stdin writer changed secret bytes"
  [ "$(cat "$writer_env_file")" = $'kc_license=\nkc_vault=\nKC_LICENSE=\nKC_VAULT=' ] \
    || fail "stdin writer inherited a secret-bearing activation variable"
  set +a
  unset kc_license kc_vault KC_LICENSE KC_VAULT
  rm -f "$hold_file"
  wait "$call_pid"
  call_pid=""
  trap - EXIT
)

test_shottr_license_refresh_helper_scrubs_child_environment() (
  local sandbox helper deadlines mutant_script fake_bin
  local defaults_bin nix_bin timeout_bin real_timeout output leak_log trace_log observed status
  local SHOTTR_DEFAULTS_KILL_AFTER SHOTTR_DEFAULTS_DEADLINE
  sandbox="$(new_sandbox)"
  helper="$REPO_ROOT/scripts/secrets/refresh-shottr-license.sh"
  deadlines="$REPO_ROOT/scripts/secrets/shottr-deadlines.sh"
  mutant_script="$sandbox/refresh-shottr-license.mutant.sh"
  fake_bin="$sandbox/bin"
  defaults_bin="$fake_bin/defaults"
  nix_bin="$fake_bin/nix"
  timeout_bin="$sandbox/timeout bin/timeout"
  real_timeout="$(command -v timeout)"
  output="$sandbox/shottr-license.age"
  leak_log="$sandbox/child-environment-leak.log"
  trace_log="$sandbox/xtrace.log"
  mkdir -p "$fake_bin" "$(dirname "$timeout_bin")"

  # shellcheck disable=SC1090 # Repository-root path is supplied by the harness.
  . "$deadlines"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'expected_kill_after=%q\n' "$SHOTTR_DEFAULTS_KILL_AFTER"
    printf 'expected_deadline=%q\n' "$SHOTTR_DEFAULTS_DEADLINE"
    printf 'real_timeout=%q\n' "$real_timeout"
    cat <<'EOF'
[ "$#" -ge 4 ] || exit 97
[ "$1" = "-k" ] || exit 97
[ "$2" = "$expected_kill_after" ] || exit 97
[ "$3" = "$expected_deadline" ] || exit 97
exec "$real_timeout" "$@"
EOF
  } > "$timeout_bin"

  cat > "$defaults_bin" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${kc_license+x}" = x ] \
  || [ "${kc_vault+x}" = x ] \
  || [ "${KC_LICENSE+x}" = x ] \
  || [ "${KC_VAULT+x}" = x ]; then
  printf 'secret-variable-present\n' >> "$FAKE_SHOTTR_LEAK_LOG"
  exit 88
fi
last=""
for arg in "$@"; do
  last="$arg"
done
case "$last" in
  kc-license) printf '%s\n' 'issue-1093-license-sentinel' ;;
  kc-vault) printf '%s\n' 'issue-1093-vault-sentinel' ;;
  *) exit 64 ;;
esac
EOF
  cat > "$nix_bin" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${kc_license+x}" = x ] \
  || [ "${kc_vault+x}" = x ] \
  || [ "${KC_LICENSE+x}" = x ] \
  || [ "${KC_VAULT+x}" = x ]; then
  printf 'secret-variable-present\n' >> "$FAKE_SHOTTR_LEAK_LOG"
  exit 88
fi
output=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$output" ] || exit 64
{
  printf 'fixture-ciphertext\n'
  cat
} > "$output"
EOF
  chmod +x "$defaults_bin" "$nix_bin" "$timeout_bin"

  awk '
    { print }
    /export -n kc_license/ { print "  export kc_license" }
  ' "$helper" > "$mutant_script"
  cp "$deadlines" "$sandbox/shottr-deadlines.sh"
  chmod +x "$mutant_script"

  run_hostile_refresh() {
    local script="$1"
    (
      cd "$REPO_ROOT" || exit 1
      set -a
      export SHELLOPTS
      kc_license='inherited-lower-license-sentinel'
      kc_vault='inherited-lower-vault-sentinel'
      KC_LICENSE='inherited-upper-license-sentinel'
      KC_VAULT='inherited-upper-vault-sentinel'
      env \
        PATH="$fake_bin:$PATH" \
        FAKE_SHOTTR_LEAK_LOG="$leak_log" \
        SHOTTR_DEFAULTS_BIN="$defaults_bin" \
        SHOTTR_AGE_ENCRYPT_ATOMIC="$REPO_ROOT/scripts/secrets/age-encrypt-atomic.sh" \
        SHOTTR_TIMEOUT_BIN="$timeout_bin" \
        PS4='+ ' bash -x "$script" "$output" "$nix_bin" 2> "$trace_log"
    )
  }

  : > "$leak_log"
  run_hostile_refresh "$helper" \
    || fail "Shottr license refresh helper failed under hostile inherited environment"
  [ ! -s "$leak_log" ] \
    || fail "Shottr license refresh helper exposed a secret variable to a child environment"
  assert_contains "$(cat "$trace_log")" "+ set +x"
  assert_not_contains "$(cat "$trace_log")" "issue-1093-license-sentinel"
  assert_not_contains "$(cat "$trace_log")" "issue-1093-vault-sentinel"
  assert_not_contains "$(cat "$trace_log")" "inherited-lower-license-sentinel"
  assert_not_contains "$(cat "$trace_log")" "inherited-lower-vault-sentinel"
  assert_not_contains "$(cat "$trace_log")" "inherited-upper-license-sentinel"
  assert_not_contains "$(cat "$trace_log")" "inherited-upper-vault-sentinel"
  [ -f "$output" ] || fail "Shottr license refresh helper did not produce fixture ciphertext"
  observed="$(cat "$output")"
  assert_contains "$observed" "issue-1093-license-sentinel"
  assert_contains "$observed" "issue-1093-vault-sentinel"

  rm -f "$output"
  : > "$leak_log"
  status=0
  run_hostile_refresh "$mutant_script" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] \
    || fail "secret re-export mutant unexpectedly passed the hostile environment fixture"
  [ -s "$leak_log" ] \
    || fail "hostile environment fixture did not observe the secret re-export mutant"
)

test_shottr_age_encryption_is_atomic() (
  local sandbox helper fake_age output old_ciphertext plaintext observed
  local old_mode old_uid old_gid target target_link target_mode target_uid target_gid
  local top_link absolute_link dangling_link loop_a loop_b loop_status
  local mock_bin metadata_log real_stat real_chmod
  sandbox="$(new_sandbox)"
  helper="$REPO_ROOT/scripts/secrets/age-encrypt-atomic.sh"
  fake_age="$sandbox/fake-age"
  output="$sandbox/shottr-license.age"
  old_ciphertext='existing-ciphertext-fixture'
  plaintext='shottr-plaintext-fixture'

  cat > "$fake_age" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mode="$1"
shift
output=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$output" ] || exit 64
payload="$(cat)"
printf 'encrypted:%s\n' "$payload" > "$output"
[ "$mode" != "fail-after-write" ]
EOF
  chmod +x "$fake_age"
  printf '%s\n' "$old_ciphertext" > "$output"
  chmod 0644 "$output"
  old_mode="$(stat -c '%a' "$output" 2>/dev/null || stat -f '%Lp' "$output")"
  old_uid="$(stat -c '%u' "$output" 2>/dev/null || stat -f '%u' "$output")"
  old_gid="$(stat -c '%g' "$output" 2>/dev/null || stat -f '%g' "$output")"

  if builtin printf '%s' "$plaintext" | "$helper" "$output" "$fake_age" fail-after-write; then
    fail "failing age command unexpectedly replaced ciphertext"
  fi
  observed="$(cat "$output")"
  [ "$observed" = "$old_ciphertext" ] \
    || fail "failed age command changed existing ciphertext"
  if find "$sandbox" -maxdepth 1 -name '.shottr-license.age.tmp.*' -print -quit | grep -q .; then
    fail "failed age command left a plaintext-bearing temporary file"
  fi

  builtin printf '%s' "$plaintext" | "$helper" "$output" "$fake_age" success
  observed="$(cat "$output")"
  [ "$observed" = "encrypted:$plaintext" ] \
    || fail "successful age command did not atomically replace ciphertext"
  [ "$(stat -c '%a' "$output" 2>/dev/null || stat -f '%Lp' "$output")" = "$old_mode" ] \
    || fail "atomic replacement changed an existing output mode"
  [ "$(stat -c '%u' "$output" 2>/dev/null || stat -f '%u' "$output")" = "$old_uid" ] \
    || fail "atomic replacement changed an existing output owner"
  [ "$(stat -c '%g' "$output" 2>/dev/null || stat -f '%g' "$output")" = "$old_gid" ] \
    || fail "atomic replacement changed an existing output group"
  if find "$sandbox" -maxdepth 1 -name '.shottr-license.age.tmp.*' -print -quit | grep -q .; then
    fail "successful age command left a temporary file"
  fi

  mkdir -p "$sandbox/target"
  target="$sandbox/target/shottr-license.age"
  target_link="$sandbox/shottr-license-link.age"
  printf '%s\n' "$old_ciphertext" > "$target"
  chmod 0640 "$target"
  ln -s 'target/shottr-license.age' "$target_link"
  target_mode="$(stat -c '%a' "$target" 2>/dev/null || stat -f '%Lp' "$target")"
  target_uid="$(stat -c '%u' "$target" 2>/dev/null || stat -f '%u' "$target")"
  target_gid="$(stat -c '%g' "$target" 2>/dev/null || stat -f '%g' "$target")"

  builtin printf '%s' "$plaintext" | "$helper" "$target_link" "$fake_age" success
  [ -L "$target_link" ] || fail "atomic replacement replaced the output symlink"
  [ "$(readlink "$target_link")" = 'target/shottr-license.age' ] \
    || fail "atomic replacement changed the output symlink target"
  [ "$(cat "$target")" = "encrypted:$plaintext" ] \
    || fail "atomic replacement did not update the symlink target"
  [ "$(stat -c '%a' "$target" 2>/dev/null || stat -f '%Lp' "$target")" = "$target_mode" ] \
    || fail "symlink target replacement changed mode"
  [ "$(stat -c '%u' "$target" 2>/dev/null || stat -f '%u' "$target")" = "$target_uid" ] \
    || fail "symlink target replacement changed owner"
  [ "$(stat -c '%g' "$target" 2>/dev/null || stat -f '%g' "$target")" = "$target_gid" ] \
    || fail "symlink target replacement changed group"

  top_link="$sandbox/shottr-license-top.age"
  ln -s 'shottr-license-link.age' "$top_link"
  if builtin printf '%s' 'must-not-replace' \
      | "$helper" "$top_link" "$fake_age" fail-after-write; then
    fail "failing age command unexpectedly replaced a multi-hop symlink target"
  fi
  [ -L "$top_link" ] && [ -L "$target_link" ] \
    || fail "failing age command replaced a symlink hop"
  [ "$(cat "$target")" = "encrypted:$plaintext" ] \
    || fail "failing age command changed a multi-hop symlink target"
  if find "$(dirname "$target")" -maxdepth 1 -name '.shottr-license.age.tmp.*' \
      -print -quit | grep -q .; then
    fail "failing multi-hop replacement left a target-directory temporary file"
  fi

  absolute_link="$sandbox/shottr-license-absolute.age"
  ln -s "$top_link" "$absolute_link"
  builtin printf '%s' 'absolute-hop-payload' \
    | "$helper" "$absolute_link" "$fake_age" success
  [ -L "$absolute_link" ] && [ "$(readlink "$absolute_link")" = "$top_link" ] \
    || fail "atomic replacement changed an absolute symlink hop"
  [ "$(cat "$target")" = 'encrypted:absolute-hop-payload' ] \
    || fail "atomic replacement did not update the absolute multi-hop target"

  dangling_link="$sandbox/shottr-license-dangling.age"
  ln -s 'target/new-shottr-license.age' "$dangling_link"
  builtin printf '%s' "$plaintext" | "$helper" "$dangling_link" "$fake_age" success
  [ -L "$dangling_link" ] \
    || fail "atomic replacement replaced a dangling output symlink"
  [ "$(cat "$sandbox/target/new-shottr-license.age")" = "encrypted:$plaintext" ] \
    || fail "atomic replacement did not create the dangling symlink target"
  [ "$(stat -c '%a' "$sandbox/target/new-shottr-license.age" 2>/dev/null \
      || stat -f '%Lp' "$sandbox/target/new-shottr-license.age")" = "600" ] \
    || fail "new dangling symlink target did not retain restrictive mode"

  loop_a="$sandbox/loop-a.age"
  loop_b="$sandbox/loop-b.age"
  ln -s 'loop-b.age' "$loop_a"
  ln -s 'loop-a.age' "$loop_b"
  loop_status=0
  builtin printf '%s' "$plaintext" \
    | "$helper" "$loop_a" "$fake_age" success >/dev/null 2>&1 \
    || loop_status=$?
  [ "$loop_status" = "74" ] || fail "symlink loop returned $loop_status instead of 74"
  [ -L "$loop_a" ] && [ -L "$loop_b" ] \
    || fail "symlink loop handling replaced an output link"
  if find "$sandbox" -maxdepth 2 -name '.*.tmp.*' -print -quit | grep -q .; then
    fail "symlink loop handling left a temporary file"
  fi

  # Exercise the ownership-change branch without requiring root. The mock stat
  # reports distinct target/temp ownership, while mock chown records success;
  # chmod must run afterward because a real chown may clear special mode bits.
  mock_bin="$sandbox/metadata-bin"
  metadata_log="$sandbox/metadata.log"
  real_stat="$(command -v stat)"
  real_chmod="$(command -v chmod)"
  mkdir -p "$mock_bin"
  cat > "$mock_bin/stat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "-c" ] && [ "${2:-}" = "%u" ]; then
  case "$3" in *.tmp.*) echo 222 ;; *) echo 111 ;; esac
  exit 0
fi
if [ "${1:-}" = "-c" ] && [ "${2:-}" = "%g" ]; then
  case "$3" in *.tmp.*) echo 444 ;; *) echo 333 ;; esac
  exit 0
fi
exec "$REAL_STAT" "$@"
EOF
  cat > "$mock_bin/chown" <<'EOF'
#!/usr/bin/env bash
printf 'chown\n' >> "$METADATA_LOG"
EOF
  cat > "$mock_bin/chmod" <<'EOF'
#!/usr/bin/env bash
printf 'chmod\n' >> "$METADATA_LOG"
exec "$REAL_CHMOD" "$@"
EOF
  chmod +x "$mock_bin/stat" "$mock_bin/chown" "$mock_bin/chmod"
  : > "$metadata_log"
  builtin printf '%s' "$plaintext" | env \
    PATH="$mock_bin:$PATH" \
    REAL_STAT="$real_stat" \
    REAL_CHMOD="$real_chmod" \
    METADATA_LOG="$metadata_log" \
    "$helper" "$output" "$fake_age" success
  [ "$(cat "$metadata_log")" = $'chown\nchmod' ] \
    || fail "atomic replacement did not restore mode after ownership"
)

test_shottr_cfpreferences_writer_round_trip() {
  local sandbox writer source target key sentinel timeout_bin observed
  if [ "$(uname -s)" != "Darwin" ]; then
    printf 'N/A: Shottr CFPreferences writer fixture requires Darwin; runner=%s\n' "$(uname -s)"
    return 0
  fi

  sandbox="$(new_sandbox)"
  writer="$sandbox/shottr-cfpreferences-writer"
  source="$REPO_ROOT/modules/darwin/programs/shottr/cfpreferences-writer.c"
  target="$sandbox/issue-1093-preferences"
  key="fixture-key"
  sentinel='issue-1093-cfpreferences-value'
  timeout_bin="$(command -v timeout)" || fail "GNU timeout is required"

  [ -f "$source" ] || fail "Shottr CFPreferences writer source is missing"
  cc -std=c11 -O2 -Wall -Wextra -Werror \
    "$source" -framework CoreFoundation -o "$writer"
  builtin printf '%s' "$sentinel" | "$writer" "$target" "$key"
  observed="$(
    "$timeout_bin" -k 2s 10s /usr/bin/defaults read "$target" "$key" 2>/dev/null
  )" || fail "CFPreferences writer value was not readable through defaults"
  [ "$observed" = "$sentinel" ] || fail "CFPreferences writer round-trip mismatch"
  "$timeout_bin" -k 2s 10s /usr/bin/defaults delete "$target" "$key" >/dev/null 2>&1 \
    || fail "CFPreferences fixture cleanup failed"
}
