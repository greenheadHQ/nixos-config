# tests/suites/claude-remote-control-wrapper.sh — Claude Remote Control fixtures
# shellcheck shell=bash
# shellcheck disable=SC1091,SC2016,SC2030,SC2031,SC2034,SC2154,SC2164
# shellcheck source=../lib/claude-remote-control-fixtures.sh
. "$SCRIPT_DIR/lib/claude-remote-control-fixtures.sh"

test_claude_remote_control_nix_packages_include_pinned_runtime_helpers() {
  local eval_json flock_drv flock_output_name flock_output pid_argv_drv pid_argv_output pid_argv_status
  local drv package_name output launch_group_output launch_group_count launch_group_status
  local closure index=0
  local -a package_names=(claude-rc claude-rc-maint)
  eval_json="$(
    cd "$REPO_ROOT"
    nix eval --impure --json --expr '
      let
        f = builtins.getFlake (toString ./.);
        pkgs = f.inputs.nixpkgs.legacyPackages.${builtins.currentSystem};
        selectedFlock = import ./libraries/claude-rc-flock.nix { inherit pkgs; };
        controlEnvironment = {
          CLAUDE_RC_BRIDGE_PATH = "/contract/headless-dispatcher/bin:/contract/home/.local/bin";
          CLAUDE_RC_HEADLESS_SSH_MARKER = "1";
          CLAUDE_RC_ENVIRONMENT_GENERATION = "fixture-environment-generation";
        };
      in
      {
        packages = map (package: package.drvPath) [
          (import ./modules/nixos/lib/claude-rc-package.nix { inherit pkgs controlEnvironment; })
          (import ./modules/nixos/lib/claude-rc-maint-package.nix { inherit pkgs controlEnvironment; })
        ];
        flock = {
          inherit (selectedFlock) drvPath outputName;
        };
        pidArgv = (import ./modules/nixos/lib/claude-rc-pid-argv-package.nix { inherit pkgs; }).drvPath;
      }
    '
  )" || fail "could not evaluate Claude RC wrapper derivations"
  flock_drv="$(jq -r '.flock.drvPath' <<< "$eval_json")"
  flock_output_name="$(jq -r '.flock.outputName' <<< "$eval_json")"
  flock_output="$(nix build --no-link --print-out-paths "$flock_drv^$flock_output_name")" \
    || fail "could not build selected Claude RC flock"
  [ -x "$flock_output/bin/flock" ] \
    || fail "selected Claude RC flock is not executable"
  pid_argv_drv="$(jq -r '.pidArgv' <<< "$eval_json")"
  pid_argv_output="$(nix build --no-link --print-out-paths "$pid_argv_drv^out")" \
    || fail "could not build Claude RC PID argv helper"
  [ -x "$pid_argv_output/bin/claude-rc-pid-argv" ] \
    || fail "Claude RC PID argv helper is not executable"
  pid_argv_status=0
  "$pid_argv_output/bin/claude-rc-pid-argv" >/dev/null 2>&1 || pid_argv_status=$?
  [ "$pid_argv_status" = "2" ] \
    || fail "Claude RC PID argv helper smoke returned $pid_argv_status instead of usage status"

  while IFS= read -r drv; do
    package_name="${package_names[$index]}"
    output="$(nix build --no-link --print-out-paths "$drv^out")" \
      || fail "could not build $package_name"
    closure="$(nix-store -qR "$output")" \
      || fail "could not inspect $package_name closure"
    launch_group_output="$(
      grep -E -- '-claude-rc-launch-group-1$' <<< "$closure" || true
    )"
    launch_group_count="$(printf '%s\n' "$launch_group_output" | grep -c . || true)"
    [ "$launch_group_count" = "1" ] \
      || fail "$package_name closure must contain exactly one launch-group helper"
    [ -x "$launch_group_output/bin/claude-rc-launch-group" ] \
      || fail "$package_name launch-group helper is not executable"
    grep -Fq "$launch_group_output/bin" "$output/bin/$package_name" \
      || fail "$package_name runtime PATH omits the launch-group helper"
    [ "$(grep -Fxc "$pid_argv_output" <<< "$closure" || true)" = "1" ] \
      || fail "$package_name closure must contain the exact PID argv helper once"
    grep -Fq "$pid_argv_output/bin" "$output/bin/$package_name" \
      || fail "$package_name runtime PATH omits the PID argv helper"
    grep -Fxq "$flock_output" <<< "$closure" \
      || fail "$package_name closure omits the selected Claude RC flock"
    grep -Fq "$flock_output/bin" "$output/bin/$package_name" \
      || fail "$package_name runtime PATH omits the selected Claude RC flock"
    grep -Fq 'export CLAUDE_RC_BRIDGE_PATH=/contract/headless-dispatcher/bin:/contract/home/.local/bin' \
      "$output/bin/$package_name" \
      || fail "$package_name omits the evaluated bridge PATH binding"
    grep -Fq 'export CLAUDE_RC_HEADLESS_SSH_MARKER=1' "$output/bin/$package_name" \
      || fail "$package_name omits the evaluated headless SSH marker"
    grep -Fq 'export CLAUDE_RC_ENVIRONMENT_GENERATION=fixture-environment-generation' \
      "$output/bin/$package_name" \
      || fail "$package_name omits the evaluated environment generation"
    launch_group_status=0
    "$launch_group_output/bin/claude-rc-launch-group" >/dev/null 2>&1 \
      || launch_group_status=$?
    [ "$launch_group_status" = "$CLAUDE_RC_LAUNCH_GROUP_STATUS_USAGE" ] \
      || fail "$package_name launch-group smoke returned $launch_group_status instead of usage status"
    index=$((index + 1))
  done < <(jq -r '.packages[]' <<< "$eval_json")
  [ "$index" = "${#package_names[@]}" ] \
    || fail "Claude RC package evaluation returned $index wrappers"
}

