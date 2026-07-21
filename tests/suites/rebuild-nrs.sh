# tests/suites/rebuild-nrs.sh — 도메인 테스트 정의 (sourced; aggregator가 lib/test-common.sh 후 source)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# shellcheck disable=SC2154,SC2164
write_mixed_user_codex_hooks() {
  local home_dir="$1"
  mkdir -p "$home_dir/.codex"
  # session-init-icons.sh is a known stale Claude-era user hook; Codex should prune it, not run it.
  cat > "$home_dir/.codex/hooks.json" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume",
        "hooks": [
          {
            "type": "command",
            "command": "~/.codex/hooks/session-init-icons.sh"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/tmp/custom-user-hook.sh"
          }
        ]
      }
    ]
  }
}
EOF
  printf '{}\n' > "$home_dir/.codex/hooks.compatibility.json"
}
assert_user_codex_hooks_pruned() {
  local home_dir="$1"
  local hooks_json="$home_dir/.codex/hooks.json"
  [[ ! -e "$home_dir/.codex/hooks.compatibility.json" ]] || fail "expected user-level hooks.compatibility.json to be removed"
  [[ -f "$hooks_json" ]] || fail "expected user-level hooks.json with preserved custom entry"
  local hooks_content
  hooks_content="$(cat "$hooks_json")"
  assert_contains "$hooks_content" "/tmp/custom-user-hook.sh"
  assert_not_contains "$hooks_content" "session-init-icons.sh"
}
install_repo_local_only_codex_cleanup_helper() {
  local home_dir="$1"
  local helper="$home_dir/.local/lib/rebuild/common.sh"
  rm -f "$helper"
  cp "$REPO_ROOT/modules/shared/scripts/lib/rebuild/common.sh" "$helper"
  cat >> "$helper" <<'EOF'

_clear_retired_codex_hook_artifacts() {
    local hooks_json="$FLAKE_PATH/.codex/hooks.json"
    local hooks_report="$FLAKE_PATH/.codex/hooks.compatibility.json"

    if [[ -e "$hooks_json" || -e "$hooks_report" ]]; then
        rm -f "$hooks_json" "$hooks_report"
        log_info "🧹 Removed retired Codex hook artifacts."
    fi
}
EOF
}

install_partial_deployed_codex_legacy_hooks_helper() {
  local home_dir="$1"
  local helper="$home_dir/.local/lib/rebuild/codex-legacy-hooks.sh"
  mkdir -p "$(dirname "$helper")"
  rm -f "$helper"
  cat > "$helper" <<'EOF'
# Partial old deployed helper fixture: readable, but missing codex_clear_retired_hook_artifacts.
codex_partial_legacy_hooks_helper_loaded() {
    return 0
}
EOF
}

install_repo_fallback_codex_legacy_hooks_helper() {
  local repo_root="$1"
  local helper="$repo_root/modules/shared/scripts/lib/rebuild/codex-legacy-hooks.sh"
  mkdir -p "$(dirname "$helper")"
  cp "$REPO_ROOT/modules/shared/scripts/lib/rebuild/codex-legacy-hooks.sh" "$helper"
}

install_codex_managed_artifact_fixture() {
  local home_dir="$1"
  mkdir -p "$home_dir/.codex/hooks" "$home_dir/.codex/lib"

  ln -sf "$REPO_ROOT/modules/shared/programs/codex/files/hooks/record-prompt-submit.sh" \
    "$home_dir/.codex/hooks/record-prompt-submit.sh"
  ln -sf "$REPO_ROOT/modules/shared/programs/codex/files/hooks/_stop-dispatcher.sh" \
    "$home_dir/.codex/hooks/_stop-dispatcher.sh"
  ln -sf "$REPO_ROOT/modules/shared/programs/codex/files/hooks/record-last-stop.sh" \
    "$home_dir/.codex/hooks/record-last-stop.sh"
  ln -sf "$REPO_ROOT/modules/shared/programs/codex/files/hooks/nrs-session-cleanup.sh" \
    "$home_dir/.codex/hooks/nrs-session-cleanup.sh"
  ln -sf "$REPO_ROOT/modules/shared/programs/codex/files/hooks/pinning-guard.sh" \
    "$home_dir/.codex/hooks/pinning-guard.sh"
  ln -sf "$REPO_ROOT/modules/shared/programs/codex/files/hooks/pinning-alert.sh" \
    "$home_dir/.codex/hooks/pinning-alert.sh"
  ln -sf "$REPO_ROOT/modules/shared/programs/claude/files/lib/hook-runtime.sh" \
    "$home_dir/.codex/lib/hook-runtime.sh"
  ln -sf "$REPO_ROOT/modules/shared/programs/claude/files/lib/pinning-patterns.sh" \
    "$home_dir/.codex/lib/pinning-patterns.sh"
}

