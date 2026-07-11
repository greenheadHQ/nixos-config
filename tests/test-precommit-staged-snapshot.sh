#!/usr/bin/env bash
# Focused integration tests for staged pre-commit snapshot behavior.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

for tool in git lefthook gitleaks shellcheck nixfmt python3; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "SKIP: $tool not found; run from nix develop/devShell" >&2
    exit 0
  }
done

TEST_TMP_FILE="$(mktemp "${TMPDIR:-/tmp}/precommit-staged-tests.XXXXXX")"

cleanup() {
  local dir
  if [ -f "$TEST_TMP_FILE" ]; then
    while IFS= read -r dir; do
      if [ -n "$dir" ]; then
        # 공유 스냅샷 캐시의 read-only(chmod a-w) worktree 까지 지울 수 있게 u+w 복구
        chmod -R u+w "$dir" 2>/dev/null || true
        rm -rf "$dir"
      fi
    done < "$TEST_TMP_FILE"
    rm -f "$TEST_TMP_FILE"
  fi
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

track_tmp() {
  printf '%s\n' "$1" >> "$TEST_TMP_FILE"
}

assert_fail_contains() {
  local expected="$1"
  shift
  local out status
  set +e
  out="$("$@" 2>&1)"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "expected command to fail: $*"
  case "$out" in
    *"$expected"*) ;;
    *)
      printf '%s\n' "$out" >&2
      fail "expected output to contain: $expected"
      ;;
  esac
}

assert_success() {
  "$@" >/dev/null 2>&1 || fail "expected command to succeed: $*"
}

lefthook_in() (
  cd "$1"
  shift
  lefthook "$@"
)

copy_file() {
  local src="$1"
  local dest="$2"
  mkdir -p "$(dirname "$dest")"
  cp "$REPO_ROOT/$src" "$dest"
}

make_repo() {
  local dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/precommit-staged-repo.XXXXXX")"
  track_tmp "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email test@example.invalid
  git -C "$dir" config user.name "Test User"

  copy_file "lefthook.yml" "$dir/lefthook.yml"
  cat > "$dir/.gitleaks.toml" <<'EOF'
title = "test gitleaks configuration"

[extend]
useDefault = true

[[rules]]
id = "test-secret"
description = "test secret"
regex = '''TESTSECRET-[A-Z0-9]+'''
EOF
  [ -f "$REPO_ROOT/.gitleaksignore" ] && copy_file ".gitleaksignore" "$dir/.gitleaksignore"

  copy_file "scripts/ai/run-staged-snapshot.sh" "$dir/scripts/ai/run-staged-snapshot.sh"
  copy_file "scripts/ai/run-gitleaks-staged-policy.sh" "$dir/scripts/ai/run-gitleaks-staged-policy.sh"
  copy_file "scripts/ai/validate-gitleaks-staged-policy.py" "$dir/scripts/ai/validate-gitleaks-staged-policy.py"
  copy_file "scripts/ai/check-lefthook-staged-config.sh" "$dir/scripts/ai/check-lefthook-staged-config.sh"
  copy_file "scripts/ai/install-lefthook-hooks.sh" "$dir/scripts/ai/install-lefthook-hooks.sh"
  copy_file "scripts/ai/warn-skill-consistency.sh" "$dir/scripts/ai/warn-skill-consistency.sh"
  copy_file "scripts/ai/check-skill-noise.sh" "$dir/scripts/ai/check-skill-noise.sh"
  copy_file "tests/run-eval-tests.sh" "$dir/tests/run-eval-tests.sh"
  copy_file "tests/test-codex-hook-fixtures.sh" "$dir/tests/test-codex-hook-fixtures.sh"
  copy_file "scripts/ai/lib/tomlkit-bootstrap.sh" "$dir/scripts/ai/lib/tomlkit-bootstrap.sh"
  copy_file "scripts/ai/test-runtime-profile.sh" "$dir/scripts/ai/test-runtime-profile.sh"
  copy_file "scripts/ai/lib/staged-snapshot-cache.sh" "$dir/scripts/ai/lib/staged-snapshot-cache.sh"

  mkdir -p "$dir/.claude/skills/existing" "$dir/.agents/skills"
  mkdir -p "$dir/modules/shared/programs/claude/files/skills/existing"
  mkdir -p "$dir/modules/shared/programs/claude" "$dir/modules/shared/programs/codex"
  printf '# Local Existing\n' > "$dir/.claude/skills/existing/SKILL.md"
  printf '# Existing\n' > "$dir/modules/shared/programs/claude/files/skills/existing/SKILL.md"
  cat > "$dir/modules/shared/programs/claude/default.nix" <<'EOF'
{ }
EOF
  cat > "$dir/modules/shared/programs/codex/default.nix" <<'EOF'
{
  exposedCodexSkills = [ ];
  intentionallyNotExposed = [ ];
}
EOF
  cat > "$dir/tests/run-eval-tests.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "$dir/tests/run-eval-tests.sh"
  cat > "$dir/tests/test-codex-hook-fixtures.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "$dir/tests/test-codex-hook-fixtures.sh"

  git -C "$dir" add .
  git -C "$dir" commit -qm initial
  printf '%s\n' "$dir"
}