test_claude_remote_control_darwin_binding_is_single_generation() {
  local result
  result="$({
    cd "$REPO_ROOT"
    nix eval --impure --json --expr '
      let
        f = builtins.getFlake (toString ./.);
        mk = hostName: expectedMarker:
          let
            d = f.darwinConfigurations.${hostName};
            cfg = d.config;
            pkgs = d.pkgs;
            lib = f.inputs.nixpkgs.lib;
            hm = cfg.home-manager.users.${cfg.system.primaryUser};
            agent = hm.launchd.agents.claude-rc-ensure.config;
            agentEnv = agent.EnvironmentVariables;
            pathEntries = lib.splitString ":" agentEnv.PATH;
            dispatcher = {
              enabled = expectedMarker == "1";
              homeDir = hm.home.homeDirectory;
              binPath = if expectedMarker == "1" then builtins.head pathEntries else "/disabled";
            };
            expected = import ./modules/darwin/programs/claude-remote-control-launch-environment.nix {
              inherit pkgs lib;
              hostType = if expectedMarker == "1" then "personal" else "work";
              headlessDispatcher = dispatcher;
            };
            rc = import ./modules/nixos/lib/claude-rc-package.nix {
              inherit pkgs;
              controlEnvironment = expected.controlEnvironment;
            };
            maint = import ./modules/nixos/lib/claude-rc-maint-package.nix {
              inherit pkgs;
              controlEnvironment = expected.controlEnvironment;
            };
          in {
            constructorMatches = expected.controlEnvironment == {
              CLAUDE_RC_BRIDGE_PATH = agentEnv.CLAUDE_RC_BRIDGE_PATH;
              CLAUDE_RC_HEADLESS_SSH_MARKER = agentEnv.CLAUDE_RC_HEADLESS_SSH_MARKER;
              CLAUDE_RC_ENVIRONMENT_GENERATION = agentEnv.CLAUDE_RC_ENVIRONMENT_GENERATION;
            };
            pathMatches = agentEnv.PATH == expected.bridgePath;
            rcSourceMatches = toString hm.home.file.".local/bin/claude-rc".source == "${rc}/bin/claude-rc";
            maintSourceMatches = toString hm.home.file.".local/bin/claude-rc-maint".source == "${maint}/bin/claude-rc-maint";
            launchdMatchesMaint = builtins.elemAt agent.ProgramArguments 0 == "${maint}/bin/claude-rc-maint";
            marker = expected.marker;
          };
      in {
        personal = mk "greenhead-MacBookPro" "1";
        work = mk "work-MacBookPro" "0";
      }
    '
  } 2>&1)" || fail "could not evaluate Darwin Claude launch binding: $result"

  jq -e '
    all(.personal, .work;
      .constructorMatches
      and .pathMatches
      and .rcSourceMatches
      and .maintSourceMatches
      and .launchdMatchesMaint)
    and .personal.marker == "1"
    and .work.marker == "0"
  ' <<<"$result" >/dev/null \
    || fail "Darwin Claude launch binding generation mismatch: $result"
}


test_claude_remote_control_start_requires_git_repo() {
  local sandbox out rc
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  mkdir -p "$sandbox/not-repo"

  rc=0
  out="$(_claude_rc_run "$sandbox/not-repo" bash "$(_claude_rc_wrapper_script)" start 2>&1)" || rc=$?
  [ "$rc" -eq 1 ] || fail "start outside git repo should exit 1, got $rc: $out"
  assert_contains "$out" "git repo가 아님"
}

test_claude_remote_control_readlink_fixture_preserves_canonicalization() {
  local sandbox target link resolved
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  target="$sandbox/canonical-target"
  link="$sandbox/symlink"
  mkdir -p "$target"
  ln -s "$target" "$link"

  resolved="$(FAKE_CLAUDE_RESOLVED_EXE='' CLAUDE_BIN='' "$CLAUDE_RC_FAKE_BIN/readlink" -f "$link")"
  [ "$resolved" = "$target" ] \
    || fail "non-Claude readlink -f must preserve real canonicalization: $resolved"
}

test_claude_remote_control_fixture_uses_trusted_flock() {
  local sandbox shadow
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox/runtime"
  case "$(uname -s):$CLAUDE_RC_REAL_FLOCK" in
    Darwin:/nix/store/*-flock-*/bin/flock | Linux:/nix/store/*-util-linux-*/bin/flock) ;;
    *) fail "fixture must use the pinned trusted flock: $CLAUDE_RC_REAL_FLOCK" ;;
  esac

  shadow="$sandbox/untrusted-bin"
  mkdir -p "$shadow"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$shadow/flock"
  chmod +x "$shadow/flock"
  if PATH="$shadow:$PATH" _claude_rc_find_trusted_flock >/dev/null; then
    fail "fixture must reject an ambient untrusted flock instead of scanning the store"
  fi
}

test_claude_remote_control_start_registers_manual_instance() {
  local sandbox repo wrapper lock_path lifecycle_lock_path status out guardian_present
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  : > "$CLAUDE_RC_HOLD_FILE"
  wrapper="$(_claude_rc_wrapper_script)"

  out="$(_claude_rc_run "$repo" bash "$wrapper" start)"
  assert_contains "$out" "verified: pid="
  assert_contains "$out" "version=claude-server"
  guardian_present=true
  for _ in {1..200}; do
    if ! _claude_rc_has_process_with_exact_argv_token "$wrapper"; then
      guardian_present=false
      break
    fi
    sleep 0.05
  done
  if "$guardian_present"; then
    fail "successful start must hand off and exit its launcher guardian"
  fi
  lock_path="$CLAUDE_RC_STATE/$(_claude_rc_slug "$repo")/lock"
  if "$CLAUDE_RC_FAKE_BIN/flock" -n "$lock_path" true; then
    fail "server lock should be held after successful start"
  fi
  lifecycle_lock_path="$CLAUDE_RC_STATE/ensure.lock"
  "$CLAUDE_RC_FAKE_BIN/flock" --timeout 1 "$lifecycle_lock_path" true \
    || fail "detached server must not inherit the shared lifecycle lock"

  status="$(cat "$CLAUDE_RC_STATE/instances.json")"
  jq -e --arg path "$repo" '
    .version == 1
    and .instances[$path].spawn == "worktree"
    and .instances[$path].capacity == null
    and .instances[$path].permissionMode == "bypassPermissions"
    and .instances[$path].source == "manual"
  ' <<<"$status" >/dev/null || fail "manual instance schema mismatch: $status"

  _claude_rc_release_server "$repo"
}

