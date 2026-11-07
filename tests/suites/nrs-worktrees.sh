# shellcheck shell=bash
# SC2034: fixture helper가 호출자의 local 변수에 결과를 채운다.
# SC2153: REPO_ROOT는 suite aggregator가 설정한다.
# shellcheck disable=SC2034,SC2153
# 합성 Git/HMF/HOME만 사용한다. 시스템 nix store나 사용자 링크는 변경하지 않는다.
setup_nrs_worktree_fixture() {
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  hmf="$sandbox/home-manager-files"
  worktree_root="$sandbox/external worktree"$'\t|\n'
  create_git_fixture_repo "$repo_root"
  repo_root=$(cd "$repo_root" && pwd -P)
  worktree_root="$(cd "$sandbox" && pwd -P)/external worktree"$'\t|\n'
  add_fixture_worktree "$repo_root" "$worktree_root" external-fixture
  mkdir -p "$home_dir/.claude" "$home_dir/.local/bin" "$hmf/.claude"
  printf 'managed\n' > "$repo_root/CLAUDE.md"
  printf 'worktree\n' > "$worktree_root/CLAUDE.md"
  ln -s "$repo_root/CLAUDE.md" "$hmf/.claude/CLAUDE.md"
  install_nrs_worktree_fixture_cli
}

install_nrs_worktree_fixture_cli() {
  _nrs_relink_functions_src > "$sandbox/nrs-functions.sh"
  cat > "$home_dir/.local/bin/nrs-relink" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
source "$NRS_FIXTURE_FUNCTIONS"
MAIN_REPO=$NRS_FIXTURE_MAIN
_discover_hmf() { printf '%s\n' "$NRS_FIXTURE_HMF"; }
# 합성 HMF는 nix store 체인이 아니다. 이 회귀는 경로 선택과 홈 보존만 검증한다.
_check_oos_chain() { :; }
if [[ -n "${NRS_FIXTURE_CALLS:-}" ]]; then printf '%s\n' "$1" >> "$NRS_FIXTURE_CALLS"; fi
command_name=${1//-/_}
shift
"cmd_$command_name" "$@"
WRAPPER
  chmod +x "$home_dir/.local/bin/nrs-relink"
}
run_nrs_worktree_fixture() {
  HOME="$home_dir" XDG_CONFIG_HOME="$home_dir/.config" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 NRS_FIXTURE_FUNCTIONS="$sandbox/nrs-functions.sh" \
    NRS_FIXTURE_MAIN="$repo_root" NRS_FIXTURE_HMF="$hmf" \
    "$home_dir/.local/bin/nrs-relink" "$@"
}

test_nrs_external_worktree_inspect_and_restore_special_paths() {
  local sandbox home_dir repo_root hmf worktree_root
  setup_nrs_worktree_fixture
  local relative=$'.claude/pipe|line\n' suffix=$'file|\n'
  printf 'special\n' > "$repo_root/$suffix"
  printf 'special\n' > "$worktree_root/$suffix"
  ln -s "$repo_root/$suffix" "$hmf/$relative"
  ln -s "$worktree_root/CLAUDE.md" "$home_dir/.claude/CLAUDE.md"
  ln -s "$worktree_root/$suffix" "$home_dir/$relative"
  run_nrs_worktree_fixture needs-restore
  [[ -L "$home_dir/.claude/CLAUDE.md" && -L "$home_dir/$relative" ]] || fail 'restore inspection must never remove links'
  [[ "$(readlink -n "$home_dir/.claude/CLAUDE.md"; printf '.')" == "$worktree_root/CLAUDE.md." ]] || fail 'inspection changed canary target'
  [[ "$(readlink -n "$home_dir/$relative"; printf '.')" == "$worktree_root/$suffix." ]] || fail 'inspection changed special target'
  run_nrs_worktree_fixture restore
  [[ "$(readlink "$home_dir/.claude/CLAUDE.md")" == "$hmf/.claude/CLAUDE.md" ]] || fail 'expected canary restored'
  [[ "$(cat "$home_dir/$relative")" == special ]] || fail 'expected NUL-delimited mapping restored'
  [[ "$(readlink -n "$home_dir/$relative"; printf '.')" == "$hmf/$relative." ]] || fail 'expected special path restored to HMF'
  (cd "$worktree_root" || exit; run_nrs_worktree_fixture relink)
  [[ "$(readlink -n "$home_dir/$relative"; printf '.')" == "$worktree_root/$suffix." ]] || fail 'expected special path relinked to worktree'
}

test_nrs_missing_parents_restore_without_inspection_writes() {
  local sandbox home_dir repo_root hmf worktree_root
  setup_nrs_worktree_fixture
  mkdir -p "$hmf/.claude/nested/deeper"
  ln -s "$repo_root/CLAUDE.md" "$hmf/.claude/nested/deeper/config"
  rmdir "$home_dir/.claude"
  run_nrs_worktree_fixture needs-restore
  [[ ! -e "$home_dir/.claude" ]] || fail 'inspection created a missing parent'
  run_nrs_worktree_fixture restore
  [[ "$(readlink "$home_dir/.claude/CLAUDE.md")" == "$hmf/.claude/CLAUDE.md" ]] || fail 'missing canary parent was not restored'
  [[ "$(readlink "$home_dir/.claude/nested/deeper/config")" == "$hmf/.claude/nested/deeper/config" ]] || fail 'missing nested parents were not restored'
  [[ ! -e "$home_dir/.codex" ]] || fail 'restore created a directory absent from HMF mappings'
}

test_nrs_missing_parents_preserve_unsafe_ancestors() {
  local sandbox home_dir repo_root hmf worktree_root kind rc target
  for kind in regular symlink dangling; do
    setup_nrs_worktree_fixture
    mkdir -p "$hmf/.claude/nested"
    ln -s "$repo_root/CLAUDE.md" "$hmf/.claude/nested/config"
    rmdir "$home_dir/.claude"
    target="$sandbox/user-directory"
    case "$kind" in
      regular) printf 'personal\n' > "$home_dir/.claude" ;;
      symlink) mkdir "$target"; ln -s "$target" "$home_dir/.claude" ;;
      dangling) ln -s "$target" "$home_dir/.claude" ;;
    esac
    rc=0
    run_nrs_worktree_fixture needs-restore || rc=$?
    [[ "$rc" == 1 ]] || fail "unsafe parent classified as restorable: $kind"
    run_nrs_worktree_fixture restore
    if [[ "$kind" == regular ]]; then
      [[ "$(cat "$home_dir/.claude")" == personal ]] || fail 'regular parent overwritten'
    else
      [[ "$(readlink "$home_dir/.claude")" == "$target" ]] || fail 'symlink parent overwritten'
      [[ ! -e "$target/nested" && ! -e "$target/CLAUDE.md" ]] || fail 'restore traversed a symlink parent'
    fi
  done
}