test_ai_skills_consistency_cross_file() {
  local dir
  dir="$(make_repo)"
  mkdir -p "$dir/modules/shared/programs/claude/files/skills/new-skill"
  printf '# New Skill\n' > "$dir/modules/shared/programs/claude/files/skills/new-skill/SKILL.md"
  git -C "$dir" add modules/shared/programs/claude/files/skills/new-skill/SKILL.md
  cat > "$dir/modules/shared/programs/claude/default.nix" <<'EOF'
{
  ".claude/skills/new-skill" = ./files/skills/new-skill;
}
EOF
  cat > "$dir/modules/shared/programs/codex/default.nix" <<'EOF'
{
  exposedCodexSkills = [ "new-skill" ];
  intentionallyNotExposed = [ ];
}
EOF
  assert_fail_contains "new-skill" lefthook_in "$dir" run pre-commit --job ai-skills-consistency
}

test_ai_skills_consistency_without_git_metadata() {
  local dir snapshot files name_status
  dir="$(make_repo)"
  mkdir -p "$dir/modules/shared/programs/claude/files/skills/new-skill"
  printf '# New Skill\n' > "$dir/modules/shared/programs/claude/files/skills/new-skill/SKILL.md"
  git -C "$dir" add modules/shared/programs/claude/files/skills/new-skill/SKILL.md
  snapshot="$(mktemp -d "${TMPDIR:-/tmp}/precommit-snapshot.XXXXXX")"
  track_tmp "$snapshot"
  git -C "$dir" checkout-index --all --prefix="$snapshot/"
  files="$snapshot/files.nul"
  name_status="$snapshot/name-status.nul"
  git -C "$dir" diff --cached -z --name-only > "$files"
  git -C "$dir" diff --cached -z --name-status > "$name_status"
  assert_fail_contains "new-skill" env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
    STAGED_SNAPSHOT_STAGED_FILES_NUL_FILE="$files" \
    STAGED_SNAPSHOT_STAGED_NAME_STATUS_NUL_FILE="$name_status" \
    bash "$snapshot/scripts/ai/warn-skill-consistency.sh"
}

test_ai_skills_consistency_rejects_malformed_name_status_metadata() {
  local dir name_status
  dir="$(make_repo)"
  name_status="$dir/bad-name-status.nul"
  printf 'A\0' > "$name_status"
  assert_fail_contains "malformed staged name-status metadata" env \
    STAGED_SNAPSHOT_STAGED_NAME_STATUS_NUL_FILE="$name_status" \
    bash "$dir/scripts/ai/warn-skill-consistency.sh"
}

test_skill_noise_same_file_partial_staging() {
  local dir skill
  dir="$(make_repo)"
  skill="$dir/modules/shared/programs/claude/files/skills/existing/SKILL.md"
  printf '# Existing\n\n**bold**\n' > "$skill"
  git -C "$dir" add "$skill"
  printf '# Existing\n' > "$skill"
  assert_fail_contains "bold" lefthook_in "$dir" run pre-commit --job skill-noise-check
}