install_platform_rebuild_entrypoint() {
  local sandbox="$1" platform="$2" command="$3"
  local home_dir="$sandbox/home"
  local generated_dir="$sandbox/generated"

  mkdir -p "$home_dir/.local/bin" "$generated_dir"

  # shellcheck disable=SC2016  # Literal Nix source strings.
  case "$platform" in
    darwin)
      register_copy_exec \
        "$REPO_ROOT/modules/shared/programs/shell/darwin.nix" \
        ".local/bin/$command" \
        '${darwinScriptsDir}/'"$command"'.sh' \
        "modules/darwin/scripts/$command.sh"
      ;;
    nixos)
      register_copy_exec \
        "$REPO_ROOT/modules/shared/programs/shell/nixos.nix" \
        ".local/bin/$command" \
        '${nixosScriptsDir}/'"$command"'.sh' \
        "modules/nixos/scripts/$command.sh"
      ;;
    *) fail "unknown platform for $command entrypoint: $platform" ;;
  esac
}

install_platform_nrs_entrypoint() {
  install_platform_rebuild_entrypoint "$1" "$2" nrs
}

install_platform_nrp_entrypoint() {
  install_platform_rebuild_entrypoint "$1" "$2" nrp
}

install_recording_nrs_relink() {
  local home_dir="$1"
  mkdir -p "$home_dir/.local/bin"
  cat > "$home_dir/.local/bin/nrs-relink" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${NRS_RELINK_LOG:?}"
EOF
  chmod +x "$home_dir/.local/bin/nrs-relink"
}

test_rebuild_common_exports_public_api() {
  local sandbox output
  sandbox=$(new_sandbox)
  install_deployed_layout "$sandbox"

  output=$(
    HOME="$sandbox/home" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    bash -c '
      set -euo pipefail
      REBUILD_CMD="nixos-rebuild"
      source "'"$sandbox/home/.local/lib/rebuild-common.sh"'"
      parse_args --offline --force --cores 2
      printf "offline=%s\nforce=%s\ncores=%s\n" "$OFFLINE_FLAG" "$FORCE_FLAG" "$CORES_FLAG"
      declare -F log_info
      declare -F log_warn
      declare -F log_error
      declare -F acquire_nrs_lock
      declare -F release_nrs_lock
      declare -F release_nrs_lock_after_no_changes
      declare -F release_nrs_lock_on_failure
      declare -F mark_nrs_lock_switch_success
      declare -F acquire_rebuild_lock
      declare -F release_rebuild_lock
      declare -F release_rebuild_lock_on_failure
      declare -F preflight_source_build_check
      declare -F preflight_cask_conflict_check
      declare -F rebuild_is_main_flake
      declare -F prepare_worktree_symlinks_for_rebuild
      declare -F preview_changes
      declare -F worktree_symlink_guard
      declare -F maybe_relink_or_restore
      declare -F cleanup_build_artifacts
      declare -F codex_managed_artifacts_missing
      declare -F codex_log_managed_artifacts_missing
      declare -F repair_codex_config_drift_no_changes
    ' 2>&1
  )

  assert_contains "$output" "offline=--offline"
  assert_contains "$output" "force=true"
  assert_contains "$output" "cores=--cores 2"
  assert_contains "$output" "log_info"
  assert_contains "$output" "log_warn"
  assert_contains "$output" "log_error"
  assert_contains "$output" "acquire_nrs_lock"
  assert_contains "$output" "release_nrs_lock"
  assert_contains "$output" "release_nrs_lock_after_no_changes"
  assert_contains "$output" "release_nrs_lock_on_failure"
  assert_contains "$output" "mark_nrs_lock_switch_success"
  assert_contains "$output" "acquire_rebuild_lock"
  assert_contains "$output" "release_rebuild_lock"
  assert_contains "$output" "release_rebuild_lock_on_failure"
  assert_contains "$output" "preflight_source_build_check"
  assert_contains "$output" "preflight_cask_conflict_check"
  assert_contains "$output" "rebuild_is_main_flake"
  assert_contains "$output" "prepare_worktree_symlinks_for_rebuild"
  assert_contains "$output" "preview_changes"
  assert_contains "$output" "worktree_symlink_guard"
  assert_contains "$output" "maybe_relink_or_restore"
  assert_contains "$output" "cleanup_build_artifacts"
  assert_contains "$output" "codex_managed_artifacts_missing"
  assert_contains "$output" "codex_log_managed_artifacts_missing"
  assert_contains "$output" "repair_codex_config_drift_no_changes"
}