test_claude_remote_control_start_accepts_late_guard_handoff() (
  local sandbox repo wrapper lock_path real_ps out status
  local ready_file release_file once_dir
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  wrapper="$(_claude_rc_wrapper_script)"
  lock_path="$CLAUDE_RC_STATE/$(_claude_rc_slug "$repo")/lock"
  real_ps="$(_claude_rc_find_tool ps)" || fail "late-handoff fixture requires ps"
  ready_file="$sandbox/handoff-entered"
  release_file="$sandbox/release-handoff"
  once_dir="$sandbox/handoff-ps-once"

  {
    printf '#!/usr/bin/env bash\nREAL_PS=%q\n' "$real_ps"
    cat <<'EOS'
set -euo pipefail
if [ "${1:-}" = "-o" ] && [ "${2:-}" = "pgid=" ] \
    && mkdir "$FAKE_HANDOFF_ONCE_DIR" 2>/dev/null; then
  : > "$FAKE_HANDOFF_READY_FILE"
  for _ in {1..500}; do
    [ -e "$FAKE_HANDOFF_RELEASE_FILE" ] && break
    sleep 0.01
  done
  [ -e "$FAKE_HANDOFF_RELEASE_FILE" ] || exit 75
fi
exec "$REAL_PS" "$@"
EOS
  } > "$CLAUDE_RC_FAKE_BIN/ps"
  chmod +x "$CLAUDE_RC_FAKE_BIN/ps"

  : > "$CLAUDE_RC_HOLD_FILE"
  # shellcheck disable=SC2329 # invoked indirectly by the EXIT trap
  cleanup_late_handoff_fixture() {
    : > "$release_file"
    rm -f "$CLAUDE_RC_HOLD_FILE"
    _claude_rc_wait_lock_free "$lock_path" || true
  }
  trap cleanup_late_handoff_fixture EXIT

  out="$(_claude_rc_run "$repo" env \
    LAUNCH_GUARD_ACK_ATTEMPTS=0 \
    LAUNCH_GUARD_ACK_INTERVAL_SECONDS=0.01 \
    FAKE_HANDOFF_READY_FILE="$ready_file" \
    FAKE_HANDOFF_RELEASE_FILE="$release_file" \
    FAKE_HANDOFF_ONCE_DIR="$once_dir" \
    bash -c '
      set -euo pipefail
      # shellcheck source=/dev/null
      source "$1"
      kill() {
        local signal="${1:-}" target="${2:-}" result=0 attempt
        builtin kill "$@" || result=$?
        if [ "$signal" = "-USR1" ] && [ ! -e "$FAKE_HANDOFF_READY_FILE" ]; then
          for ((attempt = 0; attempt < 500; attempt++)); do
            [ -e "$FAKE_HANDOFF_READY_FILE" ] && break
            sleep 0.01
          done
          [ -e "$FAKE_HANDOFF_READY_FILE" ] || return 76
        elif [ "$signal" = "-TERM" ] \
            && [ -e "$FAKE_HANDOFF_READY_FILE" ] \
            && [ ! -e "$FAKE_HANDOFF_RELEASE_FILE" ]; then
          : > "$FAKE_HANDOFF_RELEASE_FILE"
          for ((attempt = 0; attempt < 500; attempt++)); do
            if ! builtin kill -0 "$target" 2>/dev/null \
                || pid_is_zombie_process "$target"; then
              return "$result"
            fi
            sleep 0.01
          done
          return 77
        fi
        return "$result"
      }
      main start
    ' _ "$wrapper" 2>&1)" \
    || fail "late verified handoff must keep interactive start successful: $out"
  [ -e "$ready_file" ] || fail "late-handoff fixture did not enter the handoff critical section"
  [ -e "$release_file" ] || fail "late-handoff fixture did not cross the first acknowledgement deadline"
  assert_contains "$out" "서버 시작됨:"
  assert_contains "$out" "verified: pid="
  if "$CLAUDE_RC_FAKE_BIN/flock" -n "$lock_path" true; then
    fail "late handoff must leave the verified server running"
  fi

  status="$(cat "$CLAUDE_RC_STATE/instances.json")"
  jq -e --arg path "$repo" '
    .version == 1
    and .instances[$path].spawn == "worktree"
    and .instances[$path].permissionMode == "bypassPermissions"
    and .instances[$path].source == "manual"
  ' <<<"$status" >/dev/null \
    || fail "late handoff must register the live manual bridge: $status"

  _claude_rc_release_server "$repo"
  trap - EXIT
)

test_claude_remote_control_start_tolerates_bounded_scheduler_delay() (
  local sandbox repo wrapper launch_group_wrapper out
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  wrapper="$(_claude_rc_wrapper_script)"
  launch_group_wrapper="$CLAUDE_RC_FAKE_BIN/claude-rc-launch-group"
  : > "$CLAUDE_RC_HOLD_FILE"
  trap 'rm -f "$CLAUDE_RC_HOLD_FILE"' EXIT
  unlink "$launch_group_wrapper"
  {
    printf '#!/usr/bin/env bash\nREAL_LAUNCH_GROUP=%q\n' "$CLAUDE_RC_REAL_LAUNCH_GROUP_HELPER"
    cat <<'EOS'
set -euo pipefail
sleep "${FAKE_LAUNCH_GROUP_START_DELAY_SECONDS:?}"
exec "$REAL_LAUNCH_GROUP" "$@"
EOS
  } > "$launch_group_wrapper"
  chmod +x "$launch_group_wrapper"

  export FAKE_LAUNCH_GROUP_START_DELAY_SECONDS=1.2
  export FAKE_CLAUDE_START_DELAY_SECONDS=3.5
  out="$(_claude_rc_run "$repo" bash "$wrapper" start 2>&1)" \
    || fail "bounded scheduler delay exceeded the startup contract: $out"
  assert_contains "$out" "verified: pid="
  _claude_rc_release_server "$repo"
  unset FAKE_LAUNCH_GROUP_START_DELAY_SECONDS FAKE_CLAUDE_START_DELAY_SECONDS
  trap - EXIT
)

test_claude_remote_control_interactive_lifecycle_actions_share_maint_lock() {
  local sandbox repo copy marker action observed
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  copy="$(_claude_rc_wrapper_script)"

  for action in start stop; do
    marker="$sandbox/${action}-lifecycle-lock"
    # shellcheck disable=SC2016 # Variables intentionally expand in the nested Bash process.
    _claude_rc_run "$repo" bash -c '
      set -euo pipefail
      # shellcheck source=/dev/null
      . "$1"
      marker="$2"
      assert_lifecycle_lock_held() {
        if flock -n "$STATE_DIR/ensure.lock" true; then
          echo "shared lifecycle lock was not held for $ACTION" >&2
          return 70
        fi
        printf "%s\n" "$ACTION" > "$marker"
      }
      do_start() { assert_lifecycle_lock_held; }
      do_stop() { assert_lifecycle_lock_held; }
      main "$3"
    ' _ "$copy" "$marker" "$action"
    observed="$(cat "$marker")"
    [ "$observed" = "$action" ] \
      || fail "$action callback did not run inside the shared lifecycle lock: $observed"
  done
}

