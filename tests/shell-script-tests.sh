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
if [ "$(uname -s)" = "Linux" ]; then
  run_test "codex remote-control probe parses daemon JSON" test_codex_remote_control_probe_parses_daemon_json
  run_test "codex remote-control probe marks malformed daemon JSON" test_codex_remote_control_probe_marks_malformed_daemon_json
  run_test "codex remote-control ensure-running rejects malformed daemon JSON" test_codex_remote_control_ensure_running_rejects_malformed_daemon_json
  run_test "codex remote-control starts when daemon absent" test_codex_remote_control_ensure_running_starts_when_absent
  run_test "codex remote-control rejects stale start versions" test_codex_remote_control_rejects_stale_start_versions
  run_test "codex remote-control auth failure is non-destructive" test_codex_remote_control_auth_failure_is_non_destructive
  run_test "codex remote-control login status is sanitized" test_codex_remote_control_login_status_is_sanitized
  run_test "codex remote-control missing operator reason is preserved" test_codex_remote_control_missing_operator_reason_is_preserved
  run_test "codex remote-control removes standalone PATH shadow" test_codex_remote_control_removes_standalone_path_shadow
  run_test "codex remote-control rejects direct standalone PATH shadow" test_codex_remote_control_rejects_direct_standalone_path_shadow
  run_test "codex remote-control rejects non-Nix PATH shadow" test_codex_remote_control_rejects_non_nix_path_shadow
  run_test "codex remote-control sync failure is not marked successful" test_codex_remote_control_sync_failure_is_not_marked_successful
  run_test "codex remote-control lock failure does not run core action" test_codex_remote_control_lock_failure_does_not_run_core_action
  run_test "codex remote-control lock acquisition timeout is recorded" test_codex_remote_control_lock_acquire_timeout_is_recorded
  run_test "codex remote-control spawned daemon does not inherit lock fd" test_codex_remote_control_spawned_daemon_does_not_inherit_lock_fd
  run_test "codex remote-control repair kills proven stale process" test_codex_remote_control_repair_kills_proven_stale_unmanaged_process
  run_test "codex remote-control repair refuses socket cleanup when PID remains" test_codex_remote_control_repair_refuses_socket_cleanup_when_pid_remains
  run_test "codex remote-control repair refuses unproven stale process" test_codex_remote_control_repair_does_not_kill_without_stale_proof
  run_test "codex remote-control repair refuses version-drift-only kill" test_codex_remote_control_repair_does_not_kill_on_version_drift_only
  run_test "codex remote-control repair preserves current managed app-server" test_codex_remote_control_repair_preserves_current_managed_app_server
  run_test "codex remote-control repair reaps stale deleted managed app-server" test_codex_remote_control_repair_kills_stale_deleted_managed_app_server
  run_test "codex remote-control repair reaps superseded managed app-server" test_codex_remote_control_repair_kills_stale_superseded_managed_app_server
  run_test "codex remote-control cleans sockets only when no PID after drift" test_codex_remote_control_socket_cleanup_when_no_pid_after_drift
  run_test "codex remote-control alert recovers after failure" test_codex_remote_control_alert_recovery_after_failure
  run_test "codex remote-control alert stays quiet on healthy success" test_codex_remote_control_alert_success_without_failure_is_quiet
  run_test "codex remote-control alert failure cooldown is stateful" test_codex_remote_control_alert_failure_sets_failed_and_cools_down
  run_test "codex remote-control alert missing token does not mutate state" test_codex_remote_control_alert_without_pushover_token_does_not_mutate_state
  run_test "codex remote-control sync links current standalone release" test_codex_remote_control_sync_standalone_package_success_links_current_release
  run_test "codex remote-control sync extract failure propagates status" test_codex_remote_control_sync_extract_failure_propagates_status
  run_test "codex remote-control sync records login status paths" test_codex_remote_control_sync_records_login_status_success_and_api_key_paths
