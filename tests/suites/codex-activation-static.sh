# tests/suites/codex-activation-static.sh — 도메인 테스트 정의 (sourced; aggregator가 lib/test-common.sh 후 source)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# shellcheck disable=SC2154,SC2164
test_codex_activation_agents_symlink_guard_static() {
  local content wiring
  content="$(cat "$REPO_ROOT/modules/shared/programs/codex/files/project-codex-skills.sh")"
  wiring="$(cat "$REPO_ROOT/modules/shared/programs/codex/default.nix")"
  assert_contains "$wiring" '${./files/project-codex-skills.sh}'
  assert_contains "$wiring" '"${pkgs.git}/bin/git"'
  assert_contains "$content" 'Refusing to project Codex skills through .agents symlink'
  assert_contains "$content" 'Refusing to project Codex skills because .agents is not a directory'
  assert_contains "$content" 'Refusing to project Codex skills through .agents/skills symlink'
  assert_contains "$content" 'Refusing to project Codex skills because .agents/skills is not a directory'
  assert_contains "$content" 'mkdir -p "$TARGET_SKILLS"'
}

# 투영 스크립트(modules/shared/programs/codex/files/project-codex-skills.sh)를 fixture 프로젝트에
# 실제로 실행해 파일 시스템 상태로 계약을 확인한다 (#1366). activation과 같게 DRY_RUN_CMD를
# 명시하고, git 전역 설정은 격리한다.
_codex_projection_git() {
  local project="$1"
  shift
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$project" -c init.templateDir= "$@"
}

_codex_projection_state() {
  local project="$1" path
  (
    cd "$project"
    find . -mindepth 1 -name .git -prune -o -print | LC_ALL=C sort | while IFS= read -r path; do
      if [ -L "$path" ]; then
        printf '%s -> %s\n' "$path" "$(readlink "$path")"
      elif [ -f "$path" ]; then
        printf '%s = %s\n' "$path" "$(cat "$path")"
      else
        printf '%s/\n' "$path"
      fi
    done
  )
}

_codex_projection_assert_state_unchanged() {
  local label="$1" before="$2" after="$3"
  [ "$before" = "$after" ] \
    || fail "$label changed state: $(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"
}