test_claude_remote_control_interactive_lifecycle_propagates_callback_failures() {
  local sandbox repo copy out rc marker lifecycle_lock_path
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  copy="$(_claude_rc_wrapper_script)"
  lifecycle_lock_path="$CLAUDE_RC_STATE/ensure.lock"
  : > "$CLAUDE_RC_HOLD_FILE"

  rc=0
  # shellcheck disable=SC2016 # Variables intentionally expand in nested Bash.
  out="$(_claude_rc_run "$repo" bash -c '
    set -euo pipefail
    # shellcheck source=/dev/null
    source "$1"
    upsert_instance() { return 71; }
    main start
  ' _ "$copy" 2>&1)" || rc=$?
  [ "$rc" -eq 71 ] || fail "registry failure must escape lifecycle callback, got $rc: $out"
  assert_not_contains "$out" "서버 시작됨"
  "$CLAUDE_RC_FAKE_BIN/flock" --timeout 1 "$lifecycle_lock_path" true \
    || fail "start callback failure must release lifecycle lock"
  _claude_rc_release_server "$repo"

  marker="$sandbox/remove-called"
  rc=0
  # shellcheck disable=SC2016 # Variables intentionally expand in nested Bash.
  out="$(_claude_rc_run "$repo" bash -c '
    set -euo pipefail
    # shellcheck source=/dev/null
    source "$1"
    marker="$2"
    stop_target_path() { return 72; }
    remove_instance() { printf "%s\n" called > "$marker"; }
    main stop
  ' _ "$copy" "$marker" 2>&1)" || rc=$?
  [ "$rc" -eq 72 ] || fail "stop target failure must escape lifecycle callback, got $rc: $out"
  [ ! -e "$marker" ] || fail "stop must not unregister after target resolution failure"
  "$CLAUDE_RC_FAKE_BIN/flock" --timeout 1 "$lifecycle_lock_path" true \
    || fail "stop callback failure must release lifecycle lock"
}

test_claude_remote_control_interactive_registry_lock_failure_prevents_callback() {
  local sandbox repo copy out rc marker lifecycle_lock_path
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  copy="$(_claude_rc_wrapper_script)"
  marker="$sandbox/registry-callback-ran"
  lifecycle_lock_path="$CLAUDE_RC_STATE/ensure.lock"
  : > "$CLAUDE_RC_HOLD_FILE"
  _claude_rc_install_instances_lock_failure_flock

  rc=0
  out="$(_claude_rc_run "$repo" bash -c '
    set -euo pipefail
    # shellcheck source=/dev/null
    source "$1"
    marker="$2"
    upsert_instance_unlocked() { printf "%s\n" called > "$marker"; }
    main start
  ' _ "$copy" "$marker" 2>&1)" || rc=$?
  [ "$rc" -eq 73 ] || fail "instances lock failure must escape lifecycle callback, got $rc: $out"
  [ ! -e "$marker" ] || fail "registry callback must not run without instances lock"
  "$CLAUDE_RC_FAKE_BIN/flock" --timeout 1 "$lifecycle_lock_path" true \
    || fail "instances lock failure must still release lifecycle lock"
  _claude_rc_release_server "$repo"
}

test_claude_remote_control_interactive_start_requires_verified_managed_identity() {
  local mode sandbox repo out rc lock_path

  for mode in no-process unresolvable outside-versions; do
    sandbox="$(_claude_rc_new_sandbox)"
    _claude_rc_setup "$sandbox"
    repo="$sandbox/repo"
    _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
    : > "$CLAUDE_RC_HOLD_FILE"
    case "$mode" in
      no-process) _claude_rc_install_no_process_mocks ;;
      unresolvable) FAKE_CLAUDE_STARTED_EXE=UNRESOLVABLE ;;
      outside-versions) FAKE_CLAUDE_STARTED_EXE="$sandbox/outside/claude" ;;
    esac

    rc=0
    out="$(_claude_rc_run "$repo" env \
      STARTED_IDENTITY_POLL_ATTEMPTS=2 \
      STARTED_IDENTITY_POLL_INTERVAL_SECONDS=0.01 \
      FAKE_CLAUDE_STARTED_EXE="${FAKE_CLAUDE_STARTED_EXE:-$CLAUDE_RC_SERVER_EXE}" \
      bash "$(_claude_rc_wrapper_script)" start 2>&1)" || rc=$?
    unset FAKE_CLAUDE_STARTED_EXE
    [ "$rc" -ne 0 ] || fail "interactive start must reject unverified identity ($mode): $out"
    assert_contains "$out" "identity를 확인하지 못함"
    if [ -f "$CLAUDE_RC_STATE/instances.json" ]; then
      jq -e --arg path "$repo" '(.instances | has($path)) | not' \
        "$CLAUDE_RC_STATE/instances.json" >/dev/null \
        || fail "unverified start must not register ($mode)"
    fi
    lock_path="$CLAUDE_RC_STATE/$(_claude_rc_slug "$repo")/lock"
    _claude_rc_release_server "$repo"
    "$CLAUDE_RC_FAKE_BIN/flock" -n "$lock_path" true \
      || fail "fixture cleanup failed after unverified start ($mode)"
  done
}

test_claude_remote_control_interactive_start_ignores_ambient_claude_bin() {
  local sandbox repo log
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  : > "$CLAUDE_RC_HOLD_FILE"

  CLAUDE_BIN="$CLAUDE_RC_MANAGED_BIN/claude" \
    _claude_rc_run "$repo" bash "$(_claude_rc_wrapper_script)" start >/dev/null
  _claude_rc_wait_fake_claude_log "remote-control --spawn worktree" \
    || fail "interactive fake claude log did not appear"
  log="$(cat "$CLAUDE_RC_LOG")"
  assert_contains "$log" $'\t'"$CLAUDE_RC_FAKE_BIN/claude"$'\tremote-control'
  assert_not_contains "$log" "$CLAUDE_RC_MANAGED_BIN/claude"

  _claude_rc_release_server "$repo"
}