test_parse_args_unknown_argument_shows_usage_and_fails() {
  local sandbox stdout_file stderr_file rc
  sandbox=$(new_sandbox)
  install_deployed_layout "$sandbox"
  stdout_file="$sandbox/parse-args.out"
  stderr_file="$sandbox/parse-args.err"

  # 오류 메시지와 usage는 stderr 계약이다 — stdout/stderr를 분리 캡처해 스트림 회귀를 감지한다.
  rc=0
  HOME="$sandbox/home" \
  PATH="$FIXTURE_DIR/bin:$PATH" \
  bash -c '
    set -euo pipefail
    REBUILD_CMD="nixos-rebuild"
    source "'"$sandbox/home/.local/lib/rebuild-common.sh"'"
    parse_args --bogus
  ' > "$stdout_file" 2> "$stderr_file" || rc=$?

  [[ "$rc" -eq 1 ]] || fail "expected parse_args --bogus to exit 1 (actual: $rc)"
  assert_contains "$(cat "$stderr_file")" "Unknown argument: --bogus"
  assert_contains "$(cat "$stderr_file")" "Usage:"
  [[ -s "$stdout_file" ]] && fail "expected empty stdout for unknown argument (got: $(cat "$stdout_file"))"
  return 0
}

test_nixos_nrs_help_flag_prints_usage() {
  local sandbox home_dir repo_root output
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  install_platform_nrs_entrypoint "$sandbox" nixos

  # --help는 parse_args에서 exit 0 하므로 rebuild/sudo stub 없이 안전하게 실행된다.
  output=$(
    HOME="$home_dir" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/nrs"'" --help
    ' 2>&1
  )

  assert_contains "$output" "Usage: nrs"
  assert_contains "$output" "--offline"
  assert_contains "$output" "--cores N"
  assert_not_contains "$output" "Applying changes"
  assert_not_contains "$output" "Unknown argument"
}

test_darwin_nrs_h_alias_prints_usage() {
  local sandbox home_dir repo_root output
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  install_platform_nrs_entrypoint "$sandbox" darwin

  # darwin 진입점 + 짧은 alias -h도 동일 usage 계약을 따른다.
  output=$(
    HOME="$home_dir" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/nrs"'" -h
    ' 2>&1
  )

  assert_contains "$output" "Usage: nrs"
  assert_contains "$output" "--force"
  assert_contains "$output" "--cores N"
  assert_not_contains "$output" "Unknown argument"
}

test_nrs_help_ignores_inherited_rebuild_mode() {
  local sandbox home_dir repo_root output
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  install_platform_nrs_entrypoint "$sandbox" nixos

  # 진입점의 REBUILD_MODE=switch 명시 선언이 호출 환경에서 상속된 값을 덮는다.
  output=$(
    HOME="$home_dir" \
    REBUILD_MODE="preview" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/nrs"'" --help
    ' 2>&1
  )

  assert_contains "$output" "Usage: nrs"
  assert_contains "$output" "--force"
  assert_not_contains "$output" "preview wrapper"
}

test_nrp_help_usage_omits_force_flag() {
  local sandbox home_dir repo_root output
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  install_platform_nrp_entrypoint "$sandbox" nixos

  # 실제 nrp 진입점 실행 — REBUILD_MODE=preview 선언이 usage에서 무효 --force를 제외한다.
  output=$(
    HOME="$home_dir" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/nrp"'" --help
    ' 2>&1
  )

  assert_contains "$output" "Usage: nrp"
  assert_contains "$output" "--cores N"
  assert_not_contains "$output" "--force"
}

test_nrp_rejects_force_flag() {
  local sandbox home_dir repo_root output rc
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  install_platform_nrp_entrypoint "$sandbox" nixos

  # preview 진입점에서 --force는 usage뿐 아니라 parser에서도 거부된다.
  rc=0
  output=$(
    HOME="$home_dir" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/nrp"'" --force
    ' 2>&1
  ) || rc=$?

  [[ "$rc" -eq 1 ]] || fail "expected nrp --force to exit 1 (actual: $rc)"
  assert_contains "$output" "--force is not supported"
  assert_contains "$output" "Usage: nrp"
}

