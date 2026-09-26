# tests/suites/codex-activation-static.sh — 도메인 테스트 정의 (sourced; aggregator가 lib/test-common.sh 후 source)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# shellcheck disable=SC2154,SC2164
test_codex_activation_agents_symlink_guard_static() {
  local content wiring
  content="$(cat "$REPO_ROOT/modules/shared/programs/codex/files/project-codex-skills.sh")"
  wiring="$(cat "$REPO_ROOT/modules/shared/programs/codex/default.nix")"
  assert_contains "$wiring" '${./files/project-codex-skills.sh}'
  assert_contains "$content" 'Refusing to project Codex skills through .agents symlink'
  assert_contains "$content" 'Refusing to project Codex skills because .agents is not a directory'
  assert_contains "$content" 'Refusing to project Codex skills through .agents/skills symlink'
  assert_contains "$content" 'Refusing to project Codex skills because .agents/skills is not a directory'
  assert_contains "$content" 'mkdir -p "$TARGET_SKILLS"'
}

# 투영 스크립트를 fixture 프로젝트에 실제로 실행해, 고아 정리가 원본이 사라진 관리 링크
# (`../../.claude/skills/<name>` 상대 심링크)만 지우는지 파일 시스템 상태로 확인한다 (#1366).
_codex_projection_state() {
  local project="$1" path
  (
    cd "$project"
    find .agents .claude -mindepth 1 | LC_ALL=C sort | while IFS= read -r path; do
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

test_codex_activation_orphan_cleanup_removes_only_managed_links() {
  local sandbox project plugin_skill output first_state second_state rc
  local script="$REPO_ROOT/modules/shared/programs/codex/files/project-codex-skills.sh"
  sandbox="$(new_sandbox)"
  project="$sandbox/project"
  plugin_skill="$sandbox/plugin/demo-skill"
  mkdir -p "$project/.claude/skills/alive" "$project/.agents/skills/tracked-real" "$plugin_skill"

  printf 'alive skill\n' > "$project/.claude/skills/alive/SKILL.md"
  printf 'plugin skill\n' > "$plugin_skill/SKILL.md"
  # 정상 관리 링크 / 원본이 사라진 관리 링크
  ln -s ../../.claude/skills/alive "$project/.agents/skills/alive"
  ln -s ../../.claude/skills/gone "$project/.agents/skills/gone"
  # 원본 없는 실디렉토리: 추적 파일 + 미추적 초안
  printf 'tracked skill\n' > "$project/.agents/skills/tracked-real/SKILL.md"
  printf 'untracked draft\n' > "$project/.agents/skills/tracked-real/draft.md"
  # 외부 플러그인 링크(절대경로) / 다른 대상을 가리키는 상대경로 링크
  ln -s "$plugin_skill" "$project/.agents/skills/plugin-demo"
  ln -s ../../.claude/skills/alive "$project/.agents/skills/alias"
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -C "$project" -c init.templateDir= init -q
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -C "$project" add .claude/skills/alive/SKILL.md .agents/skills/tracked-real/SKILL.md

  rc=0
  output="$(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$project" 2>&1)" || rc=$?
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
  [ "$(readlink "$project/.agents/skills/alias")" = "../../.claude/skills/alive" ] \
    || fail "relative link to another target was not preserved"
  assert_not_contains "$output" 'Removing orphan projected skill: .agents/skills/tracked-real'
  assert_not_contains "$output" 'Removing orphan projected skill: .agents/skills/plugin-demo'
  assert_not_contains "$output" 'Removing orphan projected skill: .agents/skills/alias'
  # 보존하되 관리 대상이 아닌 항목은 경고하고, 검증기가 허용하는 플러그인 링크는 조용히 둔다.
  assert_contains "$output" 'Warning: keeping .agents/skills/tracked-real'
  assert_contains "$output" 'Warning: keeping .agents/skills/alias'
  assert_not_contains "$output" 'Warning: keeping .agents/skills/plugin-demo'

  # 같은 흐름을 다시 실행해도 결과가 바뀌지 않는다.
  first_state="$(_codex_projection_state "$project")"
  rc=0
  output="$(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$script" "$project" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || fail "second projection run exited $rc: $output"
  second_state="$(_codex_projection_state "$project")"
  [ "$first_state" = "$second_state" ] \
    || fail "second projection run changed state: $(diff <(printf '%s\n' "$first_state") <(printf '%s\n' "$second_state"))"
  assert_not_contains "$output" 'Removing orphan projected skill'
}
