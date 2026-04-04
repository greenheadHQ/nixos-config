# Shared Script Layout

운영 엔트리포인트는 top-level 파일명과 CLI surface를 유지하고, 실제 구현은 책임별 helper로 분리한다.

## Refactor Scope

- `wt.sh`: user-facing worktree CLI thin wrapper
- `rebuild-common.sh`: `nrs`/`nrp`가 source하는 compatibility loader (`~/.local/lib/` 배포, 직접 실행 아님)
- `nrs-relink.sh`: standalone relink CLI. 이번 helper 분해 범위 밖의 독립 스크립트다.

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

## Rules

- Top-level entrypoints stay thin. New runtime logic belongs in a helper file unless it is dispatch/help text.
- Helpers are grouped by change reason, not by arbitrary line counts.
- Loader source order is part of the contract. The ordered helper manifest in each top-level entrypoint is the single source of truth for helper membership and load order.
- If a new helper is added under an existing helper directory, update the entrypoint helper manifest and tests together. `modules/shared/programs/shell/default.nix` only needs changes for new top-level entrypoints or new helper directories.
- `tests/shell-script-tests.sh` must stay hermetic and recursive-layout aware: it should ignore host Git hooks/config and mirror the deployed helper tree shape, not a flat copy.
- Tests must exercise the deployed layout, not only the repo-local path. `tests/shell-script-tests.sh` should validate both the expected Home Manager wiring and runtime smoke paths.