test_detect_worktree_uses_current_worktree_path() {
  local sandbox home_dir repo_root worktree_root output
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  worktree_root="$repo_root/.claude/worktrees/feature_one"
  install_deployed_layout "$sandbox" "$repo_root"

  output=$(
    HOME="$home_dir" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    bash -c '
      set -euo pipefail
      cd "'"$worktree_root"'"
      REBUILD_CMD="nixos-rebuild"
      source "'"$home_dir/.local/lib/rebuild-common.sh"'"
      printf "flake=%s\nis_main=%s\n" \
        "$FLAKE_PATH" \
        "$(rebuild_is_main_flake && echo true || echo false)"
    ' 2>&1
  )

  assert_contains "$output" "flake=$worktree_root"
  assert_contains "$output" "is_main=false"
}

test_worktree_relink_skips_non_tty_without_opt_in() {
  local sandbox home_dir repo_root worktree_root output relink_log
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  relink_log="$sandbox/nrs-relink.log"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  worktree_root="$repo_root/.claude/worktrees/feature_one"
  install_deployed_layout "$sandbox" "$repo_root"
  install_recording_nrs_relink "$home_dir"

  output=$(
    HOME="$home_dir" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    NRS_RELINK_LOG="$relink_log" \
    bash -c '
      set -euo pipefail
      cd "'"$worktree_root"'"
      REBUILD_CMD="nixos-rebuild"
      source "'"$home_dir/.local/lib/rebuild-common.sh"'"
      maybe_relink_or_restore
    ' </dev/null 2>&1
  )

  assert_contains "$output" "Skipping worktree relink in non-interactive/agent context"
  assert_not_contains "$output" "Relinking symlinks to worktree"
  [[ ! -s "$relink_log" ]] || fail "expected non-TTY worktree relink to skip nrs-relink"
}

test_worktree_relink_opt_in_allows_non_tty() {
  local sandbox home_dir repo_root worktree_root output relink_log
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  relink_log="$sandbox/nrs-relink.log"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  worktree_root="$repo_root/.claude/worktrees/feature_one"
  install_deployed_layout "$sandbox" "$repo_root"
  install_recording_nrs_relink "$home_dir"

  output=$(
    HOME="$home_dir" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    NRS_RELINK_LOG="$relink_log" \
    NRS_ALLOW_WORKTREE_RELINK=1 \
    bash -c '
      set -euo pipefail
      cd "'"$worktree_root"'"
      REBUILD_CMD="nixos-rebuild"
      source "'"$home_dir/.local/lib/rebuild-common.sh"'"
      maybe_relink_or_restore
    ' </dev/null 2>&1
  )

  assert_contains "$output" "Relinking symlinks to worktree"
  assert_not_contains "$output" "Skipping worktree relink"
  assert_file_contains "$relink_log" "relink"
}

test_main_relink_restore_ignores_non_tty_guard() {
  local sandbox home_dir repo_root worktree_root output relink_log
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  relink_log="$sandbox/nrs-relink.log"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  worktree_root="$repo_root/.claude/worktrees/feature_one"
  install_deployed_layout "$sandbox" "$repo_root"
  install_recording_nrs_relink "$home_dir"

  mkdir -p "$home_dir/.claude" "$worktree_root"
  ln -sf "$worktree_root/CLAUDE.md" "$home_dir/.claude/CLAUDE.md"

  output=$(
    HOME="$home_dir" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    NRS_RELINK_LOG="$relink_log" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      REBUILD_CMD="nixos-rebuild"
      source "'"$home_dir/.local/lib/rebuild-common.sh"'"
      maybe_relink_or_restore
    ' </dev/null 2>&1
  )

  assert_contains "$output" "Restoring symlinks to nix store chain"
  assert_not_contains "$output" "Skipping worktree relink"
  assert_file_contains "$relink_log" "restore"
}

test_nixos_nrs_offline_force_smoke() {
  local sandbox home_dir repo_root stub_dir output result_target
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stub-bin"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  install_platform_nrs_entrypoint "$sandbox" nixos
  install_repo_local_only_codex_cleanup_helper "$home_dir"
  install_partial_deployed_codex_legacy_hooks_helper "$home_dir"
  install_repo_fallback_codex_legacy_hooks_helper "$repo_root"

  mkdir -p "$stub_dir" "$home_dir/.local/bin"
  cat > "$stub_dir/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
"$@"
EOF
  cat > "$stub_dir/nixos-rebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  build)
    ln -sfn "${NRS_RESULT_TARGET:?}" ./result
    ;;
  switch)
    :
    ;;
  *)
    echo "unexpected nixos-rebuild subcommand: $1" >&2
    exit 1
    ;;