test_claude_remote_control_start_resolves_claude_from_bridge_path() {
  local sandbox repo bridge_dir original_claude bash_bin log
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  bridge_dir="$sandbox/bridge-bin"
  original_claude="$CLAUDE_RC_FAKE_BIN/claude"
  bash_bin="$(command -v bash)"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  mkdir -p "$bridge_dir"
  : > "$CLAUDE_RC_HOLD_FILE"

  mv "$original_claude" "$bridge_dir/claude"
  trap 'mv "$bridge_dir/claude" "$original_claude" 2>/dev/null || true; rm -f "$CLAUDE_RC_HOLD_FILE"' RETURN
  CLAUDE_RC_BRIDGE_PATH="$bridge_dir:$CLAUDE_RC_FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    _claude_rc_run "$repo" env \
      PATH="$CLAUDE_RC_FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
      "$bash_bin" "$(_claude_rc_wrapper_script)" start >/dev/null
  _claude_rc_wait_fake_claude_log "remote-control --spawn worktree" \
    || fail "bridge-path Claude launcher log did not appear"
  log="$(cat "$CLAUDE_RC_LOG")"
  assert_contains "$log" $'\t'"$bridge_dir/claude"$'\tremote-control'

  _claude_rc_release_server "$repo"
  mv "$bridge_dir/claude" "$original_claude"
  trap - RETURN
}

test_claude_remote_control_managed_attestation_lifecycle() {
  local sandbox repo slug attestation status
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  slug="$(_claude_rc_slug "$repo")"
  attestation="$CLAUDE_RC_STATE/$slug/environment-attestation.json"
  : > "$CLAUDE_RC_HOLD_FILE"

  CLAUDE_RC_ENVIRONMENT_GENERATION=environment-current \
  CLAUDE_RC_HEADLESS_SSH_MARKER=1 \
  CLAUDE_RC_BRIDGE_PATH="$CLAUDE_RC_FAKE_BIN:$PATH" \
    _claude_rc_run "$repo" bash "$(_claude_rc_wrapper_script)" start >/dev/null
  jq -e '
    .schemaVersion == 1
    and .environmentGeneration == "environment-current"
    and (.pid | type) == "number"
    and (.processStartIdentity | type) == "string"
  ' "$attestation" >/dev/null || fail "managed start did not publish exact environment attestation"

  CLAUDE_RC_ENVIRONMENT_GENERATION=environment-current \
  CLAUDE_RC_HEADLESS_SSH_MARKER=1 \
  CLAUDE_RC_BRIDGE_PATH="$CLAUDE_RC_FAKE_BIN:$PATH" \
    _claude_rc_run "$repo" bash "$(_claude_rc_wrapper_script)" stop --force >/dev/null
  [ ! -e "$attestation" ] || fail "verified managed stop left a stale environment attestation"
  status="$(cat "$CLAUDE_RC_STATE/instances.json")"
  jq -e --arg path "$repo" '(.instances | has($path)) | not' <<<"$status" >/dev/null \
    || fail "verified managed stop did not unregister instance: $status"
  rm -f "$CLAUDE_RC_HOLD_FILE"
}

test_claude_remote_control_attestation_failures_are_fail_closed() {
  local sandbox repo slug instance_dir attestation out rc lock_path status wrapper

  # Publication failure: an attacker-controlled symlink is never followed and
  # the just-launched server is cancelled before registration.
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  slug="$(_claude_rc_slug "$repo")"
  instance_dir="$CLAUDE_RC_STATE/$slug"
  attestation="$instance_dir/environment-attestation.json"
  lock_path="$instance_dir/lock"
  mkdir -p "$instance_dir"
  ln -s "$sandbox/foreign-attestation" "$attestation"
  : > "$CLAUDE_RC_HOLD_FILE"
  rc=0
  out="$(CLAUDE_RC_ENVIRONMENT_GENERATION=environment-current \
    CLAUDE_RC_HEADLESS_SSH_MARKER=1 \
    CLAUDE_RC_BRIDGE_PATH="$CLAUDE_RC_FAKE_BIN:$PATH" \
    _claude_rc_run "$repo" bash "$(_claude_rc_wrapper_script)" start 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "attestation publication failure must fail start: $out"
  assert_contains "$out" "environment identity를 확인하지 못함"
  [ -L "$attestation" ] || fail "attestation publication failure followed or replaced the symlink"
  "$CLAUDE_RC_FAKE_BIN/flock" --timeout 1 "$lock_path" true \
    || fail "attestation publication failure left the server lock held"
  rm -f "$attestation" "$CLAUDE_RC_HOLD_FILE"

  # Cleanup failure after a verified stop must keep the registry and stale
  # attestation visible instead of falsely reporting a complete lifecycle.
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  slug="$(_claude_rc_slug "$repo")"
  instance_dir="$CLAUDE_RC_STATE/$slug"
  attestation="$instance_dir/environment-attestation.json"
  lock_path="$instance_dir/lock"
  wrapper="$(_claude_rc_wrapper_script)"
  : > "$CLAUDE_RC_HOLD_FILE"
  CLAUDE_RC_ENVIRONMENT_GENERATION=environment-current \
  CLAUDE_RC_HEADLESS_SSH_MARKER=1 \
  CLAUDE_RC_BRIDGE_PATH="$CLAUDE_RC_FAKE_BIN:$PATH" \
    _claude_rc_run "$repo" bash "$wrapper" start >/dev/null
  rc=0
  out="$(CLAUDE_RC_ENVIRONMENT_GENERATION=environment-current \
    CLAUDE_RC_HEADLESS_SSH_MARKER=1 \
    CLAUDE_RC_BRIDGE_PATH="$CLAUDE_RC_FAKE_BIN:$PATH" \
    _claude_rc_run "$repo" bash -c '
      set -euo pipefail
      source "$1"
      clear_environment_attestation() { return 1; }
      main stop --force
    ' _ "$wrapper" 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "attestation cleanup failure must fail stop: $out"
  assert_contains "$out" "identity/exit/lock-release 검증 실패"
  [ -f "$attestation" ] || fail "failed attestation cleanup must leave visible stale evidence"
  "$CLAUDE_RC_FAKE_BIN/flock" --timeout 1 "$lock_path" true \
    || fail "failed attestation cleanup left the stopped server lock held"
  status="$(cat "$CLAUDE_RC_STATE/instances.json")"
  jq -e --arg path "$repo" '.instances | has($path)' <<<"$status" >/dev/null \
    || fail "attestation cleanup failure must preserve registry: $status"
  rm -f "$attestation" "$CLAUDE_RC_HOLD_FILE"
}