test_local_skill_noise_same_file_partial_staging() {
  local dir skill
  dir="$(make_repo)"
  skill="$dir/.claude/skills/existing/SKILL.md"
  printf '# Local Existing\n\n**bold**\n' > "$skill"
  git -C "$dir" add "$skill"
  printf '# Local Existing\n' > "$skill"
  assert_fail_contains "bold" lefthook_in "$dir" run pre-commit --job local-skill-noise-check
}

test_gitleaks_unstaged_policy_masking() {
  local dir secret
  dir="$(make_repo)"
  secret='TESTSECRET-ABC123'
  printf 'token = "%s"\n' "$secret" > "$dir/secret.txt"
  git -C "$dir" add secret.txt
  cat > "$dir/.gitleaks.toml" <<EOF
title = "weakened"

[[rules]]
id = "allow-test"
description = "allow test secret"
regex = '''$secret'''
[rules.allowlist]
regexes = ['''$secret''']
EOF
  assert_fail_contains "leak" lefthook_in "$dir" run pre-commit --job gitleaks
}

test_gitleaks_rejects_unstaged_validator_edit() {
  local dir secret
  dir="$(make_repo)"
  secret='TESTSECRET-ABC123'
  printf 'token = "%s"\n' "$secret" > "$dir/secret.txt"
  git -C "$dir" add secret.txt
  cat > "$dir/scripts/ai/validate-gitleaks-staged-policy.py" <<'EOF'
#!/usr/bin/env python3
raise SystemExit(0)
EOF
  assert_fail_contains "leak" lefthook_in "$dir" run pre-commit --job gitleaks
}

test_gitleaks_rejects_extend_escape() {
  local dir
  dir="$(make_repo)"
  cat > "$dir/.gitleaks.toml" <<'EOF'
title = "bad"
[extend]
path = "../outside.toml"
EOF
  git -C "$dir" add .gitleaks.toml
  assert_fail_contains "extend.path" lefthook_in "$dir" run pre-commit --job gitleaks
}

test_gitleaks_rejects_policy_symlink() {
  local dir
  dir="$(make_repo)"
  rm "$dir/.gitleaks.toml"
  ln -s /tmp/outside-gitleaks.toml "$dir/.gitleaks.toml"
  printf 'token = "TESTSECRET-ABC123"\n' > "$dir/secret.txt"
  git -C "$dir" add .gitleaks.toml
  git -C "$dir" add secret.txt
  assert_fail_contains ".gitleaks.toml" lefthook_in "$dir" run pre-commit --job gitleaks
}