esac
EOF
  cat > "$stub_dir/nvd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "stub nvd diff"
EOF
  cat > "$home_dir/.local/bin/nrs-relink" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "$stub_dir/sudo" "$stub_dir/nixos-rebuild" "$stub_dir/nvd" "$home_dir/.local/bin/nrs-relink"

  result_target="$sandbox/current-system"
  mkdir -p "$result_target"
  mkdir -p "$repo_root/.codex"
  printf '{}\n' > "$repo_root/.codex/hooks.json"
  printf '{}\n' > "$repo_root/.codex/hooks.compatibility.json"
  write_mixed_user_codex_hooks "$home_dir"

  output=$(
    HOME="$home_dir" \
    PATH="$stub_dir:$FIXTURE_DIR/bin:$PATH" \
    NRS_RESULT_TARGET="$result_target" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/nrs"'" --offline --force
    ' 2>&1
  )

  assert_contains "$output" "Applying changes (offline)"
  assert_contains "$output" "Done!"
  assert_contains "$output" "Removed retired user-level Codex hooks.compatibility.json"
  assert_contains "$output" "Pruned 1 stale Codex hook entry"
  [[ ! -e "$repo_root/.codex/hooks.json" ]] || fail "expected nixos nrs to remove retired hooks.json"
  [[ ! -e "$repo_root/.codex/hooks.compatibility.json" ]] || fail "expected nixos nrs to remove retired hooks.compatibility.json"
  assert_user_codex_hooks_pruned "$home_dir"
}

test_nixos_nrs_no_changes_activates_when_codex_artifact_missing() {
  local sandbox home_dir repo_root stub_dir output current_target switch_log
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stub-bin"
  current_target="$sandbox/current-system"
  switch_log="$sandbox/nixos-switch.log"

  mkdir -p "$repo_root" "$stub_dir" "$home_dir/.local/bin" "$current_target"
  install_deployed_layout "$sandbox" "$repo_root"
  install_platform_nrs_entrypoint "$sandbox" nixos
  install_codex_managed_artifact_fixture "$home_dir"
  rm -f "$home_dir/.codex/hooks/pinning-alert.sh"

  cat > "$stub_dir/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
"$@"
EOF
  cat > "$stub_dir/nixos-rebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  build)
    ln -sfn "${NIXOS_CURRENT_SYSTEM:?}" ./result
    ;;
  switch)
    printf 'switch\n' >> "${NIXOS_SWITCH_LOG:?}"
    ;;
  *)
    echo "unexpected nixos-rebuild subcommand: $1" >&2
    exit 1
    ;;
esac
EOF
  cat > "$stub_dir/nvd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "stub nvd diff"
EOF
  local real_readlink
  real_readlink="$(command -v readlink)"
  cat > "$stub_dir/readlink" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "/run/current-system" ]]; then
  printf '%s\n' "\${NIXOS_CURRENT_SYSTEM:?}"
else
  "$real_readlink" "\$@"
fi
EOF
  cat > "$home_dir/.local/bin/nrs-relink" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "$stub_dir/sudo" "$stub_dir/nixos-rebuild" "$stub_dir/nvd" "$stub_dir/readlink" "$home_dir/.local/bin/nrs-relink"

  output=$(
    HOME="$home_dir" \
    PATH="$stub_dir:$FIXTURE_DIR/bin:$PATH" \
    NIXOS_CURRENT_SYSTEM="$current_target" \
    NIXOS_SWITCH_LOG="$switch_log" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/nrs"'" --offline
    ' 2>&1
  )

  assert_contains "$output" "Codex hook/lib artifact missing"
  assert_contains "$output" '$HOME/.codex/hooks/pinning-alert.sh'
  assert_contains "$output" "Applying changes (offline)"
  assert_not_contains "$output" "Skipping rebuild"
  [[ -s "$switch_log" ]] || fail "expected no-change nrs to run nixos-rebuild switch when Codex artifact is missing"
}

