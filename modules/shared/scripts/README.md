# Shared Script Layout

운영 엔트리포인트는 top-level 파일명과 CLI surface를 유지하고, 실제 구현은 책임별 helper로 분리한다.

## Refactor Scope

- `wt.sh`: user-facing worktree CLI thin wrapper
- `rebuild-common.sh`: `nrs`/`nrp`가 source하는 compatibility loader (`~/.local/lib/` 배포, 직접 실행 아님)
- `nrs-relink.sh`: standalone relink CLI. 이번 helper 분해 범위 밖의 독립 스크립트다.

## Contract Source

- 이 파일이 shared shell helper contract의 authoritative source다.
- top-level loader 주석은 이 파일을 요약할 수는 있지만, 서로 다른 contract를 정의하면 안 된다.
- `tests/shell-script-tests.sh`는 이 파일의 contract를 runtime/deployed-layout 기준으로 검증한다.
- 테스트의 `register_*` 함수는 Nix wiring assertion과 fixture install을 함께 수행한다. 이는 fixture 생성 편의를 위한 것이지, authoritative source가 아니다. Nix 선언(`default.nix`, `darwin.nix`, `nixos.nix`)이 배포 계약의 authoritative source다.

## Helper Boundaries

- `lib/wt/ui.sh`: prompt, formatting, repo/path helpers
- `lib/wt/tmux.sh`: tmux window/session orchestration
- `lib/wt/git-state.sh`: git/worktree state collection, PR status lookup
- `lib/wt/bootstrap.sh`: worktree bootstrap, open, remove orchestration
- `lib/wt/create.sh`: create/recreate flows and existing-branch handling
- `lib/wt/navigate.sh`: `wt cd` / `wt ls`
- `lib/wt/cleanup.sh`: `wt cleanup`
- `lib/rebuild/common.sh`: logging, worktree detection, argument parsing
- `lib/rebuild/worktree.sh`: `mkOutOfStoreSymlink` drift guard
- `lib/rebuild/locks.sh`: cooperative nrs/rebuild locking
- `lib/rebuild/preflight.sh`: source-build and cask preflight checks
- `lib/rebuild/relink.sh`: worktree symlink cleanup/relink/restore helpers
- `lib/rebuild/preview.sh`: build preview and artifact cleanup

## Rebuild Contract

- Public rebuild helpers:
  `parse_args`, `log_info`, `log_warn`, `log_error`, `worktree_symlink_guard`,
  `acquire_nrs_lock`, `release_nrs_lock`, `release_nrs_lock_after_no_changes`,
  `release_nrs_lock_on_failure`, `mark_nrs_lock_switch_success`,
  `acquire_rebuild_lock`, `release_rebuild_lock`, `release_rebuild_lock_on_failure`,
  `preflight_source_build_check`, `preflight_cask_conflict_check`,
  `rebuild_is_main_flake`, `prepare_worktree_symlinks_for_rebuild`,
  `maybe_relink_or_restore`, `preview_changes`, `cleanup_build_artifacts`
- Public caller-visible rebuild state:
  `FLAKE_PATH`, `OFFLINE_FLAG`, `NO_CHANGES`, `FORCE_FLAG`, `CORES_FLAG`, `UNINSTALLED_CASKS`
- Internal rebuild state:
  `MAIN_FLAKE_PATH`, `NRS_LOCK_ACQUIRED`, `NRS_LOCK_REENTRY`, `NRS_LOCK_SWITCH_SUCCESS`
- Caller는 underscored helper와 internal rebuild state를 직접 참조하지 않는다.

## wt Contract

- `WT_HELPERS`의 membership과 source order는 계속 계약이다.
- `WT_LAST_FILE`의 읽기/쓰기는 `lib/wt/git-state.sh` helper를 통해서만 공유한다.
- `WORKTREE_DIR`는 top-level constant contract로 유지한다. 이번 범위에서는 generic accessor layer로 승격하지 않는다.

## Rules

- Top-level entrypoints stay thin. New runtime logic belongs in a helper file unless it is dispatch/help text.
- Helpers are grouped by change reason, not by arbitrary line counts.
- Loader source order is part of the contract. The ordered helper manifest in each top-level entrypoint is the single source of truth for helper membership and load order.
- If a new helper is added under an existing helper directory, update the entrypoint helper manifest and tests together. `modules/shared/programs/shell/default.nix` only needs changes for new top-level entrypoints or new helper directories. New deployment entries must add a `register_*` call in `install_deployed_layout()` or `install_platform_nrs_entrypoint()`.
- `tests/shell-script-tests.sh` must stay hermetic and recursive-layout aware: it should ignore host Git hooks/config and mirror the deployed helper tree shape, not a flat copy.
- Tests must exercise the deployed layout, not only the repo-local path. `tests/shell-script-tests.sh` should validate both the expected Home Manager wiring and runtime smoke paths.
- Public surface smoke를 유지하되, ordered helper manifest/order contract를 검증하는 최소 fixture test도 유지한다.
