# tests/suites/skill-noise.sh — 도메인 테스트 정의 (sourced; aggregator가 lib/test-common.sh 후 source)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# shellcheck disable=SC2154,SC2164
skill_noise_git() {
  local repo_root="$1"
  shift
  local home_dir
  home_dir="$(dirname "$repo_root")/home"
  HOME="$home_dir" \
    XDG_CONFIG_HOME="$home_dir/.config" \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_NOSYSTEM=1 \
    git -C "$repo_root" \
    -c core.hooksPath=/dev/null \
    -c commit.gpgSign=false \
    -c init.templateDir= \
    "$@"
}

create_skill_noise_fixture_repo() {
  local repo_root="$1"
  local sandbox_root home_dir
  sandbox_root="$(dirname "$repo_root")"
  home_dir="$sandbox_root/home"

  mkdir -p \
    "$repo_root/scripts/ai" \
    "$repo_root/.claude/skills/demo" \
    "$repo_root/.agents/skills" \
    "$repo_root/modules/shared/programs/claude/files/skills/demo" \
    "$home_dir/.config"
  cp "$REPO_ROOT/scripts/ai/check-skill-noise.sh" "$repo_root/scripts/ai/check-skill-noise.sh"
  cp "$REPO_ROOT/scripts/ai/warn-skill-consistency.sh" "$repo_root/scripts/ai/warn-skill-consistency.sh"

  (
    cd "$repo_root"
    skill_noise_git "$repo_root" init >/dev/null 2>&1
    skill_noise_git "$repo_root" config user.name "Test User"
    skill_noise_git "$repo_root" config user.email "test@example.com"
    printf 'clean local\n' > .claude/skills/demo/SKILL.md
    printf 'clean shared\n' > modules/shared/programs/claude/files/skills/demo/SKILL.md
    ln -s ../../.claude/skills/demo .agents/skills/demo
    skill_noise_git "$repo_root" add .
    skill_noise_git "$repo_root" commit -m "initial" >/dev/null 2>&1
  )
}

test_check_skill_noise_staged_reads_index_snapshot() {
  local sandbox repo_root output
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  create_skill_noise_fixture_repo "$repo_root"

  printf 'Intro **staged-noise**\n' > "$repo_root/.claude/skills/demo/SKILL.md"
  skill_noise_git "$repo_root" add .claude/skills/demo/SKILL.md
  printf 'Intro clean worktree\n' > "$repo_root/.claude/skills/demo/SKILL.md"

  if output=$(cd "$repo_root" && bash scripts/ai/check-skill-noise.sh --staged .claude/skills 2>&1); then
    fail "expected staged noisy markdown to fail even when worktree is clean"
  fi
  assert_contains "$output" "bold 1 건 잔존"

  printf 'Intro staged clean\n' > "$repo_root/.claude/skills/demo/SKILL.md"
  skill_noise_git "$repo_root" add .claude/skills/demo/SKILL.md
  printf 'Intro **worktree-noise**\n' > "$repo_root/.claude/skills/demo/SKILL.md"

  output=$(cd "$repo_root" && bash scripts/ai/check-skill-noise.sh --staged .claude/skills 2>&1)
  assert_contains "$output" "[PASS]"
}

test_check_skill_noise_staged_normalizes_crlf() {
  local sandbox repo_root output
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  create_skill_noise_fixture_repo "$repo_root"

  printf 'Intro\r\n\r\n\r\nOutro\r\n' > "$repo_root/.claude/skills/demo/SKILL.md"
  skill_noise_git "$repo_root" add .claude/skills/demo/SKILL.md

  if output=$(cd "$repo_root" && bash scripts/ai/check-skill-noise.sh --staged .claude/skills 2>&1); then
    fail "expected staged CRLF excessive empty lines to fail"
  fi
  assert_contains "$output" "excessive empty lines 1 건 잔존"
}

test_check_skill_noise_staged_follows_symlink_projection() {
  local sandbox repo_root output
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  create_skill_noise_fixture_repo "$repo_root"

  printf 'Intro **projection-noise**\n' > "$repo_root/.claude/skills/demo/SKILL.md"
  skill_noise_git "$repo_root" add .claude/skills/demo/SKILL.md

  if output=$(cd "$repo_root" && bash scripts/ai/check-skill-noise.sh --staged .agents/skills 2>&1); then
    fail "expected staged symlink projection scan to catch target noise"
  fi
  assert_contains "$output" "bold 1 건 잔존"
}

test_check_skill_noise_staged_rejects_non_regular_markdown() {
  local sandbox repo_root output
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  create_skill_noise_fixture_repo "$repo_root"

  rm "$repo_root/.claude/skills/demo/SKILL.md"
  ln -s target.md "$repo_root/.claude/skills/demo/SKILL.md"
  skill_noise_git "$repo_root" add .claude/skills/demo/SKILL.md

  if output=$(cd "$repo_root" && bash scripts/ai/check-skill-noise.sh --staged .claude/skills 2>&1); then
    fail "expected staged non-regular markdown to fail"
  fi
  assert_contains "$output" "staged markdown is not a regular file"
}