test_darwin_nrs_offline_force_smoke() {
  local sandbox home_dir repo_root stub_dir output result_target current_target
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stub-bin"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  install_platform_nrs_entrypoint "$sandbox" darwin

  mkdir -p "$stub_dir" "$home_dir/.local/bin" "$home_dir/Library/LaunchAgents" "$sandbox/current-system"
  current_target="$sandbox/current-system"

  cat > "$stub_dir/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
"$@"
EOF
  cat > "$stub_dir/darwin-rebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  build)
    ln -sfn "${DARWIN_RESULT_TARGET:?}" ./result
    ;;
  switch)
    :
    ;;
  *)
    echo "unexpected darwin-rebuild subcommand: $1" >&2
    exit 1
    ;;
esac
EOF
  cat > "$stub_dir/nvd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "stub nvd diff"
EOF
  cat > "$stub_dir/launchctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  list)
    printf '%s\n' '-\t0\tcom.greenhead.test-agent'
    exit 0
    ;;
  bootout) exit 0 ;;
esac
exit 0
EOF
  cat > "$stub_dir/open" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  cat > "$stub_dir/pgrep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 1
EOF
  cat > "$stub_dir/killall" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  local real_readlink
  real_readlink="$(command -v readlink)"
  cat > "$stub_dir/readlink" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "/run/current-system" ]]; then
  printf '%s\n' "\${DARWIN_CURRENT_SYSTEM:?}"
else
  "$real_readlink" "\$@"
fi
EOF
  cat > "$home_dir/.local/bin/nrs-relink" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "$stub_dir/sudo" "$stub_dir/darwin-rebuild" "$stub_dir/nvd" "$stub_dir/launchctl" "$stub_dir/open" "$stub_dir/pgrep" "$stub_dir/killall" "$stub_dir/readlink" "$home_dir/.local/bin/nrs-relink"

  result_target="$sandbox/darwin-result"
  mkdir -p "$result_target"
  mkdir -p "$repo_root/.codex"
  printf '{}\n' > "$repo_root/.codex/hooks.json"
  printf '{}\n' > "$repo_root/.codex/hooks.compatibility.json"
  write_mixed_user_codex_hooks "$home_dir"

  output=$(
    HOME="$home_dir" \
    PATH="$stub_dir:$FIXTURE_DIR/bin:$PATH" \
    DARWIN_RESULT_TARGET="$result_target" \
    DARWIN_CURRENT_SYSTEM="$current_target" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/nrs"'" --offline --force
    ' 2>&1
  )

  assert_contains "$output" "Applying changes (offline)"
  assert_contains "$output" "Done!"
  assert_contains "$output" "Removed retired user-level Codex hooks.compatibility.json"
  assert_contains "$output" "Pruned 1 stale Codex hook entry"
  [[ ! -e "$repo_root/.codex/hooks.json" ]] || fail "expected darwin nrs to remove retired hooks.json"
  [[ ! -e "$repo_root/.codex/hooks.compatibility.json" ]] || fail "expected darwin nrs to remove retired hooks.compatibility.json"
  assert_user_codex_hooks_pruned "$home_dir"
}

test_darwin_nrs_no_changes_releases_worktree_lock() {
  local sandbox home_dir repo_root worktree_root stub_dir output result_target current_target lock_file
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stub-bin"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  worktree_root="$repo_root/.claude/worktrees/feature_one"
  install_deployed_layout "$sandbox" "$repo_root"
  install_platform_nrs_entrypoint "$sandbox" darwin
  install_repo_local_only_codex_cleanup_helper "$home_dir"
  install_partial_deployed_codex_legacy_hooks_helper "$home_dir"
  install_repo_fallback_codex_legacy_hooks_helper "$worktree_root"

  mkdir -p "$stub_dir" "$home_dir/.local/bin" "$home_dir/Library/LaunchAgents"
  current_target="$sandbox/current-system"
  mkdir -p "$current_target"
  lock_file="$sandbox/nrs-state"
  rm -f "$lock_file"
  mkdir -p "$worktree_root/.codex"
  printf '{}\n' > "$worktree_root/.codex/hooks.json"
  printf '{}\n' > "$worktree_root/.codex/hooks.compatibility.json"
  write_mixed_user_codex_hooks "$home_dir"
  install_codex_managed_artifact_fixture "$home_dir"

  cat > "$stub_dir/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
"$@"
EOF
  cat > "$stub_dir/darwin-rebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  build)
    ln -sfn "${DARWIN_RESULT_TARGET:?}" ./result
    ;;
  switch)
    :
    ;;
  *)
    echo "unexpected darwin-rebuild subcommand: $1" >&2
    exit 1
    ;;
esac
EOF
  cat > "$stub_dir/nvd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "stub nvd diff"