test_nrs_hmf_listing_failure_never_mutates_entries() {
  local sandbox home_dir repo_root hmf worktree_root mode action rc expected target real_find output
  real_find=$(command -v find)
  for mode in empty partial; do
    setup_nrs_worktree_fixture
    mkdir "$sandbox/stub-bin"
    cat > "$sandbox/stub-bin/find" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "$NRS_FIXTURE_HMF" ]]; then
  if [[ "$NRS_FIND_FAILURE" == partial ]]; then
    printf '%s\0' "$NRS_FIXTURE_HMF/.claude/CLAUDE.md"
  fi
  exit 23
fi
exec "$NRS_REAL_FIND" "$@"
STUB
    chmod +x "$sandbox/stub-bin/find"
    for action in needs-restore restore relink; do
      target="$worktree_root/CLAUDE.md"
      [[ "$action" != relink ]] || target="$hmf/.claude/CLAUDE.md"
      ln -sfn "$target" "$home_dir/.claude/CLAUDE.md"
      rc=0
      output=$(cd "$worktree_root" || exit; PATH="$sandbox/stub-bin:$PATH" NRS_REAL_FIND="$real_find" \
        NRS_FIND_FAILURE="$mode" run_nrs_worktree_fixture "$action" 2>&1) || rc=$?
      expected=1
      [[ "$action" != needs-restore ]] || expected=2
      [[ "$rc" == "$expected" ]] || fail "$mode HMF enumeration failure: $action returned $rc, expected $expected"
      assert_contains "$output" 'Could not enumerate home-manager-files mappings'
      [[ "$(readlink -n "$home_dir/.claude/CLAUDE.md"; printf '.')" == "$target." ]] || fail "$action changed a link after $mode enumeration failure"
    done
  done
}