test_gitleaks_validator_tomlkit_fallback_unwraps_extend() {
  python3 - "$REPO_ROOT/scripts/ai/validate-gitleaks-staged-policy.py" <<'PY'
import importlib.util
import sys
import tempfile
from pathlib import Path

module_path = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("validator", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
module.tomllib = None
if module.tomlkit is None:
    raise SystemExit(0)

with tempfile.TemporaryDirectory() as tmp:
    config = Path(tmp) / "config.toml"
    config.write_text('[extend]\npath = "child.toml"\n', encoding="utf-8")
    data = module.parse_toml(config)
    assert isinstance(data, dict)
    assert isinstance(data.get("extend"), dict)
PY
}

test_installed_guard_rejects_lefthook_drift_and_env() {
  local dir
  dir="$(make_repo)"
  (cd "$dir" && bash ./scripts/ai/install-lefthook-hooks.sh)
  cat >> "$dir/lefthook.yml" <<'EOF'
    bypass:
      run: echo bypass
EOF
  printf 'change\n' > "$dir/change.txt"
  git -C "$dir" add change.txt
  assert_fail_contains "lefthook.yml differs" git -C "$dir" commit -qm drift
  git -C "$dir" checkout -- lefthook.yml
  assert_fail_contains "LEFTHOOK_EXCLUDE" env LEFTHOOK_EXCLUDE=gitleaks git -C "$dir" commit -qm excluded
  assert_fail_contains "LEFTHOOK_BIN" env LEFTHOOK_BIN=/bin/true git -C "$dir" commit -qm bin
  assert_fail_contains "LEFTHOOK_CONFIG" env LEFTHOOK_CONFIG=/tmp/lefthook.yml git -C "$dir" commit -qm config
}

test_guard_rejects_unsupported_command_shape() {
  local dir
  dir="$(make_repo)"
  perl -0pi -e 's/run: bash \.\/scripts\/ai\/run-gitleaks-staged-policy\.sh/run: bash .\/scripts\/ai\/run-gitleaks-staged-policy.sh\n      skip: true/' "$dir/lefthook.yml"
  git -C "$dir" add lefthook.yml
  (cd "$dir" && bash ./scripts/ai/install-lefthook-hooks.sh)
  printf 'change\n' > "$dir/change.txt"
  git -C "$dir" add change.txt
  assert_fail_contains "unsupported pre-commit" git -C "$dir" commit -qm unsupported
}

test_guard_rejects_unsupported_pre_push_shape() {
  local dir
  dir="$(make_repo)"
  perl -0pi -e 's#        - "modules/shared/programs/claude/files/scripts/tests/statusline\.bats"#        - "README.md"#' "$dir/lefthook.yml"
  git -C "$dir" add lefthook.yml
  (cd "$dir" && bash ./scripts/ai/install-lefthook-hooks.sh)
  printf 'change\n' > "$dir/change.txt"
  git -C "$dir" add change.txt
  assert_fail_contains "unsupported pre-push" git -C "$dir" commit -qm unsupported-pre-push
}

test_installer_idempotent_and_worktree_local() {
  local dir hook_path hook_dir
  dir="$(make_repo)"
  (cd "$dir" && bash ./scripts/ai/install-lefthook-hooks.sh)
  (cd "$dir" && bash ./scripts/ai/install-lefthook-hooks.sh)
  hook_path="$(git -C "$dir" rev-parse --path-format=absolute --git-path hooks/pre-commit)"
  hook_dir="$(dirname "$hook_path")"
  case "$hook_dir" in
    "$(git -C "$dir" rev-parse --path-format=absolute --git-dir)/hooks") ;;
    *) fail "expected worktree-local hooks path, got $hook_dir" ;;
  esac
  [ "$(grep -Fxc '# BEGIN nixos-config lefthook staged-config guard' "$hook_path")" = "1" ] || fail "expected one begin marker"
  [ "$(grep -Fxc '# END nixos-config lefthook staged-config guard' "$hook_path")" = "1" ] || fail "expected one end marker"
  bash -n "$hook_path"
}

# 공유 staged-snapshot 캐시: 같은 index 를 보는 호출은 checkout-index 를 1회만 수행하고
# 결과 worktree 를 read-only 로 공유한다. TMPDIR 을 repo 안으로 격리해 캐시도 함께 정리된다.
test_staged_snapshot_cache_hit_and_readonly() {
  local dir log builds
  dir="$(make_repo)"
  printf 'cache probe\n' > "$dir/cache-probe.txt"
  git -C "$dir" add cache-probe.txt
  mkdir -p "$dir/.cache-tmp"
  log="$dir/.cache-tmp/build.log"
  : > "$log"
  ( cd "$dir" && TMPDIR="$dir/.cache-tmp" STAGED_SNAPSHOT_CACHE_DEBUG_BUILD_LOG="$log" \
      bash ./scripts/ai/run-staged-snapshot.sh -- true ) || fail "first snapshot run failed"
  ( cd "$dir" && TMPDIR="$dir/.cache-tmp" STAGED_SNAPSHOT_CACHE_DEBUG_BUILD_LOG="$log" \
      bash ./scripts/ai/run-staged-snapshot.sh -- true ) || fail "second snapshot run failed"
  builds="$(wc -l < "$log" | tr -d ' ')"
  [ "$builds" = "1" ] || fail "expected 1 checkout-index build after cache hit, got $builds"
  ( cd "$dir" && TMPDIR="$dir/.cache-tmp" \
      bash ./scripts/ai/run-staged-snapshot.sh -- bash -c 'test ! -w "$STAGED_SNAPSHOT_ROOT"' ) \
    || fail "shared snapshot worktree must be read-only"
}