test_claude_remote_control_handoff_failure_cleans_attestation() {
  local sandbox repo slug attestation lock_path wrapper out rc
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  slug="$(_claude_rc_slug "$repo")"
  attestation="$CLAUDE_RC_STATE/$slug/environment-attestation.json"
  lock_path="$CLAUDE_RC_STATE/$slug/lock"
  wrapper="$(_claude_rc_wrapper_script)"
  : > "$CLAUDE_RC_HOLD_FILE"

  rc=0
  out="$(CLAUDE_RC_ENVIRONMENT_GENERATION=environment-current \
    CLAUDE_RC_HEADLESS_SSH_MARKER=1 \
    CLAUDE_RC_BRIDGE_PATH="$CLAUDE_RC_FAKE_BIN:$PATH" \
    _claude_rc_run "$repo" bash -c '
      set -euo pipefail
      source "$1"
      handoff_launch_guard() {
        cancel_launch_guard "$1" "$2" || true
        return 1
      }
      main start
    ' _ "$wrapper" 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "forced handoff failure must fail start: $out"
  [ ! -e "$attestation" ] || fail "handoff failure left a stale environment attestation"
  "$CLAUDE_RC_FAKE_BIN/flock" --timeout 1 "$lock_path" true \
    || fail "handoff failure left the server lock held"
  rm -f "$CLAUDE_RC_HOLD_FILE"
}

test_claude_remote_control_start_warns_when_running_options_differ() {
  local sandbox repo err out
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  : > "$CLAUDE_RC_HOLD_FILE"

  _claude_rc_run "$repo" bash "$(_claude_rc_wrapper_script)" start >/dev/null
  out="$sandbox/start.out"
  err="$sandbox/start.err"
  _claude_rc_run "$repo" bash "$(_claude_rc_wrapper_script)" start \
    --spawn same-dir --capacity 7 --permission-mode plan > "$out" 2> "$err"

  assert_contains "$(cat "$out")" "이미 실행 중"
  assert_contains "$(cat "$err")" "실행 중인 서버에는 반영되지 않음"
  assert_contains "$(cat "$err")" "spawn: running=worktree, requested=same-dir"
  assert_contains "$(cat "$err")" "capacity: running=<omitted>, requested=7"
  assert_contains "$(cat "$err")" "permission-mode: running=bypassPermissions, requested=plan"

  _claude_rc_release_server "$repo"
}

test_claude_remote_control_start_warns_and_preserves_declared_registry() {
  local sandbox repo err status log
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  _claude_rc_write_instance "$repo" "worktree" "null" "bypassPermissions" "declared"
  : > "$CLAUDE_RC_HOLD_FILE"

  err="$sandbox/start.err"
  _claude_rc_run "$repo" bash "$(_claude_rc_wrapper_script)" start \
    --spawn same-dir --capacity 7 --permission-mode plan >/dev/null 2> "$err"
  _claude_rc_wait_fake_claude_log "remote-control --spawn same-dir" \
    || fail "fake claude log did not appear before assertion"

  assert_contains "$(cat "$err")" "이 경로는 Nix 선언 관리 대상"
  assert_contains "$(cat "$err")" "spawn: declared=worktree, requested=same-dir"
  assert_contains "$(cat "$err")" "capacity: declared=<omitted>, requested=7"
  assert_contains "$(cat "$err")" "permission-mode: declared=bypassPermissions, requested=plan"

  log="$(cat "$CLAUDE_RC_LOG")"
  assert_contains "$log" "remote-control --spawn same-dir --permission-mode plan --capacity 7 --no-create-session-in-dir"
  status="$(cat "$CLAUDE_RC_STATE/instances.json")"
  jq -e --arg path "$repo" '
    .instances[$path].source == "declared"
    and .instances[$path].spawn == "worktree"
    and .instances[$path].capacity == null
    and .instances[$path].permissionMode == "bypassPermissions"
  ' <<<"$status" >/dev/null || fail "declared start should preserve registry entry: $status"

  _claude_rc_release_server "$repo"
}

test_claude_remote_control_start_rejects_unmanaged_same_cwd_server() {
  local sandbox repo out rc
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  _claude_rc_install_unmanaged_process_mocks

  rc=0
  FAKE_UNMANAGED_CWD="$repo"
  FAKE_UNMANAGED_EXE="$CLAUDE_RC_SERVER_EXE"
  out="$(_claude_rc_run "$repo" bash "$(_claude_rc_wrapper_script)" start 2>&1)" || rc=$?
  unset FAKE_UNMANAGED_CWD FAKE_UNMANAGED_EXE
  [ "$rc" -eq 1 ] || fail "unmanaged same-cwd server should be rejected, got $rc: $out"
  assert_contains "$out" "refusing duplicate start"
  [ ! -f "$CLAUDE_RC_STATE/instances.json" ] || fail "unmanaged rejection must not register instance"
}

_claude_rc_assert_unmanaged_cli_shape_rejected() {
  local label="$1" sandbox repo out rc
  shift
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  _claude_rc_install_unmanaged_process_mocks
  _claude_rc_write_pid_argv_fixture 4242 "$@"

  rc=0
  FAKE_UNMANAGED_CWD="$repo"
  FAKE_UNMANAGED_EXE="$CLAUDE_RC_SERVER_EXE"
  FAKE_UNMANAGED_COMMAND="$*"
  out="$(_claude_rc_run "$repo" bash "$(_claude_rc_wrapper_script)" start 2>&1)" || rc=$?
  unset FAKE_UNMANAGED_CWD FAKE_UNMANAGED_EXE FAKE_UNMANAGED_COMMAND
  [ "$rc" -eq 1 ] || fail "$label should be rejected as an unmanaged bridge, got $rc: $out"
  assert_contains "$out" "refusing duplicate start"
  [ ! -f "$CLAUDE_RC_STATE/instances.json" ] \
    || fail "$label rejection must not register instance"
}

_claude_rc_assert_cli_shape_ignored() {
  local label="$1" sandbox repo out rc
  shift
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  _claude_rc_install_unmanaged_process_mocks
  _claude_rc_write_pid_argv_fixture 4242 "$@"
  : > "$CLAUDE_RC_HOLD_FILE"

  rc=0
  FAKE_UNMANAGED_CWD="$repo"
  FAKE_UNMANAGED_EXE="$CLAUDE_RC_SERVER_EXE"
  FAKE_UNMANAGED_COMMAND="$*"
  out="$(_claude_rc_run "$repo" bash "$(_claude_rc_wrapper_script)" start 2>&1)" || rc=$?
  unset FAKE_UNMANAGED_CWD FAKE_UNMANAGED_EXE FAKE_UNMANAGED_COMMAND
  [ "$rc" -eq 0 ] || fail "$label must not trip the unmanaged bridge guard, got $rc: $out"
  assert_contains "$out" "서버 시작됨"

  _claude_rc_release_server "$repo"
}