test_nrs_external_worktree_relink_rejects_other_repository() {
  local sandbox home_dir repo_root hmf worktree_root output rc=0
  setup_nrs_worktree_fixture
  ln -s "$hmf/.claude/CLAUDE.md" "$home_dir/.claude/CLAUDE.md"
  (cd "$worktree_root" || exit; run_nrs_worktree_fixture relink)
  [[ "$(cat "$home_dir/.claude/CLAUDE.md")" == worktree ]] || fail 'expected registered external worktree relink'
  mkdir "$sandbox/other"
  HOME="$home_dir" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$sandbox/other" -c core.hooksPath=/dev/null -c init.templateDir= init --quiet
  output=$(cd "$sandbox/other" || exit; run_nrs_worktree_fixture relink 2>&1) || rc=$?
  [[ "$rc" == 1 ]] || fail 'expected unrelated repository refusal'
  assert_contains "$output" 'not a registered worktree'
  [[ "$(cat "$home_dir/.claude/CLAUDE.md")" == worktree ]] || fail 'expected unrelated repository to leave link untouched'
}

test_nrs_restore_preserves_user_entries() {
  local sandbox home_dir repo_root hmf worktree_root kind
  setup_nrs_worktree_fixture
  for kind in regular directory symlink parent; do
    rm -rf "$home_dir/.claude"
    mkdir "$home_dir/.claude"
    case "$kind" in
      regular) printf 'personal\n' > "$home_dir/.claude/CLAUDE.md" ;;
      directory) mkdir "$home_dir/.claude/CLAUDE.md" ;;
      symlink) ln -s "$worktree_root/other.md" "$home_dir/.claude/CLAUDE.md" ;;
      parent)
        rmdir "$home_dir/.claude"
        mkdir "$sandbox/user-directory"
        ln -s "$sandbox/user-directory" "$home_dir/.claude"
        ln -s "$worktree_root/CLAUDE.md" "$home_dir/.claude/CLAUDE.md"
        ;;
    esac
    run_nrs_worktree_fixture restore
    case "$kind" in
      regular) [[ "$(cat "$home_dir/.claude/CLAUDE.md")" == personal ]] || fail 'regular file overwritten' ;;
      directory) [[ -d "$home_dir/.claude/CLAUDE.md" && ! -L "$home_dir/.claude/CLAUDE.md" ]] || fail 'directory overwritten' ;;
      symlink) [[ "$(readlink "$home_dir/.claude/CLAUDE.md")" == "$worktree_root/other.md" ]] || fail 'unrelated symlink overwritten' ;;
      parent) [[ "$(readlink "$home_dir/.claude/CLAUDE.md")" == "$worktree_root/CLAUDE.md" ]] || fail 'symlink parent traversed' ;;
    esac
  done
}

test_nrs_relink_reports_preserved_entries_separately() {
  local sandbox home_dir repo_root hmf worktree_root output
  setup_nrs_worktree_fixture
  printf 'personal\n' > "$home_dir/.claude/CLAUDE.md"
  output=$(cd "$worktree_root" || exit; run_nrs_worktree_fixture relink 2>&1)
  [[ "$(cat "$home_dir/.claude/CLAUDE.md")" == personal ]] || fail 'relink overwrote a regular file'
  assert_contains "$output" 'skip: .claude/CLAUDE.md (preserved user or unverified entry)'
  assert_contains "$output" '(1 preserved'
  assert_not_contains "$output" 'not in worktree'
}

test_nrs_deleted_registered_worktree_restores_dangling_mapping() {
  local sandbox home_dir repo_root hmf worktree_root
  setup_nrs_worktree_fixture
  ln -s "$worktree_root/CLAUDE.md" "$home_dir/.claude/CLAUDE.md"
  rm -rf "$worktree_root"
  run_nrs_worktree_fixture restore
  [[ "$(readlink "$home_dir/.claude/CLAUDE.md")" == "$hmf/.claude/CLAUDE.md" ]] || fail 'deleted registered worktree not restored'
}