EOF
  local real_readlink
  real_readlink="$(command -v readlink)"
  cat > "$stub_dir/readlink" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "/run/current-system" ]]; then
  printf '%s\n' "\${DARWIN_CURRENT_SYSTEM:?}"
else
  "$real_readlink" "\$@"
fi
EOF
  cat > "$home_dir/.local/bin/nrs-relink" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "$stub_dir/sudo" "$stub_dir/darwin-rebuild" "$stub_dir/nvd" "$stub_dir/readlink" "$home_dir/.local/bin/nrs-relink"

  result_target="$current_target"
  output=$(
    HOME="$home_dir" \
    PATH="$stub_dir:$FIXTURE_DIR/bin:$PATH" \
    DARWIN_RESULT_TARGET="$result_target" \
    DARWIN_CURRENT_SYSTEM="$current_target" \
    NRS_LOCK_FILE="$lock_file" \
    bash -c '
      set -euo pipefail
      cd "'"$worktree_root"'"
      "'"$home_dir/.local/bin/nrs"'" 
    ' 2>&1
  )

  assert_contains "$output" "Lock acquired"
  assert_contains "$output" "No changes to apply"
  assert_contains "$output" "Lock released"
  assert_contains "$output" "Removed retired user-level Codex hooks.compatibility.json"
  assert_contains "$output" "Pruned 1 stale Codex hook entry"
  [[ ! -e "$lock_file" ]] || fail "expected sandbox nrs lock file to be removed after no-change early return"
  [[ ! -e "$worktree_root/.codex/hooks.json" ]] || fail "expected no-change darwin nrs to remove retired hooks.json"
  [[ ! -e "$worktree_root/.codex/hooks.compatibility.json" ]] || fail "expected no-change darwin nrs to remove retired hooks.compatibility.json"
  assert_user_codex_hooks_pruned "$home_dir"
}

# darwin no-change gcroot guard fixture — caller의 local 변수(sandbox/home_dir/repo_root/
# worktree_root/stub_dir/current_target/relink_log/lock_file)를 bash dynamic scoping으로 채운다.
# main repo에서 no-change nrs를 돌리되, stale worktree 심링크 probe를 심어 guard가 없으면
# maybe_relink_or_restore의 Phase 1(rm) + restore가 반드시 실행되는 상태를 만든다.
setup_darwin_no_change_gcroot_fixture() {
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stub-bin"
  current_target="$sandbox/current-system"
  relink_log="$sandbox/nrs-relink.log"
  lock_file="$sandbox/nrs-state"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  worktree_root="$repo_root/.claude/worktrees/feature_one"
  install_deployed_layout "$sandbox" "$repo_root"
  install_platform_nrs_entrypoint "$sandbox" darwin
  install_codex_managed_artifact_fixture "$home_dir"
  install_recording_nrs_relink "$home_dir"

  mkdir -p "$stub_dir" "$current_target" "$home_dir/.claude"
  rm -f "$lock_file"

  # stale worktree probe: main 경로 _remove_worktree_symlinks가 매칭하는 심링크
  ln -sf "$worktree_root/CLAUDE.md" "$home_dir/.claude/CLAUDE.md"

  cat > "$stub_dir/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
"$@"
EOF
  cat > "$stub_dir/darwin-rebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  build)
    ln -sfn "${DARWIN_CURRENT_SYSTEM:?}" ./result
    ;;
  switch)
    :
    ;;
  *)
    echo "unexpected darwin-rebuild subcommand: $1" >&2
    exit 1
    ;;
esac
EOF
  cat > "$stub_dir/nvd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "stub nvd diff"
EOF
  local real_readlink
  real_readlink="$(command -v readlink)"
  cat > "$stub_dir/readlink" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "/run/current-system" ]]; then
  printf '%s\n' "\${DARWIN_CURRENT_SYSTEM:?}"
else
  "$real_readlink" "\$@"
fi
EOF
  chmod +x "$stub_dir/sudo" "$stub_dir/darwin-rebuild" "$stub_dir/nvd" "$stub_dir/readlink"
}

run_darwin_no_change_gcroot_nrs() {
  HOME="$home_dir" \
  PATH="$stub_dir:$FIXTURE_DIR/bin:$PATH" \
  DARWIN_CURRENT_SYSTEM="$current_target" \
  NRS_LOCK_FILE="$lock_file" \
  NRS_RELINK_LOG="$relink_log" \
  bash -c '
    set -euo pipefail
    cd "'"$repo_root"'"
    "'"$home_dir/.local/bin/nrs"'"
  ' 2>&1
}