# parallel pre-commit 모사: 동시 호출이 경쟁해도 mkdir lock 직렬화로 build 는 정확히 1회.
test_staged_snapshot_cache_concurrent_single_build() {
  local dir log builds
  dir="$(make_repo)"
  printf 'concurrent probe\n' > "$dir/concurrent-probe.txt"
  git -C "$dir" add concurrent-probe.txt
  mkdir -p "$dir/.cache-tmp"
  log="$dir/.cache-tmp/build.log"
  : > "$log"
  for _ in 1 2 3 4 5 6; do
    ( cd "$dir" && TMPDIR="$dir/.cache-tmp" STAGED_SNAPSHOT_CACHE_DEBUG_BUILD_LOG="$log" \
        bash ./scripts/ai/run-staged-snapshot.sh -- true ) &
  done
  wait
  builds="$(wc -l < "$log" | tr -d ' ')"
  [ "$builds" = "1" ] || fail "expected exactly 1 build under concurrency, got $builds"
}

# 멈춘/죽은 빌더의 lock(단순 버전은 owner 메타 없는 빈 디렉토리)은 대기자가 타임아웃 후 제거하고
# 직접 빌드해 승계한다. checkout 은 다시 1회 일어난다.
test_staged_snapshot_cache_stale_lock_takeover() {
  local dir log repo_path hash builds
  dir="$(make_repo)"
  printf 'stale probe\n' > "$dir/stale-probe.txt"
  git -C "$dir" add stale-probe.txt
  mkdir -p "$dir/.cache-tmp"
  log="$dir/.cache-tmp/build.log"
  : > "$log"
  ( cd "$dir" && TMPDIR="$dir/.cache-tmp" STAGED_SNAPSHOT_CACHE_DEBUG_BUILD_LOG="$log" \
      bash ./scripts/ai/run-staged-snapshot.sh -- true ) || fail "seed snapshot run failed"
  repo_path="$(find "$dir/.cache-tmp/staged-snapshot-cache" -mindepth 1 -maxdepth 1 -type d | head -1)"
  hash="$(find "$repo_path/trees" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | head -1)"
  # 파생 경로가 비면(레이아웃 변경 등) destructive rm 이 의도치 않은 대상을 지울 수 있으므로 가드.
  [ -n "$repo_path" ] && [ -d "$repo_path" ] || fail "stale-lock test: cache repo_id dir not found"
  [ -n "$hash" ] && [ -d "$repo_path/trees/$hash" ] || fail "stale-lock test: cache tree not found"
  # 완성 트리 제거 + holder 가 점유 중인 것처럼 빈 lock 디렉토리를 심는다.
  chmod -R u+w "$repo_path/trees/$hash"; rm -rf "$repo_path/trees/$hash"
  mkdir -p "$repo_path/locks/$hash"
  : > "$log"
  ( cd "$dir" && TMPDIR="$dir/.cache-tmp" STAGED_SNAPSHOT_CACHE_DEBUG_BUILD_LOG="$log" \
      STAGED_SNAPSHOT_CACHE_LOCK_TIMEOUT_SECONDS=2 \
      bash ./scripts/ai/run-staged-snapshot.sh -- true ) || fail "stale-lock takeover run failed"
  builds="$(wc -l < "$log" | tr -d ' ')"
  [ "$builds" = "1" ] || fail "expected 1 rebuild after stale lock takeover, got $builds"
  [ -d "$repo_path/trees/$hash/worktree" ] || fail "worktree not rebuilt after takeover"
}

test_ai_skills_consistency_cross_file
test_ai_skills_consistency_without_git_metadata
test_ai_skills_consistency_rejects_malformed_name_status_metadata
test_skill_noise_same_file_partial_staging
test_local_skill_noise_same_file_partial_staging
test_gitleaks_unstaged_policy_masking
test_gitleaks_rejects_unstaged_validator_edit
test_gitleaks_rejects_extend_escape
test_gitleaks_rejects_policy_symlink
test_gitleaks_validator_tomlkit_fallback_unwraps_extend
test_installed_guard_rejects_lefthook_drift_and_env
test_guard_rejects_unsupported_command_shape
test_guard_rejects_unsupported_pre_push_shape
test_installer_idempotent_and_worktree_local
test_staged_snapshot_cache_hit_and_readonly
test_staged_snapshot_cache_concurrent_single_build
test_staged_snapshot_cache_stale_lock_takeover

echo "All pre-commit staged snapshot tests passed."