test_nrs_replaced_worktree_and_similar_prefix_are_preserved() {
  local sandbox home_dir repo_root hmf worktree_root kind rc
  setup_nrs_worktree_fixture
  for kind in prefix replaced traversal; do
    rm -f "$home_dir/.claude/CLAUDE.md"
    case "$kind" in
      prefix) ln -s "${worktree_root}other/CLAUDE.md" "$home_dir/.claude/CLAUDE.md" ;;
      replaced)
        rm -rf "$worktree_root"
        mkdir "$worktree_root"
        HOME="$home_dir" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$worktree_root" -c core.hooksPath=/dev/null -c init.templateDir= init --quiet
        ln -s "$worktree_root/CLAUDE.md" "$home_dir/.claude/CLAUDE.md"
        ;;
      traversal) ln -s "$repo_root/.claude/worktrees/../../other/CLAUDE.md" "$home_dir/.claude/CLAUDE.md" ;;
    esac
    rc=0
    run_nrs_worktree_fixture needs-restore || rc=$?
    [[ "$rc" == 1 && -L "$home_dir/.claude/CLAUDE.md" ]] || fail "unsafe pruning: $kind"
    run_nrs_worktree_fixture restore
    [[ "$(readlink "$home_dir/.claude/CLAUDE.md")" != "$hmf/.claude/CLAUDE.md" ]] || fail "unsafe restore: $kind"
  done
}

test_nrs_partial_git_listing_cannot_mutate_links() {
  local sandbox home_dir repo_root hmf worktree_root rc=0 real_git
  setup_nrs_worktree_fixture
  ln -s "$worktree_root/CLAUDE.md" "$home_dir/.claude/CLAUDE.md"
  real_git=$(command -v git)
  mkdir "$sandbox/stub-bin"
  cat > "$sandbox/stub-bin/git" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *'worktree list'* ]]; then
  printf 'worktree %s\0\0' "$NRS_PARTIAL_ROOT"
  exit 1
fi
exec "$NRS_REAL_GIT" "$@"
STUB
  chmod +x "$sandbox/stub-bin/git"
  PATH="$sandbox/stub-bin:$PATH" NRS_REAL_GIT="$real_git" NRS_PARTIAL_ROOT="$worktree_root" run_nrs_worktree_fixture needs-restore || rc=$?
  [[ "$rc" == 2 && -L "$home_dir/.claude/CLAUDE.md" ]] || fail 'partial Git failure pruned a link'
  PATH="$sandbox/stub-bin:$PATH" NRS_REAL_GIT="$real_git" NRS_PARTIAL_ROOT="$worktree_root" run_nrs_worktree_fixture restore
  [[ "$(readlink "$home_dir/.claude/CLAUDE.md")" == "$worktree_root/CLAUDE.md" ]] || fail 'partial Git failure restored an unverified worktree link'
}

test_nrs_main_restore_runs_once_when_canary_missing() {
  local sandbox home_dir repo_root hmf worktree_root
  setup_nrs_worktree_fixture
  ln -s "$worktree_root/CLAUDE.md" "$home_dir/.claude/CLAUDE.md"
  rm "$home_dir/.claude/CLAUDE.md"
  HOME="$home_dir" XDG_CONFIG_HOME="$home_dir/.config" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 NRS_FIXTURE_FUNCTIONS="$sandbox/nrs-functions.sh" \
    NRS_FIXTURE_MAIN="$repo_root" NRS_FIXTURE_HMF="$hmf" NRS_FIXTURE_CALLS="$sandbox/calls" \
    bash -c '
      set -euo pipefail
      source "$1"
      FLAKE_PATH=$NRS_FIXTURE_MAIN MAIN_FLAKE_PATH=$NRS_FIXTURE_MAIN
      log_info() { :; }; log_warn() { :; }
      maybe_relink_or_restore
    ' -- "$REPO_ROOT/modules/shared/scripts/lib/rebuild/relink.sh"
  assert_line_count "$sandbox/calls" restore 1
  [[ "$(readlink "$home_dir/.claude/CLAUDE.md")" == "$hmf/.claude/CLAUDE.md" ]] || fail 'canary disappeared without restoration'
}

test_nrs_legacy_unregistered_worktree_restores_exact_mapping() {
  local sandbox home_dir repo_root hmf worktree_root
  setup_nrs_worktree_fixture
  ln -s "$repo_root/.claude/worktrees/deleted/CLAUDE.md" "$home_dir/.claude/CLAUDE.md"
  run_nrs_worktree_fixture restore
  [[ "$(readlink "$home_dir/.claude/CLAUDE.md")" == "$hmf/.claude/CLAUDE.md" ]] || fail 'legacy unregistered exact mapping not restored'
}

test_nrs_worktree_only_entry_is_preserved_with_warning() {
  local sandbox home_dir repo_root hmf worktree_root output rc=0
  setup_nrs_worktree_fixture
  ln -s "$hmf/.claude/CLAUDE.md" "$home_dir/.claude/CLAUDE.md"
  ln -s "$worktree_root/new-entry.md" "$home_dir/.claude/new-entry.md"
  output=$(run_nrs_worktree_fixture needs-restore 2>&1) || rc=$?
  [[ "$rc" == 1 && -L "$home_dir/.claude/new-entry.md" ]] || fail 'entry absent from current HMF must be preserved'
  assert_contains "$output" 'Preserved worktree link'
}