test_claude_remote_control_rejects_unmanaged_rc_alias() {
  _claude_rc_assert_unmanaged_cli_shape_rejected \
    "rc alias" claude rc --spawn worktree
}

test_claude_remote_control_rejects_unmanaged_global_option_prefix() {
  _claude_rc_assert_unmanaged_cli_shape_rejected \
    "global-option prefix" claude --verbose remote-control --spawn worktree
}

test_claude_remote_control_rejects_unmanaged_valued_global_option_prefix() {
  _claude_rc_assert_unmanaged_cli_shape_rejected \
    "valued global-option prefix" claude --model sonnet remote-control --spawn worktree
  _claude_rc_assert_unmanaged_cli_shape_rejected \
    "joined valued global-option prefix" claude --model=sonnet remote-control --spawn worktree
}

test_claude_remote_control_rejects_unmanaged_debug_filter_prefixes() {
  _claude_rc_assert_unmanaged_cli_shape_rejected \
    "long debug filter prefix" claude --debug api remote-control --spawn worktree
  _claude_rc_assert_unmanaged_cli_shape_rejected \
    "short debug filter prefix" claude -d api rc --spawn worktree
}

test_claude_remote_control_blocks_ambiguous_candidates_and_ignores_explicit_session_modes() {
  # Candidate discovery never signals these ambiguous processes. It only
  # refuses a duplicate launch while the same-cwd instance lock is free.
  _claude_rc_assert_unmanaged_cli_shape_rejected \
    "ambiguous debug filter" claude --debug remote-control
  _claude_rc_assert_unmanaged_cli_shape_rejected \
    "background-agent prompt" claude --background remote-control
  _claude_rc_assert_cli_shape_ignored \
    "interactive remote-control option" claude --remote-control demo
}

test_claude_remote_control_ignores_argv_only_remote_control_match() {
  local sandbox repo copy out rc status
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  _claude_rc_install_unmanaged_process_mocks
  copy="$(_claude_rc_wrapper_script)"

  # shellcheck disable=SC2016 # Variables intentionally expand in nested Bash.
  rc=0
  FAKE_UNMANAGED_CWD="$repo" \
  FAKE_UNMANAGED_EXE="$sandbox/outside/rogue" \
    out="$(_claude_rc_run "$repo" bash -c '
      set -euo pipefail
      # shellcheck source=/dev/null
      . "$1"
      find_server_pid_for_path "$2"
    ' _ "$copy" "$repo" 2>&1)" || rc=$?
  [ "$rc" -eq 1 ] || fail "argv-only remote-control match should not resolve as server, got rc=$rc out=$out"

  : > "$CLAUDE_RC_HOLD_FILE"
  rc=0
  FAKE_UNMANAGED_CWD="$repo" \
  FAKE_UNMANAGED_EXE="$sandbox/outside/rogue" \
    out="$(_claude_rc_run "$repo" bash "$copy" start 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || fail "argv-only remote-control match should not trip unmanaged guard, got $rc: $out"
  assert_contains "$out" "서버 시작됨"
  status="$(cat "$CLAUDE_RC_STATE/instances.json")"
  jq -e --arg path "$repo" '.instances | has($path)' <<<"$status" >/dev/null \
    || fail "start should register when only argv matches remote-control: $status"

  _claude_rc_release_server "$repo"
}

test_claude_remote_control_ignores_remote_control_substring_decoy() {
  local sandbox repo copy out rc
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  _claude_rc_install_unmanaged_process_mocks
  copy="$(_claude_rc_wrapper_script)"
  _claude_rc_write_pid_argv_fixture 4242 claude not-remote-control --spawn worktree

  # shellcheck disable=SC2016 # Variables intentionally expand in nested Bash.
  rc=0
  FAKE_UNMANAGED_CWD="$repo" \
  FAKE_UNMANAGED_EXE="$CLAUDE_RC_SERVER_EXE" \
    out="$(_claude_rc_run "$repo" bash -c '
      set -euo pipefail
      # shellcheck source=/dev/null
      . "$1"
      find_bridge_pid_for_path "$2"
    ' _ "$copy" "$repo" 2>&1)" || rc=$?
  [ "$rc" -eq 1 ] \
    || fail "remote-control substring decoy should fail exact-token discovery, got rc=$rc out=$out"

  : > "$CLAUDE_RC_HOLD_FILE"
  FAKE_UNMANAGED_CWD="$repo" \
  FAKE_UNMANAGED_EXE="$CLAUDE_RC_SERVER_EXE" \
    _claude_rc_run "$repo" bash "$copy" start >/dev/null
  _claude_rc_release_server "$repo"
}

test_claude_remote_control_ignores_prompt_token_decoy() {
  local sandbox repo copy out rc
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  _claude_rc_install_unmanaged_process_mocks
  copy="$(_claude_rc_wrapper_script)"
  _claude_rc_write_pid_argv_fixture 4242 claude -p remote-control

  # An exact prompt argument must not be classified as the CLI subcommand.
  # shellcheck disable=SC2016 # Variables intentionally expand in nested Bash.
  rc=0
  FAKE_UNMANAGED_CWD="$repo" \
  FAKE_UNMANAGED_EXE="$CLAUDE_RC_SERVER_EXE" \
    out="$(_claude_rc_run "$repo" bash -c '
      set -euo pipefail
      # shellcheck source=/dev/null
      . "$1"
      find_bridge_pid_for_path "$2"
    ' _ "$copy" "$repo" 2>&1)" || rc=$?
  [ "$rc" -eq 1 ] \
    || fail "prompt token decoy should not resolve as bridge, got rc=$rc out=$out"

  : > "$CLAUDE_RC_HOLD_FILE"
  FAKE_UNMANAGED_CWD="$repo" \
  FAKE_UNMANAGED_EXE="$CLAUDE_RC_SERVER_EXE" \
    _claude_rc_run "$repo" bash "$copy" start >/dev/null
  _claude_rc_release_server "$repo"
}

