#!/usr/bin/env bash
# SC2034: REPO_ROOT/FIXTURE_DIR/TEST_TMP_FILE는 source된 스위트가 사용. SC1090: 스위트 동적 디스커버리.
# shellcheck disable=SC2034,SC1090
# tests/shell-script-tests.sh
# 배포 레이아웃 기준 shell script fixture 테스트
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/shell-scripts"
TEST_TMP_FILE="$(mktemp "${TMPDIR:-/tmp}/shell-script-tests-list.XXXXXX")"

# Git hooks may export repository-scoped GIT_* variables.
# Fixture repositories must run fully isolated from the outer repo context.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_OBJECT_DIRECTORY
unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_IMPLICIT_WORK_TREE

. "$SCRIPT_DIR/lib/test-common.sh"

# 도메인 스위트(정의 전용) find 디스커버리 — tests/suites/ 한정(기존 test-*.sh 하네스 자동 제외)
while IFS= read -r -d '' _suite; do
  . "$_suite"
done < <(find "$SCRIPT_DIR/suites" -maxdepth 1 -type f -name '*.sh' -print0 | sort -z)

run_test "wt help uses deployed helper layout" test_wt_help_from_deployed_layout
run_test "wt wrapper ignores runtime HOME for real script" test_wt_wrapper_ignores_runtime_home_for_real_script
run_test "managed plugin skill helper rejects duplicate matches" test_managed_plugin_skill_link_requires_single_match
run_test "rebuild-common exports public API" test_rebuild_common_exports_public_api
run_test "detect_worktree switches to active worktree" test_detect_worktree_uses_current_worktree_path
run_test "wt cd returns target path by name" test_wt_cd_by_name_returns_target_path
run_test "wt ls lists deployed worktrees" test_wt_ls_from_deployed_layout_lists_worktrees
run_test "wt ls --json outputs parseable array" test_wt_ls_json_outputs_parseable_array
run_test "wt create conflict requires if-exists when noninteractive" test_wt_create_conflict_noninteractive_requires_if_exists
run_test "wt create if-exists=reuse returns path" test_wt_create_if_exists_reuse_returns_path
run_test "wt cd requires name when noninteractive" test_wt_cd_noninteractive_requires_name
run_test "wt cd prints path in tmux when noninteractive" test_wt_cd_noninteractive_in_tmux_prints_path
run_test "wt create/reuse prints path in tmux when noninteractive" test_wt_create_reuse_noninteractive_in_tmux_prints_path
run_test "wt --stay prints path to stdout when noninteractive" test_wt_create_stay_noninteractive_prints_path_to_stdout
run_test "shadow paths do not override managed helpers" test_shadow_paths_do_not_override_managed_helpers
run_test "wt symlink alias does not load adjacent helpers" test_wt_symlink_alias_does_not_load_adjacent_helpers
run_test "rebuild-common symlink alias does not load adjacent helpers" test_rebuild_common_symlink_alias_does_not_load_adjacent_helpers
run_test "wt create does not call legacy sync" test_wt_create_does_not_call_legacy_sync
run_test "wt create skips symlinked codex source" test_wt_create_skips_symlinked_codex_source
run_test "wt create prunes retired project MCP block" test_wt_create_prunes_retired_project_mcp_block
run_test "wt create removes unterminated copied Codex config" test_wt_create_removes_unterminated_copied_codex_config
run_test "wt create removes directory copied Codex config" test_wt_create_removes_directory_copied_codex_config
run_test "codex trust sanitizes unsafe copied Codex config" test_codex_trust_sanitizes_unsafe_copied_codex_config
run_test "wt prepare rejects symlinked Claude dir" test_wt_prepare_rejects_symlinked_claude_dir
run_test "wt prepare skips symlinked source settings" test_wt_prepare_skips_symlinked_source_settings
run_test "wt create trusts Codex project config" test_wt_create_trusts_codex_project
run_test "wt create skips unsafe Codex config path" test_wt_create_skips_unsafe_codex_config
run_test "wt create supports valid Codex projects shapes" test_wt_create_supports_valid_projects_shapes
run_test "wt create preserves unmergeable Codex config" test_wt_create_preserves_unmergeable_codex_config
run_test "wt create inherits Claude local plugin manifest" test_wt_create_inherits_claude_local_plugin_manifest
run_test "wt create ignores branch-tracked plugin settings" test_wt_create_ignores_branch_tracked_plugin_settings
run_test "wt plugin manifest ignores noncanonical adjacent lock directory" test_wt_plugin_manifest_ignores_noncanonical_adjacent_lock_directory
run_test "wt plugin manifest skill projection skips OS errors" test_wt_plugin_manifest_skill_projection_skips_os_errors
run_test "wt plugin manifest cleanup uses stable canonical target" test_wt_plugin_manifest_cleanup_uses_stable_canonical_target
run_test "wt cleanup removes exact Claude local plugin manifest entries" test_wt_cleanup_removes_exact_claude_local_plugin_manifest_entries
run_test "wt cleanup stops when plugin manifest cleanup fails" test_wt_cleanup_stops_when_plugin_manifest_cleanup_fails
run_test "wt plugin manifest missing and invalid inputs are safe" test_wt_plugin_manifest_missing_and_invalid_are_safe
run_test "codex activation .agents symlink guard static" test_codex_activation_agents_symlink_guard_static
run_test "wt recreate guard uses physical paths" test_wt_recreate_guard_uses_physical_paths
run_test "wt cleanup auto removes merged worktree" test_wt_cleanup_auto_removes_merged_worktree
run_test "wt cleanup auto skips dirty merged worktree" test_wt_cleanup_auto_skips_dirty_merged_worktree
run_test "wt cleanup auto skips unpushed merged worktree" test_wt_cleanup_auto_skips_unpushed_with_upstream
run_test "wt cleanup auto skips merged branch reuse" test_wt_cleanup_auto_skips_merged_branch_reuse
run_test "wt cleanup auto survives stale worktree" test_wt_cleanup_auto_survives_stale_worktree
run_test "wt cleanup name-filter survives stale worktree" test_wt_cleanup_name_filter_survives_stale_worktree
run_test "wt cleanup auto broken-only reports skip count" test_wt_cleanup_auto_broken_only_reports_skip_count
run_test "missing managed helpers fail closed" test_missing_managed_helpers_fail_closed
run_test "missing wt Python helpers fail state changes" test_missing_wt_python_helpers_fail_state_changes
run_test "missing wt Python helpers fail cleanup state changes" test_missing_wt_python_helpers_fail_cleanup_state_changes
run_test "codex trust write failure returns warning" test_codex_trust_write_failure_returns_warning
run_test "fixture git setup ignores host global hooks" test_fixture_git_is_hermetic_against_global_hooks
run_test "nixos nrs offline force smoke" test_nixos_nrs_offline_force_smoke
run_test "extract_oos_entries filesystem input" test_extract_oos_entries_filesystem_input
run_test "extract_oos_entries git show input" test_extract_oos_entries_git_show_input
run_test "extract_oos_entries empty and absent exit zero" test_extract_oos_entries_empty_and_absent_exit_zero
run_test "stale filter supports clean symlinked user hooks" test_user_hooks_stale_filter_supports_clean_symlink_target
run_test "stale filter detects symlinked stale user hooks" test_user_hooks_stale_filter_detects_symlink_target_stale_entries
run_test "stale filter ignores stale path mentions" test_user_hooks_stale_filter_ignores_stale_path_mentions
run_test "stale filter detects exact HOME hook path" test_user_hooks_stale_filter_detects_exact_home_path
run_test "retired hook cleanup preserves malformed user hooks" test_clear_retired_codex_hook_artifacts_preserves_malformed_user_hooks
run_test "retired hook cleanup preserves symlinked user hooks" test_clear_retired_codex_hook_artifacts_preserves_symlinked_user_hooks
run_test "retired hook cleanup removes dangling artifact symlinks" test_clear_retired_codex_hook_artifacts_removes_dangling_artifact_symlinks
run_test "check-skill-noise staged mode reads index snapshot" test_check_skill_noise_staged_reads_index_snapshot
run_test "check-skill-noise staged mode normalizes CRLF" test_check_skill_noise_staged_normalizes_crlf
run_test "check-skill-noise staged mode follows symlink projection" test_check_skill_noise_staged_follows_symlink_projection
run_test "check-skill-noise staged mode rejects non-regular markdown" test_check_skill_noise_staged_rejects_non_regular_markdown
run_test "check-skill-noise follows symlink skill projection" test_check_skill_noise_worktree_follows_symlink_projection
run_test "check-skill-noise rejects external symlink skill projection" test_check_skill_noise_worktree_rejects_external_symlink
run_test "warn-skill-consistency ignores managed plugin skill projection" test_warn_skill_consistency_ignores_managed_plugin_skill_projection
run_test "darwin nrs offline force smoke" test_darwin_nrs_offline_force_smoke
run_test "darwin nrs no-change releases worktree lock" test_darwin_nrs_no_changes_releases_worktree_lock
run_test "install-lefthook cleans up redundant local core.hooksPath" test_install_lefthook_cleanup_local_redundant
run_test "install-lefthook preserves custom local core.hooksPath" test_install_lefthook_preserves_custom_local
run_test "install-lefthook is silent on clean state" test_install_lefthook_silent_on_clean_state
run_test "install-lefthook serializes concurrent invocations" test_install_lefthook_concurrent_install_serializes
run_test "install-lefthook pins worktree-local hooks path in worktree mode" test_install_lefthook_worktree_mode_pins_local_hooks_path
run_test "fragile-hardcoding-guard line count word order independent" test_fragile_hardcoding_guard_line_count_word_order_independent
run_test "fragile-hardcoding-guard line count true positive preserved" test_fragile_hardcoding_guard_line_count_true_positive_preserved