else
  echo "==> codex remote-control fixtures: SKIPPED (Linux/NixOS-only service script)" >&2
fi
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
run_test "nixos nrs no-change activates when Codex artifact missing" test_nixos_nrs_no_changes_activates_when_codex_artifact_missing
run_test "extract_oos_entries filesystem input" test_extract_oos_entries_filesystem_input
run_test "extract_oos_entries git show input" test_extract_oos_entries_git_show_input
run_test "extract_oos_entries empty and absent exit zero" test_extract_oos_entries_empty_and_absent_exit_zero
run_test "verify-ai-compat Codex artifact contract static" test_verify_ai_compat_codex_artifact_contract_static
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
run_test "darwin nrs no-change activates when Codex artifact missing" test_darwin_nrs_no_changes_activates_when_codex_artifact_missing
run_test "install-lefthook cleans up redundant local core.hooksPath" test_install_lefthook_cleanup_local_redundant
run_test "install-lefthook preserves custom local core.hooksPath" test_install_lefthook_preserves_custom_local
run_test "install-lefthook is silent on clean state" test_install_lefthook_silent_on_clean_state
run_test "install-lefthook serializes concurrent invocations" test_install_lefthook_concurrent_install_serializes
run_test "install-lefthook pins worktree-local hooks path in worktree mode" test_install_lefthook_worktree_mode_pins_local_hooks_path
run_test "webhook-bridge crawled payload sends notification" test_webhook_bridge_crawled_payload_sends_notification
run_test "webhook-bridge non-crawled payload skips notification" test_webhook_bridge_non_crawled_payload_skips_notification
run_test "webhook-bridge invalid JSON keeps 200 without notification" test_webhook_bridge_invalid_json_keeps_200_without_notification
run_test "webhook-bridge matching token sends notification" test_webhook_bridge_matching_token_sends_notification
run_test "webhook-bridge wrong token keeps 200 and warns" test_webhook_bridge_wrong_token_keeps_200_and_warns
run_test "pushover helper missing credential skips curl" test_pushover_send_missing_cred_returns_1_without_curl
run_test "pushover helper sends expected fields" test_pushover_send_success_passes_expected_fields
run_test "pushover helper passes optional sound" test_pushover_send_passes_optional_sound
run_test "pushover helper curl failure returns nonzero" test_pushover_send_curl_failure_returns_1
run_test "immich backup happy path creates dump atomically" test_immich_backup_happy_path_creates_dump_atomically
run_test "immich backup integrity failure exits nonzero" test_immich_backup_integrity_failure_exits_nonzero
run_test "immich backup retention deletes only old dumps in dir" test_immich_backup_retention_deletes_only_old_dumps_in_dir
run_test "karakeep backup happy path dated dir" test_karakeep_backup_happy_path_dated_dir
run_test "karakeep backup missing db exits nonzero" test_karakeep_backup_missing_db_exits_nonzero
run_test "karakeep backup retention scopes to backup dir" test_karakeep_backup_retention_scopes_to_backup_dir
run_test "fragile-hardcoding-guard line count word order independent" test_fragile_hardcoding_guard_line_count_word_order_independent
run_test "fragile-hardcoding-guard line count true positive preserved" test_fragile_hardcoding_guard_line_count_true_positive_preserved
run_test "fragile-hardcoding-guard edit true positive preserved" test_fragile_hardcoding_guard_edit_true_positive_preserved
run_test "fragile-hardcoding-guard empty and malformed input noop" test_fragile_hardcoding_guard_empty_and_malformed_input_noop
run_test "log-skill normal input logs usage" test_log_skill_hook_normal_input_logs_usage
run_test "log-skill empty malformed and subagent noop" test_log_skill_hook_empty_malformed_and_subagent_noop
run_test "nrs-session-cleanup empty malformed and nonrepo noop" test_nrs_session_cleanup_hook_empty_malformed_and_nonrepo_input_noop
run_test "plans-gc removes old transient buffer" test_plans_gc_hook_removes_old_transient_buffer
run_test "plans-gc empty and malformed input noop" test_plans_gc_hook_empty_and_malformed_input_noop
run_test "record-last-session normal input writes marker" test_record_last_session_hook_normal_input_writes_marker
run_test "record-last-session empty malformed and subagent noop" test_record_last_session_hook_empty_malformed_and_subagent_noop
run_test "session-init-icons startup creates state and context" test_session_init_icons_hook_startup_creates_state_and_context
run_test "session-init-icons empty and malformed input noop" test_session_init_icons_hook_empty_and_malformed_input_noop
run_test "system-bash-guard denies bash write and edit patterns" test_system_bash_guard_hook_denies_bash_write_and_edit_patterns
run_test "system-bash-guard empty and malformed input noop" test_system_bash_guard_hook_empty_and_malformed_input_noop
run_test "worktree-path-guard main repo session always allows" test_worktree_path_guard_main_repo_session_always_allows
run_test "worktree-path-guard denies main repo file from worktree" test_worktree_path_guard_denies_main_repo_file_from_worktree
run_test "worktree-path-guard allows own worktree file" test_worktree_path_guard_allows_own_worktree_file
run_test "worktree-path-guard allows sibling worktree file" test_worktree_path_guard_allows_sibling_worktree_file
run_test "worktree-path-guard allows main repo plan path exception" test_worktree_path_guard_allows_main_repo_plan_path_exception
run_test "worktree-path-guard empty and malformed input noop" test_worktree_path_guard_empty_and_malformed_input_noop
run_test "immich originals mirror skips rsync on empty source" test_immich_originals_mirror_empty_source_skips_rsync
run_test "immich cleanup paginates v3 nextPage string" test_immich_cleanup_v3_paginates_next_page_string
run_test "immich cleanup preserves empty album notification" test_immich_cleanup_v3_empty_album_preserves_notification
run_test "immich cleanup rejects invalid asset id" test_immich_cleanup_v3_rejects_invalid_asset_id
run_test "immich cleanup rejects invalid nextPage" test_immich_cleanup_v3_rejects_invalid_next_page
run_test "hook_init_scan_dir falls back when TMPDIR missing" test_hook_init_scan_dir_falls_back_when_tmpdir_missing
run_test "hook_init_scan_dir falls back when TMPDIR unwritable" test_hook_init_scan_dir_falls_back_when_tmpdir_unwritable
run_test "hook_init_scan_dir falls back when system tmp unusable" test_hook_init_scan_dir_falls_back_to_user_cache_when_system_tmp_unusable
run_test "hook_init_scan_dir uses valid TMPDIR" test_hook_init_scan_dir_uses_valid_tmpdir
run_test "hook_parse_json_path preserves filter defaults" test_hook_parse_json_path_preserves_filter_defaults
run_test "hook_parse_json_path malformed input returns empty success" test_hook_parse_json_path_malformed_input_returns_empty_success
run_test "pinning-guard survives set-but-unusable TMPDIR (e2e)" test_pinning_guard_survives_unusable_tmpdir

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
  run_test "codex-config check rejects invalid UTF-8 target" test_codex_config_check_rejects_invalid_utf8_target
  run_test "codex-config check rejects non-regular target" test_codex_config_check_rejects_nonregular_target
  run_test "codex-config merge_template_into unit" test_codex_config_merge_template_into_unit
  run_test "codex-config collect_drift unit" test_codex_config_collect_drift_unit
  run_test "codex-config repair semantic parse lazy unit" test_codex_config_repair_semantic_parse_is_lazy_unit
else
  echo "==> codex-config fixtures: SKIPPED (tomlkit 미가용; 'nix shell .#pythonWithTomlkit --command bash tests/run-shell-script-tests.sh'로 전건 실행 권장; pre-push hook은 자동 wrap됨)" >&2
fi