test_claude_remote_control_stop_blocks_worktree_sessions_and_force_unregisters() {
  local sandbox repo child_dir out rc status dead_repo
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  child_dir="$repo/.claude/worktrees/session-one"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  mkdir -p "$child_dir"
  _claude_rc_write_instance "$repo" "worktree" "null" "bypassPermissions" "manual"
  _claude_rc_install_child_process_mocks

  rc=0
  FAKE_CHILD_CWD="$child_dir"
  out="$(_claude_rc_run "$repo" bash "$(_claude_rc_wrapper_script)" stop 2>&1)" || rc=$?
  unset FAKE_CHILD_CWD
  [ "$rc" -eq 1 ] || fail "stop should fail while worktree sessions exist, got $rc: $out"
  assert_contains "$out" "재시작 불가(tombstone) 세션 1개 존재"
  status="$(cat "$CLAUDE_RC_STATE/instances.json")"
  jq -e --arg path "$repo" '.instances | has($path)' <<<"$status" >/dev/null \
    || fail "failed stop should preserve registration: $status"

  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  : > "$CLAUDE_RC_HOLD_FILE"
  _claude_rc_run "$repo" bash "$(_claude_rc_wrapper_script)" start >/dev/null
  _claude_rc_wait_fake_claude_log "remote-control --spawn worktree" \
    || fail "fake claude log did not appear before stop"
  _claude_rc_run "$repo" bash "$(_claude_rc_wrapper_script)" stop --force >/dev/null
  status="$(cat "$CLAUDE_RC_STATE/instances.json")"
  jq -e --arg path "$repo" '(.instances | has($path)) | not' <<<"$status" >/dev/null \
    || fail "force stop should unregister instance: $status"
  rm -f "$CLAUDE_RC_HOLD_FILE"

  dead_repo="$sandbox/dead-repo"
  _claude_rc_make_repo "$dead_repo" "$CLAUDE_RC_HOME"
  _claude_rc_write_instance "$dead_repo" "worktree" "null" "bypassPermissions" "manual"
  _claude_rc_run "$dead_repo" bash "$(_claude_rc_wrapper_script)" stop --force >/dev/null
  status="$(cat "$CLAUDE_RC_STATE/instances.json")"
  jq -e --arg path "$dead_repo" '(.instances | has($path)) | not' <<<"$status" >/dev/null \
    || fail "dead server stop should only unregister: $status"
}

test_claude_remote_control_stop_preserves_registration_when_lock_held_without_pid() {
  local sandbox repo slug lock_path lock_pid out rc status
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  _claude_rc_install_no_process_mocks
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  _claude_rc_write_instance "$repo" "worktree" "null" "bypassPermissions" "manual"
  slug="$(_claude_rc_slug "$repo")"
  mkdir -p "$CLAUDE_RC_STATE/$slug"
  lock_path="$CLAUDE_RC_STATE/$slug/lock"

  _claude_rc_acquire_synthetic_lock "$lock_path" "stop without PID"
  lock_pid="$CLAUDE_RC_SYNTHETIC_LOCK_PID"

  rc=0
  out="$(_claude_rc_run "$repo" bash "$(_claude_rc_wrapper_script)" stop --force 2>&1)" || rc=$?
  _claude_rc_release_synthetic_lock "$lock_pid"
  [ "$rc" -eq 1 ] || fail "stop should fail on held lock without PID, got $rc: $out"
  assert_contains "$out" "no-server-process"
  status="$(cat "$CLAUDE_RC_STATE/instances.json")"
  jq -e --arg path "$repo" '.instances | has($path)' <<<"$status" >/dev/null \
    || fail "held-lock stop must preserve registration: $status"
}

test_claude_remote_control_stop_path_removes_missing_registered_instance() {
  local sandbox stale_path status
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  _claude_rc_install_no_process_mocks
  stale_path="$sandbox/missing-project"
  _claude_rc_write_instance "$stale_path" "worktree" "null" "bypassPermissions" "manual"

  _claude_rc_run "$sandbox" bash "$(_claude_rc_wrapper_script)" stop "$stale_path" >/dev/null
  status="$(cat "$CLAUDE_RC_STATE/instances.json")"
  jq -e --arg path "$stale_path" '(.instances | has($path)) | not' <<<"$status" >/dev/null \
    || fail "stop <path> should remove missing stale registration: $status"
}

test_claude_remote_control_interactive_stop_waits_for_parent_lock_release() {
  local sandbox repo lock_path delay_state status
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  : > "$CLAUDE_RC_HOLD_FILE"
  _claude_rc_run "$repo" bash "$(_claude_rc_wrapper_script)" start >/dev/null
  lock_path="$CLAUDE_RC_STATE/$(_claude_rc_slug "$repo")/lock"
  delay_state="$sandbox/delayed-stop-probes"
  printf '%s\n' 2 > "$delay_state"
  _claude_rc_install_delayed_free_flock

  FAKE_FLOCK_DELAY_PATH="$lock_path" \
  FAKE_FLOCK_DELAY_STATE="$delay_state" \
    _claude_rc_run "$repo" bash "$(_claude_rc_wrapper_script)" stop --force >/dev/null

  [ "$(cat "$delay_state")" = "0" ] \
    || fail "interactive stop did not wait for parent lock release"
  status="$(cat "$CLAUDE_RC_STATE/instances.json")"
  jq -e --arg path "$repo" '(.instances | has($path)) | not' <<<"$status" >/dev/null \
    || fail "verified stop should unregister after lock release: $status"
  rm -f "$CLAUDE_RC_HOLD_FILE"
}

test_claude_remote_control_interactive_stop_preserves_registration_when_parent_lock_release_times_out() {
  local sandbox repo lock_path delay_state status out rc
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  : > "$CLAUDE_RC_HOLD_FILE"
  _claude_rc_run "$repo" bash "$(_claude_rc_wrapper_script)" start >/dev/null
  lock_path="$CLAUDE_RC_STATE/$(_claude_rc_slug "$repo")/lock"
  delay_state="$sandbox/stuck-stop-probes"
  printf '%s\n' 10 > "$delay_state"
  _claude_rc_install_delayed_free_flock

  rc=0
  out="$(_claude_rc_run "$repo" env \
    STOPPED_LOCK_POLL_ATTEMPTS=2 \
    STOPPED_LOCK_POLL_INTERVAL_SECONDS=0.01 \
    FAKE_FLOCK_DELAY_PATH="$lock_path" \
    FAKE_FLOCK_DELAY_STATE="$delay_state" \
    bash "$(_claude_rc_wrapper_script)" stop --force 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "stop must fail when parent lock release cannot be verified: $out"
  assert_contains "$out" "identity/exit/lock-release 검증 실패"
  status="$(cat "$CLAUDE_RC_STATE/instances.json")"
  jq -e --arg path "$repo" '.instances | has($path)' <<<"$status" >/dev/null \
    || fail "failed lock-release verification must preserve registration: $status"
  rm -f "$CLAUDE_RC_HOLD_FILE"
}