test_check_skill_noise_worktree_follows_symlink_projection() {
  local sandbox repo_root output
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  create_skill_noise_fixture_repo "$repo_root"

  cat > "$repo_root/.claude/skills/demo/SKILL.md" <<'EOF'
inline code keeps `**literal**`

```bash
echo "**literal**"


echo "blank lines inside fences stay protected"
```
EOF

  output=$(cd "$repo_root" && bash scripts/ai/check-skill-noise.sh .agents/skills 2>&1)
  assert_contains "$output" "[PASS]"

  printf 'Intro\n\n\nOutro\n' > "$repo_root/.claude/skills/demo/SKILL.md"
  if output=$(cd "$repo_root" && bash scripts/ai/check-skill-noise.sh .agents/skills 2>&1); then
    fail "expected symlink projection scan to catch excessive empty lines"
  fi
  assert_contains "$output" "excessive empty lines 1 건 잔존"
}

test_check_skill_noise_description_length_thresholds() {
  local sandbox repo_root output warn_desc fail_desc
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  create_skill_noise_fixture_repo "$repo_root"

  warn_desc="$(printf '%*s' 901 '' | tr ' ' a)"
  printf -- '---\nname: demo\ndescription: %s\n---\nclean\n' "$warn_desc" \
    > "$repo_root/.claude/skills/demo/SKILL.md"

  output=$(cd "$repo_root" && bash scripts/ai/check-skill-noise.sh .claude/skills 2>&1)
  assert_contains "$output" "[WARN]"
  assert_contains "$output" "description 901자"
  assert_contains "$output" "[PASS]"

  fail_desc="$(printf '%*s' 1100 '' | tr ' ' a)"
  printf -- '---\nname: demo\ndescription: |\n  %s\n---\nclean\n' "$fail_desc" \
    > "$repo_root/.claude/skills/demo/SKILL.md"

  if output=$(cd "$repo_root" && bash scripts/ai/check-skill-noise.sh .claude/skills 2>&1); then
    fail "expected over-limit skill description to fail"
  fi
  assert_contains "$output" "[FAIL] demo/SKILL.md: description 1100자"
  assert_contains "$output" "description=1"
}

test_check_skill_noise_multiline_bold_respects_protection() {
  local sandbox repo_root output
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  create_skill_noise_fixture_repo "$repo_root"

  cat > "$repo_root/.claude/skills/demo/SKILL.md" <<'EOF'
inline code keeps `**literal
span**`

```text
**literal
span**
```
EOF

  output=$(cd "$repo_root" && bash scripts/ai/check-skill-noise.sh .claude/skills 2>&1)
  assert_contains "$output" "[PASS]"

  cat > "$repo_root/.claude/skills/demo/SKILL.md" <<'EOF'
Intro **not

bold** outro
EOF

  output=$(cd "$repo_root" && bash scripts/ai/check-skill-noise.sh .claude/skills 2>&1)
  assert_contains "$output" "[PASS]"

  cat > "$repo_root/.claude/skills/demo/SKILL.md" <<'EOF'
Intro **two
line** outro
EOF

  if output=$(cd "$repo_root" && bash scripts/ai/check-skill-noise.sh .claude/skills 2>&1); then
    fail "expected unprotected multi-line bold to fail"
  fi
  assert_contains "$output" "bold 1 건 잔존"
}

test_check_skill_noise_worktree_rejects_external_symlink() {
  local sandbox repo_root external_dir output
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  external_dir="$sandbox/private"
  create_skill_noise_fixture_repo "$repo_root"

  mkdir -p "$external_dir"
  printf 'external **secret**\n' > "$external_dir/secret-not-in-repo.md"
  ln -s "$external_dir" "$repo_root/.claude/skills/external"

  if output=$(cd "$repo_root" && bash scripts/ai/check-skill-noise.sh .claude/skills 2>&1); then
    fail "expected external symlink directory to fail"
  fi
  assert_contains "$output" "points outside repo"
  assert_not_contains "$output" "**secret**"
}

test_warn_skill_consistency_ignores_managed_plugin_skill_projection() {
  local sandbox repo_root plugin_dir output
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  plugin_dir="$sandbox/plugin"
  create_skill_noise_fixture_repo "$repo_root"

  mkdir -p "$plugin_dir/skills/plugin-skill"
  printf '%s\n' '---' 'name: plugin-skill' '---' > "$plugin_dir/skills/plugin-skill/SKILL.md"
  ln -s "$plugin_dir/skills/plugin-skill" \
    "$repo_root/.agents/skills/wt-plugin--example-plugin_demo-marketplace-1234567890--plugin-skill-1234567890"

  output=$(cd "$repo_root" && bash scripts/ai/warn-skill-consistency.sh 2>&1)
  assert_not_contains "$output" "고아 투영"
}