test_detect_external_worktree_preserves_trailing_newline() {
  local sandbox home_dir repo_root hmf worktree_root
  setup_nrs_worktree_fixture
  (
    source "$REPO_ROOT/modules/shared/scripts/lib/rebuild/common.sh"
    FLAKE_PATH=$repo_root
    log_warn() { :; }
    cd "$worktree_root" || exit
    detect_worktree
    [[ "$FLAKE_PATH" == "$worktree_root" ]] || fail 'external worktree path was truncated'
  )
}

test_darwin_no_changes_external_worktree_requires_hm_evidence() {
  local sandbox home_dir repo_root hmf worktree_root stub_dir current_target relink_log lock_file output state
  for state in missing present; do
    setup_darwin_no_change_gcroot_fixture
    worktree_root="$(cd "$sandbox" && pwd -P)/external worktree"$'\t\n'
    add_fixture_worktree "$repo_root" "$worktree_root" external-no-change
    hmf="$sandbox/home-manager-files"
    mkdir -p "$hmf/.claude"
    printf 'main fixture\n' > "$repo_root/CLAUDE.md"
    printf 'external fixture\n' > "$worktree_root/CLAUDE.md"
    ln -s "$repo_root/CLAUDE.md" "$hmf/.claude/CLAUDE.md"
    ln -sfn "$worktree_root/CLAUDE.md" "$home_dir/.claude/CLAUDE.md"
    install_nrs_worktree_fixture_cli
    if [[ "$state" == present ]]; then
      mkdir -p "$home_dir/.local/state/home-manager/gcroots"
      touch "$home_dir/.local/state/home-manager/gcroots/current-home"
    fi
    output=$(NRS_FIXTURE_FUNCTIONS="$sandbox/nrs-functions.sh" NRS_FIXTURE_MAIN="$repo_root" \
      NRS_FIXTURE_HMF="$hmf" NRS_FIXTURE_CALLS="$sandbox/real-calls" run_darwin_no_change_gcroot_nrs)
    assert_contains "$output" 'No changes to apply'
    if [[ "$state" == present ]]; then
      assert_line_count "$sandbox/real-calls" restore 1
      [[ "$(readlink "$home_dir/.claude/CLAUDE.md")" == "$hmf/.claude/CLAUDE.md" ]] || fail 'no-change external link was not restored'
    else
      [[ ! -e "$sandbox/real-calls" ]] || fail 'no-change path called link mutation without HM evidence'
      [[ "$(readlink "$home_dir/.claude/CLAUDE.md")" == "$worktree_root/CLAUDE.md" ]] || fail 'no-change path changed link without HM evidence'
    fi
  done
}

test_nrs_restore_failure_preserves_unprocessed_worktree_links() {
  local sandbox home_dir repo_root hmf worktree_root rc=0 real_ln
  setup_nrs_worktree_fixture
  printf 'other\n' > "$repo_root/other.md"
  printf 'other\n' > "$worktree_root/other.md"
  ln -s "$repo_root/other.md" "$hmf/.claude/other.md"
  ln -s "$worktree_root/CLAUDE.md" "$home_dir/.claude/CLAUDE.md"
  ln -s "$worktree_root/other.md" "$home_dir/.claude/other.md"
  real_ln=$(command -v ln)
  mkdir "$sandbox/stub-bin"
  cat > "$sandbox/stub-bin/ln" <<'STUB'
#!/usr/bin/env bash
for destination in "$@"; do :; done
[[ "$destination" != "$HOME/.claude/other.md" ]] || exit 1
exec "$NRS_REAL_LN" "$@"
STUB
  chmod +x "$sandbox/stub-bin/ln"
  PATH="$sandbox/stub-bin:$PATH" NRS_REAL_LN="$real_ln" run_nrs_worktree_fixture restore || rc=$?
  [[ "$rc" != 0 ]] || fail 'expected injected restore failure'
  [[ -L "$home_dir/.claude/CLAUDE.md" ]] || fail 'restore removed canary before replacing it'
  [[ "$(readlink "$home_dir/.claude/other.md")" == "$worktree_root/other.md" ]] || fail 'restore removed an unprocessed link'
}