# 고아 정리는 원본이 사라진 관리 링크(`../../.claude/skills/<name>` 상대 심링크)만 지운다.
test_codex_activation_orphan_cleanup_removes_only_managed_links() {
  local sandbox project plugin_skill missing_plugin_skill output first_state second_state rc
  local script="$REPO_ROOT/modules/shared/programs/codex/files/project-codex-skills.sh"
  sandbox="$(new_sandbox)"
  project="$sandbox/project"
  plugin_skill="$sandbox/plugin/demo-skill"
  missing_plugin_skill="$sandbox/plugin/removed-skill"
  mkdir -p "$project/.claude/skills/alive" "$project/.agents/skills/tracked-real" "$plugin_skill"

  printf 'alive skill\n' > "$project/.claude/skills/alive/SKILL.md"
  printf 'plugin skill\n' > "$plugin_skill/SKILL.md"
  # 정상 관리 링크 / 원본이 사라진 관리 링크
  ln -s ../../.claude/skills/alive "$project/.agents/skills/alive"
  ln -s ../../.claude/skills/gone "$project/.agents/skills/gone"
  # 원본 없는 실디렉토리: 추적 파일 + 미추적 초안
  printf 'tracked skill\n' > "$project/.agents/skills/tracked-real/SKILL.md"
  printf 'untracked draft\n' > "$project/.agents/skills/tracked-real/draft.md"
  # 외부 플러그인 링크(절대경로) / SKILL.md에 닿지 않는 절대경로 링크 / 다른 대상 상대경로 링크
  ln -s "$plugin_skill" "$project/.agents/skills/plugin-demo"
  ln -s "$missing_plugin_skill" "$project/.agents/skills/plugin-broken"
  ln -s ../../.claude/skills/alive "$project/.agents/skills/alias"
  _codex_projection_git "$project" init -q
  _codex_projection_git "$project" add .claude/skills/alive/SKILL.md .agents/skills/tracked-real/SKILL.md

  rc=0
  output="$(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 DRY_RUN_CMD='' bash "$script" "$project" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || fail "projection script exited $rc: $output"

  [ ! -e "$project/.agents/skills/gone" ] && [ ! -L "$project/.agents/skills/gone" ] \
    || fail "orphan managed link was not removed"
  assert_contains "$output" 'Removing orphan projected skill: .agents/skills/gone'
  [ "$(readlink "$project/.agents/skills/alive")" = "../../.claude/skills/alive" ] \
    || fail "managed link with source changed"
  [ "$(cat "$project/.agents/skills/tracked-real/SKILL.md")" = "tracked skill" ] \
    || fail "tracked file in real directory was not preserved"
  [ "$(cat "$project/.agents/skills/tracked-real/draft.md")" = "untracked draft" ] \
    || fail "untracked draft in real directory was not preserved"
  [ "$(readlink "$project/.agents/skills/plugin-demo")" = "$plugin_skill" ] \
    || fail "external plugin link was not preserved"
  [ "$(cat "$plugin_skill/SKILL.md")" = "plugin skill" ] \
    || fail "external plugin link target changed"
  [ "$(readlink "$project/.agents/skills/plugin-broken")" = "$missing_plugin_skill" ] \
    || fail "absolute link without SKILL.md was not preserved"
  [ "$(readlink "$project/.agents/skills/alias")" = "../../.claude/skills/alive" ] \
    || fail "relative link to another target was not preserved"
  assert_not_contains "$output" 'Removing orphan projected skill: .agents/skills/tracked-real'
  assert_not_contains "$output" 'Removing orphan projected skill: .agents/skills/plugin-demo'
  assert_not_contains "$output" 'Removing orphan projected skill: .agents/skills/plugin-broken'
  assert_not_contains "$output" 'Removing orphan projected skill: .agents/skills/alias'
  # 보존하되 관리 대상이 아닌 항목은 경고한다. 검증기(verify-ai-compat.sh)가 허용하는 플러그인
  # 링크(절대경로 + SKILL.md 접근 가능)만 조용히 두고, SKILL.md에 닿지 않는 절대경로 링크는 경고한다.
  assert_contains "$output" 'Warning: keeping .agents/skills/tracked-real'
  assert_contains "$output" 'Warning: keeping .agents/skills/alias'
  assert_contains "$output" 'Warning: keeping .agents/skills/plugin-broken'
  assert_not_contains "$output" 'Warning: keeping .agents/skills/plugin-demo'

  # 같은 흐름을 다시 실행해도 결과가 바뀌지 않는다.
  first_state="$(_codex_projection_state "$project")"
  rc=0
  output="$(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 DRY_RUN_CMD='' bash "$script" "$project" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || fail "second projection run exited $rc: $output"
  second_state="$(_codex_projection_state "$project")"
  _codex_projection_assert_state_unchanged "second projection run" "$first_state" "$second_state"
  assert_not_contains "$output" 'Removing orphan projected skill'
}

# git을 찾지 못하면 추적 판정을 할 수 없으므로 아무것도 바꾸지 않고 실패한다. 판정 실패가
# "미추적"으로 떨어지면 투영 루프가 원본과 이름이 같은 추적 실디렉토리를 rm -rf한다.
test_codex_activation_projection_fails_closed_without_git() {
  local sandbox project nogit_bin bash_bin tool before after output rc
  local script="$REPO_ROOT/modules/shared/programs/codex/files/project-codex-skills.sh"
  sandbox="$(new_sandbox)"
  project="$sandbox/project"
  nogit_bin="$sandbox/nogit-bin"
  mkdir -p "$project/.claude/skills/legacy" "$project/.claude/skills/fresh" \
    "$project/.agents/skills/legacy" "$nogit_bin"
  printf 'legacy source\n' > "$project/.claude/skills/legacy/SKILL.md"
  printf 'fresh source\n' > "$project/.claude/skills/fresh/SKILL.md"
  printf 'tracked legacy copy\n' > "$project/.agents/skills/legacy/SKILL.md"
  ln -s ../../.claude/skills/gone "$project/.agents/skills/gone"
  _codex_projection_git "$project" init -q
  _codex_projection_git "$project" add .agents/skills/legacy/SKILL.md
  # 스크립트가 쓰는 외부 명령만 둔 PATH (git 없음)
  for tool in basename readlink ln rm mkdir; do
    ln -s "$(command -v "$tool")" "$nogit_bin/$tool"
  done
  bash_bin="$(command -v bash)"
  before="$(_codex_projection_state "$project")"

  rc=0
  output="$(PATH="$nogit_bin" DRY_RUN_CMD='' "$bash_bin" "$script" "$project" 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "projection without git on PATH exited 0: $output"
  after="$(_codex_projection_state "$project")"
  _codex_projection_assert_state_unchanged "projection without git on PATH" "$before" "$after"

  # activation처럼 git 경로를 명시했는데 그 경로가 없을 때도 같다.
  rc=0
  output="$(DRY_RUN_CMD='' bash "$script" "$project" "$sandbox/missing/bin/git" 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "projection with missing git path exited 0: $output"
  after="$(_codex_projection_state "$project")"
  _codex_projection_assert_state_unchanged "projection with missing git path" "$before" "$after"
}

