# tests/suites/skill-stale-identifiers.sh — stale skill identifier warning fixtures
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# shellcheck disable=SC2154,SC2164
skill_stale_git() {
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

create_skill_stale_fixture_repo() {
  local repo_root="$1"
  local sandbox_root home_dir
  sandbox_root="$(dirname "$repo_root")"
  home_dir="$sandbox_root/home"

  mkdir -p \
    "$repo_root/scripts/ai" \
    "$repo_root/.claude/skills/demo" \
    "$repo_root/modules/darwin/programs/folder-actions" \
    "$repo_root/modules/shared/programs/claude/files/skills" \
    "$home_dir/.config"
  cp "$REPO_ROOT/scripts/ai/warn-skill-stale-identifiers.sh" \
    "$repo_root/scripts/ai/warn-skill-stale-identifiers.sh"

  (
    cd "$repo_root"
    skill_stale_git "$repo_root" init >/dev/null 2>&1
    skill_stale_git "$repo_root" config user.name "Test User"
    skill_stale_git "$repo_root" config user.email "test@example.com"
    printf 'fixture\n' > README.md
    skill_stale_git "$repo_root" add .
    skill_stale_git "$repo_root" commit -m "initial" >/dev/null 2>&1
  )
}

test_warn_skill_stale_identifiers_detects_residual_skill_doc() {
  local sandbox repo_root output
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  create_skill_stale_fixture_repo "$repo_root"

  cat > "$repo_root/modules/darwin/programs/folder-actions/default.nix" <<'EOF'
{
  launchd.agents.fixture = {
    Label = "com.example.fixture.old-label";
  };
}
EOF
  cat > "$repo_root/.claude/skills/demo/SKILL.md" <<'EOF'
Use launchctl print gui/501/com.example.fixture.old-label when diagnosing the fixture.
EOF
  skill_stale_git "$repo_root" add .
  skill_stale_git "$repo_root" commit -m "add old label" >/dev/null 2>&1

  cat > "$repo_root/modules/darwin/programs/folder-actions/default.nix" <<'EOF'
{
  launchd.agents.fixture = {
    Label = "com.example.fixture.new-label";
  };
}
EOF
  skill_stale_git "$repo_root" add modules/darwin/programs/folder-actions/default.nix

  output=$(cd "$repo_root" && bash scripts/ai/warn-skill-stale-identifiers.sh 2>&1)
  assert_contains "$output" "[WARN] 스킬 문서 구 식별자 잔존 의심: com.example.fixture.old-label"
  assert_contains "$output" ".claude/skills/demo/SKILL.md:1"
  assert_contains "$output" "스킬 문서 갱신 필요 여부 확인"
}

test_warn_skill_stale_identifiers_clean_pass_stays_quiet() {
  local sandbox repo_root output
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  create_skill_stale_fixture_repo "$repo_root"

  cat > "$repo_root/modules/darwin/programs/folder-actions/default.nix" <<'EOF'
{
  launchd.agents.compress-rar = {
    Label = "com.green.folder-action.compress-rar";
  };
}
EOF
  printf 'No stale folder-action label here.\n' > "$repo_root/.claude/skills/demo/SKILL.md"
  skill_stale_git "$repo_root" add .
  skill_stale_git "$repo_root" commit -m "add clean label" >/dev/null 2>&1

  cat > "$repo_root/modules/darwin/programs/folder-actions/default.nix" <<'EOF'
{
  launchd.agents.compress-rar = {
    Label = "com.greenhead.folder-action.compress-rar";
  };
}
EOF
  skill_stale_git "$repo_root" add modules/darwin/programs/folder-actions/default.nix

  output=$(cd "$repo_root" && bash scripts/ai/warn-skill-stale-identifiers.sh 2>&1)
  [ -z "$output" ] || fail "expected clean stale identifier check to stay quiet, got: $output"
}