# codex-config fixture는 tomlkit이 필요하다. lefthook pre-push는 `nix shell` wrap으로
# 항상 tomlkit을 제공하지만, 사용자가 직접 실행할 때는 미가용일 수 있다. 미가용이면
# codex-config 섹션만 skip + 안내 (기본 shell suite 진입은 유지).
if codex_config_tomlkit_available; then
  run_test "codex-config sync fixtures" test_codex_config_sync_fixtures
  run_test "codex-config sync no-op preserves bytes" test_codex_config_sync_noop_preserves_bytes
  run_test "codex-config sync rewrites on bad mode" test_codex_config_sync_rejects_bad_mode
  run_test "codex-config sync rewrites on symlink" test_codex_config_sync_rejects_symlink
  run_test "codex-config bare 2-arg compat" test_codex_config_bare_sync_compat
  run_test "codex-config check fixtures" test_codex_config_check_fixtures
  run_test "codex-config merge_template_into unit" test_codex_config_merge_template_into_unit
  run_test "codex-config collect_drift unit" test_codex_config_collect_drift_unit
else
  echo "==> codex-config fixtures: SKIPPED (tomlkit 미가용; 'nix shell .#pythonWithTomlkit --command bash tests/run-shell-script-tests.sh'로 전건 실행 권장; pre-push hook은 자동 wrap됨)" >&2
fi