# 추적 판정 명령 자체가 실패하면(저장소가 아님 등) 그 실디렉토리를 "미추적"으로 보지 않고 보존한다.
test_codex_activation_projection_keeps_real_dir_when_tracking_check_fails() {
  local sandbox project output rc
  local script="$REPO_ROOT/modules/shared/programs/codex/files/project-codex-skills.sh"
  sandbox="$(new_sandbox)"
  project="$sandbox/project"
  mkdir -p "$project/.claude/skills/legacy" "$project/.agents/skills/legacy"
  printf 'legacy source\n' > "$project/.claude/skills/legacy/SKILL.md"
  printf 'legacy copy\n' > "$project/.agents/skills/legacy/SKILL.md"
  printf 'untracked draft\n' > "$project/.agents/skills/legacy/draft.md"

  rc=0
  output="$(GIT_CEILING_DIRECTORIES="$sandbox" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    DRY_RUN_CMD='' bash "$script" "$project" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || fail "projection script exited $rc: $output"
  [ ! -L "$project/.agents/skills/legacy" ] \
    || fail "real directory was replaced although git tracking check failed"
  [ "$(cat "$project/.agents/skills/legacy/SKILL.md")" = "legacy copy" ] \
    || fail "real directory content changed although git tracking check failed"
  [ "$(cat "$project/.agents/skills/legacy/draft.md")" = "untracked draft" ] \
    || fail "untracked draft removed although git tracking check failed"
  assert_contains "$output" 'Warning: keeping .agents/skills/legacy'
}

# dry-run(DRY_RUN_CMD=echo)은 변경 명령을 출력만 하고 파일 시스템을 바꾸지 않는다. 거부 가드는
# dry-run에서도 돈다. DRY_RUN_CMD가 아예 없으면(Home Manager activation 밖 호출) 바꾸지 않고 실패한다.
test_codex_activation_projection_dry_run_leaves_tree_unchanged() {
  local sandbox project guarded before after output rc
  local script="$REPO_ROOT/modules/shared/programs/codex/files/project-codex-skills.sh"
  sandbox="$(new_sandbox)"
  project="$sandbox/project"
  mkdir -p "$project/.claude/skills/fresh" "$project/.claude/skills/stale" "$project/.agents/skills"
  printf 'fresh source\n' > "$project/.claude/skills/fresh/SKILL.md"
  printf 'stale source\n' > "$project/.claude/skills/stale/SKILL.md"
  ln -s ../../elsewhere/stale "$project/.agents/skills/stale"
  ln -s ../../.claude/skills/gone "$project/.agents/skills/gone"
  _codex_projection_git "$project" init -q
  before="$(_codex_projection_state "$project")"

  rc=0
  output="$(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 DRY_RUN_CMD='echo' \
    bash "$script" "$project" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || fail "dry-run projection exited $rc: $output"
  after="$(_codex_projection_state "$project")"
  _codex_projection_assert_state_unchanged "dry-run projection" "$before" "$after"
  assert_contains "$output" "ln -sfn CLAUDE.md $project/AGENTS.md"
  assert_contains "$output" "ln -sfn ../../.claude/skills/fresh $project/.agents/skills/fresh"
  assert_contains "$output" "rm -rf $project/.agents/skills/stale"
  assert_contains "$output" "rm -f $project/.agents/skills/gone"

  guarded="$sandbox/guarded"
  mkdir -p "$guarded" "$sandbox/elsewhere"
  ln -s "$sandbox/elsewhere" "$guarded/.agents"
  rc=0
  output="$(DRY_RUN_CMD='echo' bash "$script" "$guarded" 2>&1)" || rc=$?
  [ "$rc" -eq 1 ] || fail "dry-run refusal guard exited $rc: $output"
  assert_contains "$output" 'Refusing to project Codex skills through .agents symlink'
  [ ! -e "$guarded/AGENTS.md" ] && [ ! -L "$guarded/AGENTS.md" ] \
    || fail "dry-run refusal guard ran after creating AGENTS.md"

  rc=0
  output="$(env -u DRY_RUN_CMD GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$script" "$project" 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "projection without DRY_RUN_CMD exited 0: $output"
  after="$(_codex_projection_state "$project")"
  _codex_projection_assert_state_unchanged "projection without DRY_RUN_CMD" "$before" "$after"
}