test_darwin_nrs_no_changes_skips_relink_without_hm_gcroot() {
  local sandbox home_dir repo_root worktree_root stub_dir current_target relink_log lock_file output
  setup_darwin_no_change_gcroot_fixture

  output=$(run_darwin_no_change_gcroot_nrs)

  assert_contains "$output" "No changes to apply"
  assert_not_contains "$output" "Restoring symlinks to nix store chain"
  [[ ! -s "$relink_log" ]] || fail "expected no-change nrs without HM gcroot to skip nrs-relink"
  [[ -L "$home_dir/.claude/CLAUDE.md" ]] || fail "expected stale worktree symlink to be left untouched without HM gcroot"
  [[ ! -e "$lock_file" ]] || fail "expected nrs lock file to be removed after no-change early return"
}

test_darwin_nrs_no_changes_restores_when_hm_gcroot_present() {
  local sandbox home_dir repo_root worktree_root stub_dir current_target relink_log lock_file output
  setup_darwin_no_change_gcroot_fixture
  mkdir -p "$home_dir/.local/state/home-manager/gcroots"
  touch "$home_dir/.local/state/home-manager/gcroots/current-home"

  output=$(run_darwin_no_change_gcroot_nrs)

  assert_contains "$output" "No changes to apply"
  assert_contains "$output" "Restoring symlinks to nix store chain"
  assert_file_contains "$relink_log" "restore"
  [[ ! -L "$home_dir/.claude/CLAUDE.md" ]] || fail "expected stale worktree symlink to be removed when HM gcroot is present"
}

test_darwin_nrs_no_changes_activates_when_codex_artifact_missing() {
  local sandbox home_dir repo_root stub_dir output current_target switch_log lock_file
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stub-bin"
  current_target="$sandbox/current-system"
  switch_log="$sandbox/darwin-switch.log"
  lock_file="$sandbox/nrs-state"

  mkdir -p "$repo_root" "$stub_dir" "$home_dir/.local/bin" "$home_dir/Library/LaunchAgents" "$current_target"
  install_deployed_layout "$sandbox" "$repo_root"
  install_platform_nrs_entrypoint "$sandbox" darwin
  install_codex_managed_artifact_fixture "$home_dir"
  rm -f "$home_dir/.codex/hooks/pinning-alert.sh"

  cat > "$stub_dir/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
"$@"
EOF
  cat > "$stub_dir/darwin-rebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  build)
    ln -sfn "${DARWIN_CURRENT_SYSTEM:?}" ./result
    ;;
  switch)
    printf 'switch\n' >> "${DARWIN_SWITCH_LOG:?}"
    ;;
  *)
    echo "unexpected darwin-rebuild subcommand: $1" >&2
    exit 1
    ;;
esac
EOF
  cat > "$stub_dir/nvd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "stub nvd diff"
EOF
  cat > "$stub_dir/launchctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  list) exit 0 ;;
  bootout) exit 0 ;;
esac
exit 0
EOF
  cat > "$stub_dir/open" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  cat > "$stub_dir/pgrep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 1
EOF
  cat > "$stub_dir/killall" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  local real_readlink
  real_readlink="$(command -v readlink)"
  cat > "$stub_dir/readlink" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "/run/current-system" ]]; then
  printf '%s\n' "\${DARWIN_CURRENT_SYSTEM:?}"
else
  "$real_readlink" "\$@"
fi
EOF
  cat > "$home_dir/.local/bin/nrs-relink" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "$stub_dir/sudo" "$stub_dir/darwin-rebuild" "$stub_dir/nvd" "$stub_dir/launchctl" "$stub_dir/open" "$stub_dir/pgrep" "$stub_dir/killall" "$stub_dir/readlink" "$home_dir/.local/bin/nrs-relink"

  output=$(
    HOME="$home_dir" \
    PATH="$stub_dir:$FIXTURE_DIR/bin:$PATH" \
    DARWIN_CURRENT_SYSTEM="$current_target" \
    DARWIN_SWITCH_LOG="$switch_log" \
    NRS_LOCK_FILE="$lock_file" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/nrs"'"
    ' 2>&1
  )

  assert_contains "$output" "Codex hook/lib artifact missing"
  assert_contains "$output" '$HOME/.codex/hooks/pinning-alert.sh'
  assert_contains "$output" "Applying changes"
  assert_not_contains "$output" "Skipping rebuild"
  [[ -s "$switch_log" ]] || fail "expected no-change nrs to run darwin-rebuild switch when Codex artifact is missing"
}
