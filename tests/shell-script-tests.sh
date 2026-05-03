#!/usr/bin/env bash
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

cleanup() {
  local dir
  if [[ -f "$TEST_TMP_FILE" ]]; then
    while IFS= read -r dir; do
      [[ -n "$dir" ]] && rm -rf "$dir"
    done < "$TEST_TMP_FILE"
    rm -f "$TEST_TMP_FILE"
  fi
  return 0
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" != *"$needle"* ]] || fail "expected output to not contain: $needle"
}

assert_file_contains() {
  local path="$1"
  local needle="$2"
  grep -Fqx "$needle" "$path" >/dev/null || fail "expected $path to contain exact line: $needle"
}

assert_line_count() {
  local path="$1"
  local needle="$2"
  local expected="$3"
  local actual
  actual=$(grep -Fxc "$needle" "$path")
  [[ "$actual" == "$expected" ]] || fail "expected $path to contain $expected occurrences of: $needle (actual: $actual)"
}

write_mixed_user_codex_hooks() {
  local home_dir="$1"
  mkdir -p "$home_dir/.codex"
  # session-init-icons.sh is a known stale Claude-era user hook; Codex should prune it, not run it.
  cat > "$home_dir/.codex/hooks.json" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume",
        "hooks": [
          {
            "type": "command",
            "command": "~/.codex/hooks/session-init-icons.sh"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/tmp/custom-user-hook.sh"
          }
        ]
      }
    ]
  }
}
EOF
  printf '{}\n' > "$home_dir/.codex/hooks.compatibility.json"
}

write_malformed_user_codex_hooks() {
  local home_dir="$1"
  mkdir -p "$home_dir/.codex"
  printf '{ not valid json\n' > "$home_dir/.codex/hooks.json"
  printf '{}\n' > "$home_dir/.codex/hooks.compatibility.json"
}

write_symlinked_user_codex_hooks() {
  local home_dir="$1"
  mkdir -p "$home_dir/.codex" "$home_dir/dotfiles/codex"
  cat > "$home_dir/dotfiles/codex/hooks.json" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.codex/hooks/session-init-icons.sh"
          }
        ]
      }
    ]
  }
}
EOF
  ln -s "$home_dir/dotfiles/codex/hooks.json" "$home_dir/.codex/hooks.json"
  printf '{}\n' > "$home_dir/.codex/hooks.compatibility.json"
}

write_clean_symlinked_user_codex_hooks() {
  local home_dir="$1"
  mkdir -p "$home_dir/.codex" "$home_dir/dotfiles/codex"
  cat > "$home_dir/dotfiles/codex/hooks.json" <<'EOF'
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/tmp/custom-user-hook.sh"
          }
        ]
      }
    ]
  }
}
EOF
  ln -s "$home_dir/dotfiles/codex/hooks.json" "$home_dir/.codex/hooks.json"
}

assert_user_codex_hooks_pruned() {
  local home_dir="$1"
  local hooks_json="$home_dir/.codex/hooks.json"
  [[ ! -e "$home_dir/.codex/hooks.compatibility.json" ]] || fail "expected user-level hooks.compatibility.json to be removed"
  [[ -f "$hooks_json" ]] || fail "expected user-level hooks.json with preserved custom entry"
  local hooks_content
  hooks_content="$(cat "$hooks_json")"
  assert_contains "$hooks_content" "/tmp/custom-user-hook.sh"
  assert_not_contains "$hooks_content" "session-init-icons.sh"
}

assert_malformed_user_codex_hooks_preserved() {
  local home_dir="$1"
  local hooks_json="$home_dir/.codex/hooks.json"
  [[ ! -e "$home_dir/.codex/hooks.compatibility.json" ]] || fail "expected user-level hooks.compatibility.json to be removed"
  [[ -f "$hooks_json" ]] || fail "expected malformed user-level hooks.json to remain for manual repair"
  [[ "$(cat "$hooks_json")" == "{ not valid json" ]] || fail "expected malformed user-level hooks.json content to remain unchanged"
}

assert_symlinked_user_codex_hooks_preserved() {
  local home_dir="$1"
  local hooks_json="$home_dir/.codex/hooks.json"
  [[ ! -e "$home_dir/.codex/hooks.compatibility.json" ]] || fail "expected user-level hooks.compatibility.json to be removed"
  [[ -L "$hooks_json" ]] || fail "expected user-level hooks.json symlink to remain intact"
  [[ "$(readlink "$hooks_json")" == "$home_dir/dotfiles/codex/hooks.json" ]] || fail "expected user-level hooks.json symlink target to remain unchanged"
  assert_contains "$(cat "$home_dir/dotfiles/codex/hooks.json")" "session-init-icons.sh"
}

test_user_hooks_stale_filter_supports_clean_symlink_target() {
  local sandbox home_dir count
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  write_clean_symlinked_user_codex_hooks "$home_dir"

  source "$REPO_ROOT/modules/shared/scripts/lib/rebuild/codex-legacy-hooks.sh"
  count="$(jq -r "$(codex_legacy_user_hook_count_jq_filter)" "$home_dir/.codex/hooks.json")"
  [[ "$count" == "0" ]] || fail "expected clean symlinked user hooks.json stale count 0, got: $count"
}

test_user_hooks_stale_filter_detects_symlink_target_stale_entries() {
  local sandbox home_dir count
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  write_symlinked_user_codex_hooks "$home_dir"

  source "$REPO_ROOT/modules/shared/scripts/lib/rebuild/codex-legacy-hooks.sh"
  count="$(jq -r "$(codex_legacy_user_hook_count_jq_filter)" "$home_dir/.codex/hooks.json")"
  [[ "$count" == "1" ]] || fail "expected symlinked user hooks.json stale count 1, got: $count"
}

test_user_hooks_stale_filter_ignores_stale_path_mentions() {
  local sandbox home_dir hooks_json count
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  hooks_json="$home_dir/.codex/hooks.json"
  mkdir -p "$home_dir/.codex"
  cat > "$hooks_json" <<'EOF'
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/tmp/foo/.codex/hooks/session-init-icons.sh.backup"
          },
          {
            "type": "command",
            "command": "bash -lc 'test -e ~/.codex/hooks/session-init-icons.sh'"
          }
        ]
      }
    ]
  }
}
EOF

  source "$REPO_ROOT/modules/shared/scripts/lib/rebuild/codex-legacy-hooks.sh"
  count="$(HOME="$home_dir" jq -r "$(codex_legacy_user_hook_count_jq_filter)" "$hooks_json")"
  [[ "$count" == "0" ]] || fail "expected stale path mentions to be ignored, got stale count: $count"
}

test_user_hooks_stale_filter_detects_exact_home_path() {
  local sandbox home_dir hooks_json count
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  hooks_json="$home_dir/.codex/hooks.json"
  mkdir -p "$home_dir/.codex"
  cat > "$hooks_json" <<EOF
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$home_dir/.codex/hooks/worktree-path-guard.sh"
          }
        ]
      }
    ]
  }
}
EOF

  source "$REPO_ROOT/modules/shared/scripts/lib/rebuild/codex-legacy-hooks.sh"
  count="$(HOME="$home_dir" jq -r "$(codex_legacy_user_hook_count_jq_filter)" "$hooks_json")"
  [[ "$count" == "1" ]] || fail "expected exact HOME path stale count 1, got: $count"
}

new_sandbox() {
  local dir
  dir=$(mktemp -d "${TMPDIR:-/tmp}/shell-script-tests.XXXXXX")
  printf '%s\n' "$dir" >> "$TEST_TMP_FILE"
  printf '%s\n' "$dir"
}

assert_nix_has_attr() {
  local nix_file="$1" deployed_path="$2"
  shift 2
  local block
  block="$(
    awk -v target="  home.file.\"$deployed_path\" = {" '
      $0 == target { in_block = 1 }
      in_block { print }
      in_block && $0 == "  };" { exit }
    ' "$nix_file"
  )"
  [[ -n "$block" ]] || fail "expected $nix_file to define home.file.\"$deployed_path\""
  local prop
  for prop in "$@"; do
    grep -Fqx "$prop" <<<"$block" >/dev/null || \
      fail "expected $nix_file:$deployed_path to contain exact line: $prop"
  done
}

# register_* — Nix wiring assertion + fixture install을 함께 수행.
# home_dir, generated_dir는 caller의 local 변수에 bash dynamic scoping으로 접근.

register_copy_exec() {
  local nix_file="$1" deployed_path="$2" nix_source_expr="$3" repo_source="$4"
  # shellcheck disable=SC2016  # Literal Nix source string.
  assert_nix_has_attr "$nix_file" "$deployed_path" \
    "    source = \"$nix_source_expr\";" \
    "    executable = true;"
  local gen_name; gen_name="$(basename "$deployed_path")"
  cp "$REPO_ROOT/$repo_source" "$generated_dir/$gen_name"
  chmod +x "$generated_dir/$gen_name"
  ln -sf "$generated_dir/$gen_name" "$home_dir/$deployed_path"
}

register_recursive() {
  local nix_file="$1" deployed_path="$2" nix_source_expr="$3" repo_source="$4"
  # shellcheck disable=SC2016  # Literal Nix source string.
  assert_nix_has_attr "$nix_file" "$deployed_path" \
    "    source = \"$nix_source_expr\";" \
    "    recursive = true;"
  symlink_helper_dir "$REPO_ROOT/$repo_source" "$home_dir/$deployed_path"
}

register_replace_vars() {
  local nix_file="$1" deployed_path="$2" flake_path="$3" repo_source="$4" nix_source_expr="$5" nix_var_line="$6"
  # shellcheck disable=SC2016  # Literal Nix source string.
  assert_nix_has_attr "$nix_file" "$deployed_path" \
    "    source = pkgs.replaceVars \"$nix_source_expr\" {" \
    "$nix_var_line"
  local gen_name; gen_name="$(basename "$deployed_path")"
  sed "s|@flakePath@|$flake_path|g" "$REPO_ROOT/$repo_source" > "$generated_dir/$gen_name"
  ln -sf "$generated_dir/$gen_name" "$home_dir/$deployed_path"
}

read_bash_array_from_script() {
  local script_path="$1"
  local array_name="$2"
  awk -v array_name="$array_name" '
    $0 ~ "^" array_name "=\\(" { in_array=1; next }
    in_array && $0 ~ "^\\)" { exit }
    in_array {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      if ($0 != "") print
    }
  ' "$script_path"
}

symlink_helper_dir() {
  local source_dir="$1"
  local target_dir="$2"
  local file
  local rel_path

  mkdir -p "$target_dir"
  while IFS= read -r file; do
    rel_path="${file#"$source_dir"/}"
    mkdir -p "$(dirname "$target_dir/$rel_path")"
    ln -sf "$file" "$target_dir/$rel_path"
  done < <(find "$source_dir" -type f | sort)
}

install_deployed_layout() {
  local sandbox="$1"
  local flake_path="${2:-$REPO_ROOT}"
  local home_dir="$sandbox/home"
  local generated_dir="$sandbox/generated"
  local shell_nix="$REPO_ROOT/modules/shared/programs/shell/default.nix"

  mkdir -p "$home_dir/.local/bin" "$home_dir/.local/lib" "$generated_dir"

  # shellcheck disable=SC2016  # Literal Nix source strings.
  register_copy_exec "$shell_nix" ".local/bin/wt" \
    '${sharedScriptsDir}/wt.sh' "modules/shared/scripts/wt.sh"

  # codex-sync: Nix 배포 있지만 테스트에서는 fixture stub 사용 (shadow-path 테스트용)
  # cp로 sandbox에 복사하여 원본 fixture 보호
  cp "$FIXTURE_DIR/bin/codex-sync" "$generated_dir/codex-sync"
  chmod +x "$generated_dir/codex-sync"
  ln -sf "$generated_dir/codex-sync" "$home_dir/.local/bin/codex-sync"

  # shellcheck disable=SC2016  # Literal Nix source strings.
  register_recursive "$shell_nix" ".local/lib/wt" \
    '${sharedScriptsDir}/lib/wt' "modules/shared/scripts/lib/wt"

  # shellcheck disable=SC2016  # Literal Nix source strings.
  register_replace_vars "$shell_nix" ".local/lib/rebuild-common.sh" \
    "$flake_path" "modules/shared/scripts/rebuild-common.sh" \
    '${sharedScriptsDir}/rebuild-common.sh' \
    '      flakePath = nixosConfigDefaultPath;'

  # shellcheck disable=SC2016  # Literal Nix source strings.
  register_recursive "$shell_nix" ".local/lib/rebuild" \
    '${sharedScriptsDir}/lib/rebuild' "modules/shared/scripts/lib/rebuild"

  # cross-cutting: recursive 배포가 정확히 2개
  assert_line_count "$shell_nix" '    recursive = true;' 2
}

install_repo_local_only_codex_cleanup_helper() {
  local home_dir="$1"
  local helper="$home_dir/.local/lib/rebuild/common.sh"
  rm -f "$helper"
  cp "$REPO_ROOT/modules/shared/scripts/lib/rebuild/common.sh" "$helper"
  cat >> "$helper" <<'EOF'

_clear_retired_codex_hook_artifacts() {
    local hooks_json="$FLAKE_PATH/.codex/hooks.json"
    local hooks_report="$FLAKE_PATH/.codex/hooks.compatibility.json"

    if [[ -e "$hooks_json" || -e "$hooks_report" ]]; then
        rm -f "$hooks_json" "$hooks_report"
        log_info "🧹 Removed retired Codex hook artifacts."
    fi
}
EOF
}

install_partial_deployed_codex_legacy_hooks_helper() {
  local home_dir="$1"
  local helper="$home_dir/.local/lib/rebuild/codex-legacy-hooks.sh"
  mkdir -p "$(dirname "$helper")"
  rm -f "$helper"
  cat > "$helper" <<'EOF'
# Partial old deployed helper fixture: readable, but missing codex_clear_retired_hook_artifacts.
codex_partial_legacy_hooks_helper_loaded() {
    return 0
}
EOF
}

install_repo_fallback_codex_legacy_hooks_helper() {
  local repo_root="$1"
  local helper="$repo_root/modules/shared/scripts/lib/rebuild/codex-legacy-hooks.sh"
  mkdir -p "$(dirname "$helper")"
  cp "$REPO_ROOT/modules/shared/scripts/lib/rebuild/codex-legacy-hooks.sh" "$helper"
}

install_platform_nrs_entrypoint() {
  local sandbox="$1" platform="$2"
  local home_dir="$sandbox/home"
  local generated_dir="$sandbox/generated"

  mkdir -p "$home_dir/.local/bin" "$generated_dir"

  # shellcheck disable=SC2016  # Literal Nix source strings.
  case "$platform" in
    darwin)
      register_copy_exec \
        "$REPO_ROOT/modules/shared/programs/shell/darwin.nix" \
        ".local/bin/nrs" \
        '${darwinScriptsDir}/nrs.sh' \
        "modules/darwin/scripts/nrs.sh"
      ;;
    nixos)
      register_copy_exec \
        "$REPO_ROOT/modules/shared/programs/shell/nixos.nix" \
        ".local/bin/nrs" \
        '${nixosScriptsDir}/nrs.sh' \
        "modules/nixos/scripts/nrs.sh"
      ;;
    *) fail "unknown platform for nrs entrypoint: $platform" ;;
  esac
}

create_git_fixture_repo() {
  local repo_root="$1"
  local sandbox_root home_dir
  sandbox_root="$(dirname "$repo_root")"
  home_dir="$sandbox_root/home"

  fixture_git() {
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

  mkdir -p "$repo_root/.claude/worktrees" "$home_dir/.config"
  (
    cd "$repo_root"
    fixture_git init >/dev/null 2>&1
    fixture_git branch -M main >/dev/null 2>&1
    fixture_git config user.name "Test User"
    fixture_git config user.email "test@example.com"
    echo "fixture" > README.md
    fixture_git add README.md
    fixture_git commit -m "initial" >/dev/null 2>&1
    fixture_git worktree add ".claude/worktrees/feature_one" -b feature-one >/dev/null 2>&1
  )
}

run_test() {
  local name="$1"
  shift
  echo "==> $name"
  "$@"
}

# ─── codex-config fixture helpers ───
# sync-codex-config.py의 sync/check 계약을 fixture 기반으로 고정.
# tomlkit 의존이 필요하므로 lefthook 밖 직접 실행 시에는 tomlkit import 가능 여부에 따라
# 조건부로 돌린다. lefthook pre-push는 repo-pinned `nix shell .#pythonWithTomlkit --command`로
# wrap 되어 항상 가용.
CODEX_CONFIG_SCRIPT="$REPO_ROOT/modules/shared/programs/codex/files/sync-codex-config.py"
CODEX_CONFIG_FIXTURE_DIR="$FIXTURE_DIR/codex-config"

codex_config_tomlkit_available() {
  command -v python3 >/dev/null 2>&1 && python3 -c 'import tomlkit' >/dev/null 2>&1
}

toml_semantic_equal() {
  # $1, $2 모두 path. parse 후 동등성 비교.
  python3 - "$1" "$2" <<'PY'
import sys, tomllib
try:
    with open(sys.argv[1], 'rb') as fa, open(sys.argv[2], 'rb') as fb:
        a = tomllib.load(fa)
        b = tomllib.load(fb)
except Exception as e:
    print(f"parse error: {e}", file=sys.stderr)
    sys.exit(2)
sys.exit(0 if a == b else 1)
PY
}

json_semantic_equal() {
  # $1 = actual JSON string, $2 = expected JSON path.
  # expected는 {"target_state":..,"drift":[...]} 부분 집합만 검증 (template/target 경로는 runtime 값이라 비교 제외).
  python3 - "$1" "$2" <<'PY'
import sys, json
try:
    actual = json.loads(sys.argv[1])
except Exception as e:
    print(f"actual JSON parse error: {e}", file=sys.stderr)
    sys.exit(2)
try:
    with open(sys.argv[2]) as f:
        expected = json.load(f)
except Exception as e:
    print(f"expected JSON read error: {e}", file=sys.stderr)
    sys.exit(2)
for key in expected:
    if actual.get(key) != expected[key]:
        print(f"mismatch on '{key}': expected={expected[key]!r} actual={actual.get(key)!r}", file=sys.stderr)
        sys.exit(1)
sys.exit(0)
PY
}

test_codex_config_sync_fixtures() {
  local scenario sandbox template existing expected actual rc
  for scenario in sync_basic_merge sync_malformed_root sync_malformed_toml_quarantine sync_quoted_dotted_key; do
    local dir="$CODEX_CONFIG_FIXTURE_DIR/$scenario"
    [[ -d "$dir" ]] || fail "sync fixture missing: $dir"
    sandbox=$(new_sandbox)
    template="$dir/template.toml"
    existing="$dir/existing.toml"
    expected="$dir/expected.toml"
    actual="$sandbox/target.toml"

    [[ -f "$existing" ]] && cp "$existing" "$actual"

    # sync subcommand 호출
    if ! python3 "$CODEX_CONFIG_SCRIPT" sync "$template" "$actual" 2>/dev/null; then
      fail "sync($scenario) exited non-zero"
    fi
    [[ -f "$actual" ]] || fail "sync($scenario) did not produce target"
    if ! toml_semantic_equal "$actual" "$expected"; then
      echo "--- actual ($scenario) ---" >&2
      cat "$actual" >&2
      echo "--- expected ($scenario) ---" >&2
      cat "$expected" >&2
      fail "sync($scenario) result ≠ expected"
    fi
  done
}

# ─── no-op 3조건 검증 helpers ───
# no-op invariant (regular file / mode 0o600 / byte-identical) 의 authoritative 서술은
# modules/shared/programs/codex/files/sync-codex-config.py docstring 의 "No-op suppression"
# 블록과 `_noop_probe_target` docstring 에 있다. 세 시나리오 모두 동일 fixture
# `sync_noop_baseline/` 을 공유하고, 테스트 함수 본문의 FS 셋업(`chmod 0644`, `ln -s`)이
# 어느 invariant 를 깨는지를 구분한다.

# GNU `stat -c` / BSD `stat -f` 를 모두 지원하는 helper. "%a"/"%p" 3자리 octal을 반환.
_codex_config_file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

# GNU coreutils `sha256sum` 이 없는 macOS 에서도 동일 결과를 내기 위해 `shasum -a 256` 으로
# fallback. 둘 다 없는 환경은 shell-script-tests 전제를 만족하지 못하므로 여기서 fail.
_codex_config_hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    fail "neither sha256sum nor shasum available for codex-config test hashing"
  fi
}

test_codex_config_sync_noop_preserves_bytes() {
  # existing ==(첫 sync 후)== target stable state 이고 mode 0600 이면 두 번째 sync 는
  # stderr empty + bytes unchanged 여야 한다.
  local dir="$CODEX_CONFIG_FIXTURE_DIR/sync_noop_baseline"
  local sandbox target first_hash second_hash second_stderr mode_after
  sandbox=$(new_sandbox)
  target="$sandbox/target.toml"

  cp "$dir/existing.toml" "$target"
  chmod 0600 "$target"

  # 1차 sync: tomlkit round-trip 정규화를 반영해 stable bytes 를 만든다. stderr 는 관찰 안 함.
  python3 "$CODEX_CONFIG_SCRIPT" sync "$dir/template.toml" "$target" >/dev/null 2>&1 \
    || fail "sync_noop_preserves_bytes: first sync exited non-zero"
  first_hash=$(_codex_config_hash "$target")

  # 2차 sync: 3조건 모두 성립 → no-op. stderr 비어 있어야 한다.
  second_stderr=$(python3 "$CODEX_CONFIG_SCRIPT" sync "$dir/template.toml" "$target" 2>&1 >/dev/null)
  [[ -z "$second_stderr" ]] \
    || fail "sync_noop_preserves_bytes: expected empty stderr on second sync, got: $second_stderr"

  second_hash=$(_codex_config_hash "$target")
  [[ "$first_hash" == "$second_hash" ]] \
    || fail "sync_noop_preserves_bytes: bytes changed between first and second sync"

  mode_after=$(_codex_config_file_mode "$target")
  [[ "$mode_after" == "600" ]] \
    || fail "sync_noop_preserves_bytes: mode=$mode_after (expected 600)"
}

test_codex_config_sync_rejects_bad_mode() {
  # 내용은 byte-identical 이지만 mode 가 0644 이면 no-op 이 아니라 write 가 발생해
  # mode 0600 으로 복구되어야 한다.
  local dir="$CODEX_CONFIG_FIXTURE_DIR/sync_noop_baseline"
  local sandbox target second_stderr mode_after
  sandbox=$(new_sandbox)
  target="$sandbox/target.toml"

  cp "$dir/existing.toml" "$target"
  chmod 0600 "$target"
  # 1차 sync: stable bytes 확보.
  python3 "$CODEX_CONFIG_SCRIPT" sync "$dir/template.toml" "$target" >/dev/null 2>&1 \
    || fail "sync_rejects_bad_mode: first sync exited non-zero"

  chmod 0644 "$target"   # mode drift 유발. bytes 는 그대로.

  second_stderr=$(python3 "$CODEX_CONFIG_SCRIPT" sync "$dir/template.toml" "$target" 2>&1 >/dev/null)
  [[ -n "$second_stderr" ]] \
    || fail "sync_rejects_bad_mode: expected summary log on write, stderr empty"

  mode_after=$(_codex_config_file_mode "$target")
  [[ "$mode_after" == "600" ]] \
    || fail "sync_rejects_bad_mode: mode=$mode_after after sync (expected 600)"
}

test_codex_config_sync_rejects_symlink() {
  # target 이 symlink 면 byte-identical 여부와 무관하게 write 가 발생해 regular file 로
  # 교체되어야 한다. 내부적으로 os.replace 가 symlink 를 regular file 로 치환한다.
  local dir="$CODEX_CONFIG_FIXTURE_DIR/sync_noop_baseline"
  local sandbox target backing second_stderr mode_after
  sandbox=$(new_sandbox)
  target="$sandbox/target.toml"
  backing="$sandbox/backing.toml"

  cp "$dir/existing.toml" "$backing"
  chmod 0600 "$backing"
  # 1차 sync: stable bytes 확보 (backing 대상). symlink 로 인한 write 동작 자체를 본 테스트
  # 에서 검증하므로 1차 sync 는 backing 에 직접 호출한다.
  python3 "$CODEX_CONFIG_SCRIPT" sync "$dir/template.toml" "$backing" >/dev/null 2>&1 \
    || fail "sync_rejects_symlink: backing first sync exited non-zero"

  ln -s "$backing" "$target"
  [[ -L "$target" ]] || fail "sync_rejects_symlink: symlink setup failed"

  second_stderr=$(python3 "$CODEX_CONFIG_SCRIPT" sync "$dir/template.toml" "$target" 2>&1 >/dev/null)
  [[ -n "$second_stderr" ]] \
    || fail "sync_rejects_symlink: expected summary log on write, stderr empty"

  [[ -L "$target" ]] && fail "sync_rejects_symlink: target is still a symlink after sync"
  [[ -f "$target" ]] || fail "sync_rejects_symlink: target is not a regular file after sync"
  mode_after=$(_codex_config_file_mode "$target")
  [[ "$mode_after" == "600" ]] \
    || fail "sync_rejects_symlink: mode=$mode_after after sync (expected 600)"
}

test_codex_config_bare_sync_compat() {
  # bare 2-arg 호출 결과가 explicit sync subcommand 호출과 동일해야 한다.
  local dir="$CODEX_CONFIG_FIXTURE_DIR/bare_sync_compat"
  local sandbox sub_result bare_result
  sandbox=$(new_sandbox)
  sub_result="$sandbox/via_sub.toml"
  bare_result="$sandbox/via_bare.toml"

  cp "$dir/existing.toml" "$sub_result"
  cp "$dir/existing.toml" "$bare_result"

  python3 "$CODEX_CONFIG_SCRIPT" sync "$dir/template.toml" "$sub_result" 2>/dev/null \
    || fail "bare_sync_compat: sync subcommand exited non-zero"
  python3 "$CODEX_CONFIG_SCRIPT" "$dir/template.toml" "$bare_result" 2>/dev/null \
    || fail "bare_sync_compat: bare 2-arg exited non-zero"

  toml_semantic_equal "$sub_result" "$bare_result" \
    || fail "bare_sync_compat: bare 2-arg result ≠ sync subcommand result"
  toml_semantic_equal "$sub_result" "$dir/expected.toml" \
    || fail "bare_sync_compat: sync result ≠ expected"
}

test_codex_config_check_fixtures() {
  local scenario dir sandbox template target_path actual_stdout actual_stderr rc expected_exit
  for scenario in check_match check_value_mismatch check_missing_leaf check_type_mismatch \
                  check_target_missing check_template_missing check_template_parse_error \
                  check_quoted_dotted_key_match check_quoted_dotted_key_value_mismatch \
                  check_empty_template; do
    dir="$CODEX_CONFIG_FIXTURE_DIR/$scenario"
    [[ -d "$dir" ]] || fail "check fixture missing: $dir"
    sandbox=$(new_sandbox)
    actual_stdout="$sandbox/stdout"
    actual_stderr="$sandbox/stderr"

    if [[ -f "$dir/template.toml" ]]; then
      template="$dir/template.toml"
    else
      template="$sandbox/nonexistent-template.toml"
    fi
    if [[ -f "$dir/target.toml" ]]; then
      target_path="$sandbox/target.toml"
      cp "$dir/target.toml" "$target_path"
    else
      target_path="$sandbox/nonexistent-target.toml"
    fi

    rc=0
    python3 "$CODEX_CONFIG_SCRIPT" check "$template" "$target_path" \
      >"$actual_stdout" 2>"$actual_stderr" || rc=$?

    expected_exit="$(cat "$dir/expected_exit" | tr -d '[:space:]')"
    [[ "$rc" == "$expected_exit" ]] \
      || fail "check($scenario): expected exit $expected_exit, got $rc. stderr: $(cat "$actual_stderr")"

    if [[ -f "$dir/expected_drift.json" ]]; then
      # stdout의 JSON을 기대치와 semantic 비교
      local stdout_content
      stdout_content="$(cat "$actual_stdout")"
      [[ -n "$stdout_content" ]] || fail "check($scenario): stdout empty (expected JSON)"
      json_semantic_equal "$stdout_content" "$dir/expected_drift.json" \
        || fail "check($scenario): JSON mismatch"
    fi

    if [[ -f "$dir/expected_stderr_substring" ]]; then
      local needle
      needle="$(cat "$dir/expected_stderr_substring" | tr -d '\n')"
      assert_contains "$(cat "$actual_stderr")" "$needle"
      [[ ! -s "$actual_stdout" ]] || fail "check($scenario): expected empty stdout on EXIT_ERROR, got: $(cat "$actual_stdout")"
    fi
  done
}


test_wt_help_from_deployed_layout() {
  local sandbox output
  sandbox=$(new_sandbox)
  install_deployed_layout "$sandbox"

  output=$(
    HOME="$sandbox/home" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    bash "$sandbox/home/.local/bin/wt" --help 2>&1
  )

  assert_contains "$output" "사용법: wt"
  assert_contains "$output" "wt cleanup [--auto]"
}

test_rebuild_common_exports_public_api() {
  local sandbox output
  sandbox=$(new_sandbox)
  install_deployed_layout "$sandbox"

  output=$(
    HOME="$sandbox/home" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    bash -c '
      set -euo pipefail
      REBUILD_CMD="nixos-rebuild"
      source "'"$sandbox/home/.local/lib/rebuild-common.sh"'"
      parse_args --offline --force --cores 2
      printf "offline=%s\nforce=%s\ncores=%s\n" "$OFFLINE_FLAG" "$FORCE_FLAG" "$CORES_FLAG"
      declare -F log_info
      declare -F log_warn
      declare -F log_error
      declare -F acquire_nrs_lock
      declare -F release_nrs_lock
      declare -F release_nrs_lock_after_no_changes
      declare -F release_nrs_lock_on_failure
      declare -F mark_nrs_lock_switch_success
      declare -F acquire_rebuild_lock
      declare -F release_rebuild_lock
      declare -F release_rebuild_lock_on_failure
      declare -F preflight_source_build_check
      declare -F preflight_cask_conflict_check
      declare -F rebuild_is_main_flake
      declare -F prepare_worktree_symlinks_for_rebuild
      declare -F preview_changes
      declare -F worktree_symlink_guard
      declare -F maybe_relink_or_restore
      declare -F cleanup_build_artifacts
      declare -F repair_codex_config_drift_no_changes
    ' 2>&1
  )

  assert_contains "$output" "offline=--offline"
  assert_contains "$output" "force=true"
  assert_contains "$output" "cores=--cores 2"
  assert_contains "$output" "log_info"
  assert_contains "$output" "log_warn"
  assert_contains "$output" "log_error"
  assert_contains "$output" "acquire_nrs_lock"
  assert_contains "$output" "release_nrs_lock"
  assert_contains "$output" "release_nrs_lock_after_no_changes"
  assert_contains "$output" "release_nrs_lock_on_failure"
  assert_contains "$output" "mark_nrs_lock_switch_success"
  assert_contains "$output" "acquire_rebuild_lock"
  assert_contains "$output" "release_rebuild_lock"
  assert_contains "$output" "release_rebuild_lock_on_failure"
  assert_contains "$output" "preflight_source_build_check"
  assert_contains "$output" "preflight_cask_conflict_check"
  assert_contains "$output" "rebuild_is_main_flake"
  assert_contains "$output" "prepare_worktree_symlinks_for_rebuild"
  assert_contains "$output" "preview_changes"
  assert_contains "$output" "worktree_symlink_guard"
  assert_contains "$output" "maybe_relink_or_restore"
}

test_detect_worktree_uses_current_worktree_path() {
  local sandbox home_dir repo_root worktree_root output
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  worktree_root="$repo_root/.claude/worktrees/feature_one"
  install_deployed_layout "$sandbox" "$repo_root"

  output=$(
    HOME="$home_dir" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    bash -c '
      set -euo pipefail
      cd "'"$worktree_root"'"
      REBUILD_CMD="nixos-rebuild"
      source "'"$home_dir/.local/lib/rebuild-common.sh"'"
      printf "flake=%s\nis_main=%s\n" \
        "$FLAKE_PATH" \
        "$(rebuild_is_main_flake && echo true || echo false)"
    ' 2>&1
  )

  assert_contains "$output" "flake=$worktree_root"
  assert_contains "$output" "is_main=false"
}

test_wt_ls_from_deployed_layout_lists_worktrees() {
  local sandbox home_dir repo_root output
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"

  install_deployed_layout "$sandbox"
  create_git_fixture_repo "$repo_root"

  output=$(
    HOME="$home_dir" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/wt"'" ls
    ' 2>&1
  )

  assert_contains "$output" "Worktrees (1)"
  assert_contains "$output" "feature_one"
}

test_wt_cd_by_name_returns_target_path() {
  local sandbox home_dir repo_root output expected_path
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  expected_path="$repo_root/.claude/worktrees/feature_one"
  output=$(
    env -u TMUX \
      HOME="$home_dir" \
      PATH="$FIXTURE_DIR/bin:$PATH" \
      bash -c '
        set -euo pipefail
        cd "'"$repo_root"'"
        "'"$home_dir/.local/bin/wt"'" cd feature_one
      ' 2>&1
  )

  assert_contains "$output" "$expected_path"
}

test_shadow_paths_do_not_override_managed_helpers() {
  local sandbox home_dir repo_root worktree_root output
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  worktree_root="$repo_root/.claude/worktrees/feature_one"
  install_deployed_layout "$sandbox" "$repo_root"

  mkdir -p "$home_dir/.local/bin/lib/wt" "$home_dir/.local/lib/lib/rebuild"
  cat > "$home_dir/.local/bin/lib/wt/ui.sh" <<'EOF'
echo "SHADOW_WT_HELPER" >&2
EOF
  while IFS= read -r helper; do
    [[ "$helper" == "ui" ]] && continue
    cat > "$home_dir/.local/bin/lib/wt/$helper.sh" <<'EOF'
:
EOF
  done < <(read_bash_array_from_script "$REPO_ROOT/modules/shared/scripts/wt.sh" "WT_HELPERS")
  while IFS= read -r helper; do
    cat > "$home_dir/.local/lib/lib/rebuild/$helper.sh" <<'EOF'
echo "SHADOW_REBUILD_HELPER" >&2
EOF
  done < <(read_bash_array_from_script "$REPO_ROOT/modules/shared/scripts/rebuild-common.sh" "REBUILD_HELPERS")
  cat > "$home_dir/.local/bin/codex-sync.sh" <<'EOF'
#!/usr/bin/env bash
echo "SHADOW_CODEX_SYNC" >&2
exit 0
EOF
  chmod +x "$home_dir/.local/bin/codex-sync.sh"

  output=$(
    HOME="$home_dir" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    bash -c '
      set -euo pipefail
      cd "'"$worktree_root"'"
      REBUILD_CMD="nixos-rebuild"
      source "'"$home_dir/.local/lib/rebuild-common.sh"'"
      "'"$home_dir/.local/bin/wt"'" --help
    ' 2>&1
  )

  assert_not_contains "$output" "SHADOW_WT_HELPER"
  assert_not_contains "$output" "SHADOW_REBUILD_HELPER"
  assert_not_contains "$output" "SHADOW_CODEX_SYNC"
}

test_wt_symlink_alias_does_not_load_adjacent_helpers() {
  local sandbox home_dir alias_dir alias_path output
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  alias_dir="$sandbox/alias/bin"
  alias_path="$alias_dir/wt"

  install_deployed_layout "$sandbox"

  mkdir -p "$sandbox/alias/lib/wt" "$alias_dir"
  ln -sf "$REPO_ROOT/modules/shared/scripts/wt.sh" "$alias_path"
  cat > "$sandbox/alias/lib/wt/ui.sh" <<'EOF'
echo "MALICIOUS_WT" >&2
EOF

  output=$(
    HOME="$home_dir" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    bash "$alias_path" --help 2>&1 || true
  )

  assert_contains "$output" "helper directory not found"
  assert_not_contains "$output" "MALICIOUS_WT"
}

test_rebuild_common_symlink_alias_does_not_load_adjacent_helpers() {
  local sandbox home_dir alias_dir alias_path output generated_dir
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  alias_dir="$sandbox/alias/lib"
  alias_path="$alias_dir/rebuild-common.sh"
  generated_dir="$sandbox/generated"

  install_deployed_layout "$sandbox"

  mkdir -p "$sandbox/alias/lib/rebuild" "$alias_dir" "$generated_dir"
  sed "s|@flakePath@|$REPO_ROOT|g" \
    "$REPO_ROOT/modules/shared/scripts/rebuild-common.sh" > "$generated_dir/rebuild-common.sh"
  ln -sf "$generated_dir/rebuild-common.sh" "$alias_path"
  cat > "$sandbox/alias/lib/rebuild/common.sh" <<'EOF'
echo "MALICIOUS_REBUILD" >&2
EOF

  output=$(
    HOME="$home_dir" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    bash -c '
      set -euo pipefail
      REBUILD_CMD="nixos-rebuild"
      source "'"$alias_path"'"
      printf "loaded\n"
    ' 2>&1 || true
  )

  assert_contains "$output" "helper directory not found"
  assert_not_contains "$output" "MALICIOUS_REBUILD"
}

test_wt_create_creates_worktree_without_shadow_codex_sync() {
  local sandbox home_dir repo_root output new_worktree fallback_dir marker_file
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  fallback_dir="$sandbox/fallback-bin"
  marker_file="$sandbox/codex-sync-marker"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  mkdir -p "$home_dir/.local/bin" "$fallback_dir"
  cat > "$home_dir/.local/bin/codex-sync" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'managed\n' >> "${CODEX_SYNC_MARKER:?}"
exit 0
EOF
  chmod +x "$home_dir/.local/bin/codex-sync"
  cat > "$home_dir/.local/bin/codex-sync.sh" <<'EOF'
#!/usr/bin/env bash
echo "SHADOW_CODEX_SYNC" >&2
exit 0
EOF
  chmod +x "$home_dir/.local/bin/codex-sync.sh"
  cat > "$fallback_dir/codex-sync" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'fallback\n' >> "${CODEX_SYNC_MARKER:?}"
exit 0
EOF
  chmod +x "$fallback_dir/codex-sync"

  output=$(
    env -u TMUX \
      HOME="$home_dir" \
      PATH="$fallback_dir:$FIXTURE_DIR/bin:$PATH" \
      CODEX_SYNC_MARKER="$marker_file" \
      bash -c '
        set -euo pipefail
        cd "'"$repo_root"'"
        "'"$home_dir/.local/bin/wt"'" feature-two
      ' 2>&1
  )

  new_worktree="$repo_root/.claude/worktrees/feature-two"
  [[ -d "$new_worktree" ]] || fail "expected worktree directory to exist: $new_worktree"
  assert_contains "$output" "$new_worktree"
  assert_not_contains "$output" "SHADOW_CODEX_SYNC"
  assert_contains "$(cat "$marker_file")" "managed"
  assert_not_contains "$(cat "$marker_file")" "fallback"
}

test_wt_recreate_guard_uses_physical_paths() {
  local sandbox home_dir repo_root link_root target_path fzf_dir origin_dir output
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  link_root="$sandbox/link"
  fzf_dir="$sandbox/fzf-bin"
  origin_dir="$sandbox/origin.git"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  git init --bare "$origin_dir" >/dev/null 2>&1
  git -C "$repo_root" remote add origin "$origin_dir"
  git -C "$repo_root/.claude/worktrees/feature_one" push -u origin feature-one >/dev/null 2>&1
  ln -s "$repo_root" "$link_root"
  target_path="$link_root/.claude/worktrees/feature_one"

  mkdir -p "$fzf_dir"
  cat > "$fzf_dir/fzf" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '재생성\n'
EOF
  chmod +x "$fzf_dir/fzf"

  output=$(
    HOME="$home_dir" \
    PATH="$fzf_dir:$FIXTURE_DIR/bin:$PATH" \
    bash -c '
      set -euo pipefail
      cd "'"$target_path"'"
      "'"$home_dir/.local/bin/wt"'" feature/one
    ' 2>&1 || true
  )

  assert_contains "$output" "재생성 불가: 현재 작업 디렉토리가 이 worktree 안에 있습니다"
  [[ -d "$repo_root/.claude/worktrees/feature_one" ]] || fail "expected original worktree to survive recreate guard"
}

test_wt_cleanup_auto_removes_merged_worktree() {
  local sandbox home_dir repo_root gh_dir output target_path head_oid
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  gh_dir="$sandbox/gh-bin"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  git -C "$repo_root" remote add origin https://example.invalid/nixos-config.git
  target_path="$repo_root/.claude/worktrees/feature_one"
  head_oid="$(git -C "$target_path" rev-parse HEAD)"

  mkdir -p "$gh_dir"
  cat > "$gh_dir/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'MERGED %s\n' "$head_oid"
EOF
  chmod +x "$gh_dir/gh"

  output=$(
    HOME="$home_dir" \
    PATH="$gh_dir:$FIXTURE_DIR/bin:$PATH" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/wt"'" cleanup --auto
    ' 2>&1
  )

  assert_contains "$output" "자동 정리 완료"
  [[ ! -d "$target_path" ]] || fail "expected merged worktree to be removed: $target_path"
}

test_wt_cleanup_auto_skips_dirty_merged_worktree() {
  local sandbox home_dir repo_root gh_dir output target_path head_oid
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  gh_dir="$sandbox/gh-bin"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  git -C "$repo_root" remote add origin https://example.invalid/nixos-config.git
  target_path="$repo_root/.claude/worktrees/feature_one"
  head_oid="$(git -C "$target_path" rev-parse HEAD)"
  echo "dirty" > "$target_path/dirty.txt"

  mkdir -p "$gh_dir"
  cat > "$gh_dir/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'MERGED %s\n' "$head_oid"
EOF
  chmod +x "$gh_dir/gh"

  output=$(
    HOME="$home_dir" \
    PATH="$gh_dir:$FIXTURE_DIR/bin:$PATH" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/wt"'" cleanup --auto
    ' 2>&1
  )

  assert_contains "$output" "스킵: feature_one (dirty 있음)"
  [[ -d "$target_path" ]] || fail "expected dirty worktree to be kept: $target_path"
}

test_wt_cleanup_auto_skips_unpushed_with_upstream() {
  local sandbox home_dir repo_root gh_dir origin_dir output target_path head_oid
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  gh_dir="$sandbox/gh-bin"
  origin_dir="$sandbox/origin.git"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  git init --bare "$origin_dir" >/dev/null 2>&1
  git -C "$repo_root" remote add origin "$origin_dir"
  target_path="$repo_root/.claude/worktrees/feature_one"
  git -C "$target_path" push -u origin feature-one >/dev/null 2>&1
  echo "ahead" >> "$target_path/README.md"
  git -C "$target_path" add README.md
  git -C "$target_path" commit -m "ahead" >/dev/null 2>&1
  head_oid="$(git -C "$target_path" rev-parse HEAD)"

  mkdir -p "$gh_dir"
  cat > "$gh_dir/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'MERGED %s\n' "$head_oid"
EOF
  chmod +x "$gh_dir/gh"

  output=$(
    HOME="$home_dir" \
    PATH="$gh_dir:$FIXTURE_DIR/bin:$PATH" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/wt"'" cleanup --auto
    ' 2>&1
  )

  assert_contains "$output" "스킵: feature_one (merge 후 추가 커밋 있음)"
  [[ -d "$target_path" ]] || fail "expected unpushed worktree to be kept: $target_path"
}

test_wt_cleanup_auto_skips_merged_branch_reuse() {
  local sandbox home_dir repo_root gh_dir output target_path
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  gh_dir="$sandbox/gh-bin"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  target_path="$repo_root/.claude/worktrees/feature_one"
  mkdir -p "$gh_dir"
  cat > "$gh_dir/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'MERGED deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n'
EOF
  chmod +x "$gh_dir/gh"

  output=$(
    HOME="$home_dir" \
    PATH="$gh_dir:$FIXTURE_DIR/bin:$PATH" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/wt"'" cleanup --auto
    ' 2>&1
  )

  assert_contains "$output" "자동 정리 대상 (MERGED)이 없습니다"
  [[ -d "$target_path" ]] || fail "expected reused branch worktree to be kept: $target_path"
}

test_missing_managed_helpers_fail_closed() {
  local sandbox home_dir repo_root output
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  rm -rf "$home_dir/.local/lib/wt" "$home_dir/.local/lib/rebuild"
  mkdir -p "$home_dir/.local/bin/lib/wt" "$home_dir/.local/lib/lib/rebuild"
  cat > "$home_dir/.local/bin/lib/wt/ui.sh" <<'EOF'
echo "SHADOW_WT_LOADED" >&2
EOF
  cat > "$home_dir/.local/lib/lib/rebuild/common.sh" <<'EOF'
echo "SHADOW_REBUILD_LOADED" >&2
EOF

  output=$(
    HOME="$home_dir" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    bash "$home_dir/.local/bin/wt" --help 2>&1 || true
  )
  assert_contains "$output" "helper directory not found"
  assert_not_contains "$output" "SHADOW_WT_LOADED"

  output=$(
    HOME="$home_dir" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    bash -c '
      set -euo pipefail
      REBUILD_CMD="nixos-rebuild"
      source "'"$home_dir/.local/lib/rebuild-common.sh"'"
    ' 2>&1 || true
  )
  assert_contains "$output" "helper directory not found"
  assert_not_contains "$output" "SHADOW_REBUILD_LOADED"
}

test_fixture_git_is_hermetic_against_global_hooks() {
  local sandbox repo_root hook_dir global_config hook_marker
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  hook_dir="$sandbox/global-hooks"
  global_config="$sandbox/global-gitconfig"
  hook_marker="$sandbox/HOOK_RAN"

  mkdir -p "$hook_dir"
  cat > "$hook_dir/pre-commit" <<EOF
#!/usr/bin/env bash
echo hook-ran > "$hook_marker"
exit 1
EOF
  chmod +x "$hook_dir/pre-commit"
  cat > "$global_config" <<EOF
[core]
	hooksPath = $hook_dir
EOF

  GIT_CONFIG_GLOBAL="$global_config" create_git_fixture_repo "$repo_root"

  [[ -d "$repo_root/.git" ]] || fail "expected fixture repo to be created"
  [[ ! -e "$hook_marker" ]] || fail "expected fixture git setup to ignore host global hooks"
}

test_nixos_nrs_offline_force_smoke() {
  local sandbox home_dir repo_root stub_dir output result_target
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stub-bin"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  install_platform_nrs_entrypoint "$sandbox" nixos
  install_repo_local_only_codex_cleanup_helper "$home_dir"
  install_partial_deployed_codex_legacy_hooks_helper "$home_dir"
  install_repo_fallback_codex_legacy_hooks_helper "$repo_root"

  mkdir -p "$stub_dir" "$home_dir/.local/bin"
  cat > "$stub_dir/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
"$@"
EOF
  cat > "$stub_dir/nixos-rebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  build)
    ln -sfn "${NRS_RESULT_TARGET:?}" ./result
    ;;
  switch)
    :
    ;;
  *)
    echo "unexpected nixos-rebuild subcommand: $1" >&2
    exit 1
    ;;
esac
EOF
  cat > "$stub_dir/nvd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "stub nvd diff"
EOF
  cat > "$home_dir/.local/bin/nrs-relink" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "$stub_dir/sudo" "$stub_dir/nixos-rebuild" "$stub_dir/nvd" "$home_dir/.local/bin/nrs-relink"

  result_target="$sandbox/current-system"
  mkdir -p "$result_target"
  mkdir -p "$repo_root/.codex"
  printf '{}\n' > "$repo_root/.codex/hooks.json"
  printf '{}\n' > "$repo_root/.codex/hooks.compatibility.json"
  write_mixed_user_codex_hooks "$home_dir"

  output=$(
    HOME="$home_dir" \
    PATH="$stub_dir:$FIXTURE_DIR/bin:$PATH" \
    NRS_RESULT_TARGET="$result_target" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/nrs"'" --offline --force
    ' 2>&1
  )

  assert_contains "$output" "Applying changes (offline)"
  assert_contains "$output" "Done!"
  assert_contains "$output" "Removed retired user-level Codex hooks.compatibility.json"
  assert_contains "$output" "Pruned 1 stale Codex hook entry"
  [[ ! -e "$repo_root/.codex/hooks.json" ]] || fail "expected nixos nrs to remove retired hooks.json"
  [[ ! -e "$repo_root/.codex/hooks.compatibility.json" ]] || fail "expected nixos nrs to remove retired hooks.compatibility.json"
  assert_user_codex_hooks_pruned "$home_dir"
}

test_clear_retired_codex_hook_artifacts_preserves_malformed_user_hooks() {
  local sandbox home_dir repo_root output
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  mkdir -p "$repo_root/.codex"
  printf '{}\n' > "$repo_root/.codex/hooks.json"
  printf '{}\n' > "$repo_root/.codex/hooks.compatibility.json"
  write_malformed_user_codex_hooks "$home_dir"

  output=$(
    HOME="$home_dir" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      REBUILD_CMD="nixos-rebuild"
      source "'"$home_dir/.local/lib/rebuild-common.sh"'"
      _clear_retired_codex_hook_artifacts
    ' 2>&1
  )

  assert_contains "$output" "Removed retired Codex hook artifacts."
  assert_contains "$output" "Removed retired user-level Codex hooks.compatibility.json"
  assert_contains "$output" "Could not parse $home_dir/.codex/hooks.json; leaving user-owned hook file unchanged."
  [[ ! -e "$repo_root/.codex/hooks.json" ]] || fail "expected repo-local hooks.json to be removed"
  [[ ! -e "$repo_root/.codex/hooks.compatibility.json" ]] || fail "expected repo-local hooks.compatibility.json to be removed"
  assert_malformed_user_codex_hooks_preserved "$home_dir"
}

test_clear_retired_codex_hook_artifacts_preserves_symlinked_user_hooks() {
  local sandbox home_dir repo_root output
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  mkdir -p "$repo_root/.codex"
  printf '{}\n' > "$repo_root/.codex/hooks.json"
  printf '{}\n' > "$repo_root/.codex/hooks.compatibility.json"
  write_symlinked_user_codex_hooks "$home_dir"

  output=$(
    HOME="$home_dir" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      REBUILD_CMD="nixos-rebuild"
      source "'"$home_dir/.local/lib/rebuild-common.sh"'"
      _clear_retired_codex_hook_artifacts
    ' 2>&1
  )

  assert_contains "$output" "Removed retired Codex hook artifacts."
  assert_contains "$output" "Removed retired user-level Codex hooks.compatibility.json"
  assert_contains "$output" "$home_dir/.codex/hooks.json is a symlink; leaving user-owned hook file unchanged"
  [[ ! -e "$repo_root/.codex/hooks.json" ]] || fail "expected repo-local hooks.json to be removed"
  [[ ! -e "$repo_root/.codex/hooks.compatibility.json" ]] || fail "expected repo-local hooks.compatibility.json to be removed"
  assert_symlinked_user_codex_hooks_preserved "$home_dir"
}

test_clear_retired_codex_hook_artifacts_removes_dangling_artifact_symlinks() {
  local sandbox home_dir repo_root output
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  mkdir -p "$repo_root/.codex" "$home_dir/.codex"
  rm -f "$repo_root/.codex/hooks.json" "$repo_root/.codex/hooks.compatibility.json" "$home_dir/.codex/hooks.compatibility.json"
  ln -s "$repo_root/.codex/missing-hooks.json" "$repo_root/.codex/hooks.json"
  ln -s "$repo_root/.codex/missing-hooks.compatibility.json" "$repo_root/.codex/hooks.compatibility.json"
  ln -s "$home_dir/.codex/missing-hooks.compatibility.json" "$home_dir/.codex/hooks.compatibility.json"

  output=$(
    HOME="$home_dir" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      REBUILD_CMD="nixos-rebuild"
      source "'"$home_dir/.local/lib/rebuild-common.sh"'"
      _clear_retired_codex_hook_artifacts
    ' 2>&1
  )

  assert_contains "$output" "Removed retired Codex hook artifacts."
  assert_contains "$output" "Removed retired user-level Codex hooks.compatibility.json"
  [[ ! -L "$repo_root/.codex/hooks.json" ]] || fail "expected dangling repo-local hooks.json symlink to be removed"
  [[ ! -L "$repo_root/.codex/hooks.compatibility.json" ]] || fail "expected dangling repo-local hooks.compatibility.json symlink to be removed"
  [[ ! -L "$home_dir/.codex/hooks.compatibility.json" ]] || fail "expected dangling user-level hooks.compatibility.json symlink to be removed"
}

test_darwin_nrs_offline_force_smoke() {
  local sandbox home_dir repo_root stub_dir output result_target current_target
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stub-bin"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  install_platform_nrs_entrypoint "$sandbox" darwin

  mkdir -p "$stub_dir" "$home_dir/.local/bin" "$home_dir/Library/LaunchAgents" "$sandbox/current-system"
  current_target="$sandbox/current-system"

  cat > "$stub_dir/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
"$@"
EOF
  cat > "$stub_dir/darwin-rebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  build)
    ln -sfn "${DARWIN_RESULT_TARGET:?}" ./result
    ;;
  switch)
    :
    ;;
  *)
    echo "unexpected darwin-rebuild subcommand: $1" >&2
    exit 1
    ;;
esac
EOF
  cat > "$stub_dir/nvd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "stub nvd diff"
EOF
  cat > "$stub_dir/launchctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  list)
    printf '%s\n' '-\t0\tcom.green.test-agent'
    exit 0
    ;;
  bootout) exit 0 ;;
esac
exit 0
EOF
  cat > "$stub_dir/open" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  cat > "$stub_dir/pgrep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 1
EOF
  cat > "$stub_dir/killall" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  local real_readlink
  real_readlink="$(command -v readlink)"
  cat > "$stub_dir/readlink" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "/run/current-system" ]]; then
  printf '%s\n' "\${DARWIN_CURRENT_SYSTEM:?}"
else
  "$real_readlink" "\$@"
fi
EOF
  cat > "$home_dir/.local/bin/nrs-relink" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "$stub_dir/sudo" "$stub_dir/darwin-rebuild" "$stub_dir/nvd" "$stub_dir/launchctl" "$stub_dir/open" "$stub_dir/pgrep" "$stub_dir/killall" "$stub_dir/readlink" "$home_dir/.local/bin/nrs-relink"

  result_target="$sandbox/darwin-result"
  mkdir -p "$result_target"
  mkdir -p "$repo_root/.codex"
  printf '{}\n' > "$repo_root/.codex/hooks.json"
  printf '{}\n' > "$repo_root/.codex/hooks.compatibility.json"
  write_mixed_user_codex_hooks "$home_dir"

  output=$(
    HOME="$home_dir" \
    PATH="$stub_dir:$FIXTURE_DIR/bin:$PATH" \
    DARWIN_RESULT_TARGET="$result_target" \
    DARWIN_CURRENT_SYSTEM="$current_target" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/nrs"'" --offline --force
    ' 2>&1
  )

  assert_contains "$output" "Applying changes (offline)"
  assert_contains "$output" "Done!"
  assert_contains "$output" "Removed retired user-level Codex hooks.compatibility.json"
  assert_contains "$output" "Pruned 1 stale Codex hook entry"
  [[ ! -e "$repo_root/.codex/hooks.json" ]] || fail "expected darwin nrs to remove retired hooks.json"
  [[ ! -e "$repo_root/.codex/hooks.compatibility.json" ]] || fail "expected darwin nrs to remove retired hooks.compatibility.json"
  assert_user_codex_hooks_pruned "$home_dir"
}

test_darwin_nrs_no_changes_releases_worktree_lock() {
  local sandbox home_dir repo_root worktree_root stub_dir output result_target current_target lock_file
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stub-bin"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  worktree_root="$repo_root/.claude/worktrees/feature_one"
  install_deployed_layout "$sandbox" "$repo_root"
  install_platform_nrs_entrypoint "$sandbox" darwin
  install_repo_local_only_codex_cleanup_helper "$home_dir"
  install_partial_deployed_codex_legacy_hooks_helper "$home_dir"
  install_repo_fallback_codex_legacy_hooks_helper "$worktree_root"

  mkdir -p "$stub_dir" "$home_dir/.local/bin" "$home_dir/Library/LaunchAgents"
  current_target="$sandbox/current-system"
  mkdir -p "$current_target"
  lock_file="$sandbox/nrs-state"
  rm -f "$lock_file"
  mkdir -p "$worktree_root/.codex"
  printf '{}\n' > "$worktree_root/.codex/hooks.json"
  printf '{}\n' > "$worktree_root/.codex/hooks.compatibility.json"
  write_mixed_user_codex_hooks "$home_dir"

  cat > "$stub_dir/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
"$@"
EOF
  cat > "$stub_dir/darwin-rebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  build)
    ln -sfn "${DARWIN_RESULT_TARGET:?}" ./result
    ;;
  switch)
    :
    ;;
  *)
    echo "unexpected darwin-rebuild subcommand: $1" >&2
    exit 1
    ;;
esac
EOF
  cat > "$stub_dir/nvd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "stub nvd diff"
EOF
  local real_readlink
  real_readlink="$(command -v readlink)"
  cat > "$stub_dir/readlink" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "/run/current-system" ]]; then
  printf '%s\n' "\${DARWIN_CURRENT_SYSTEM:?}"
else
  "$real_readlink" "\$@"
fi
EOF
  cat > "$home_dir/.local/bin/nrs-relink" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "$stub_dir/sudo" "$stub_dir/darwin-rebuild" "$stub_dir/nvd" "$stub_dir/readlink" "$home_dir/.local/bin/nrs-relink"

  result_target="$current_target"
  output=$(
    HOME="$home_dir" \
    PATH="$stub_dir:$FIXTURE_DIR/bin:$PATH" \
    DARWIN_RESULT_TARGET="$result_target" \
    DARWIN_CURRENT_SYSTEM="$current_target" \
    NRS_LOCK_FILE="$lock_file" \
    bash -c '
      set -euo pipefail
      cd "'"$worktree_root"'"
      "'"$home_dir/.local/bin/nrs"'" 
    ' 2>&1
  )

  assert_contains "$output" "Lock acquired"
  assert_contains "$output" "No changes to apply"
  assert_contains "$output" "Lock released"
  assert_contains "$output" "Removed retired user-level Codex hooks.compatibility.json"
  assert_contains "$output" "Pruned 1 stale Codex hook entry"
  [[ ! -e "$lock_file" ]] || fail "expected sandbox nrs lock file to be removed after no-change early return"
  [[ ! -e "$worktree_root/.codex/hooks.json" ]] || fail "expected no-change darwin nrs to remove retired hooks.json"
  [[ ! -e "$worktree_root/.codex/hooks.compatibility.json" ]] || fail "expected no-change darwin nrs to remove retired hooks.compatibility.json"
  assert_user_codex_hooks_pruned "$home_dir"
}

run_test "wt help uses deployed helper layout" test_wt_help_from_deployed_layout
run_test "rebuild-common exports public API" test_rebuild_common_exports_public_api
run_test "detect_worktree switches to active worktree" test_detect_worktree_uses_current_worktree_path
run_test "wt cd returns target path by name" test_wt_cd_by_name_returns_target_path
run_test "wt ls lists deployed worktrees" test_wt_ls_from_deployed_layout_lists_worktrees
run_test "shadow paths do not override managed helpers" test_shadow_paths_do_not_override_managed_helpers
run_test "wt symlink alias does not load adjacent helpers" test_wt_symlink_alias_does_not_load_adjacent_helpers
run_test "rebuild-common symlink alias does not load adjacent helpers" test_rebuild_common_symlink_alias_does_not_load_adjacent_helpers
run_test "wt create uses managed codex-sync path" test_wt_create_creates_worktree_without_shadow_codex_sync
run_test "wt recreate guard uses physical paths" test_wt_recreate_guard_uses_physical_paths
run_test "wt cleanup auto removes merged worktree" test_wt_cleanup_auto_removes_merged_worktree
run_test "wt cleanup auto skips dirty merged worktree" test_wt_cleanup_auto_skips_dirty_merged_worktree
run_test "wt cleanup auto skips unpushed merged worktree" test_wt_cleanup_auto_skips_unpushed_with_upstream
run_test "wt cleanup auto skips merged branch reuse" test_wt_cleanup_auto_skips_merged_branch_reuse
run_test "missing managed helpers fail closed" test_missing_managed_helpers_fail_closed
run_test "fixture git setup ignores host global hooks" test_fixture_git_is_hermetic_against_global_hooks
run_test "nixos nrs offline force smoke" test_nixos_nrs_offline_force_smoke
run_test "stale filter supports clean symlinked user hooks" test_user_hooks_stale_filter_supports_clean_symlink_target
run_test "stale filter detects symlinked stale user hooks" test_user_hooks_stale_filter_detects_symlink_target_stale_entries
run_test "stale filter ignores stale path mentions" test_user_hooks_stale_filter_ignores_stale_path_mentions
run_test "stale filter detects exact HOME hook path" test_user_hooks_stale_filter_detects_exact_home_path
run_test "retired hook cleanup preserves malformed user hooks" test_clear_retired_codex_hook_artifacts_preserves_malformed_user_hooks
run_test "retired hook cleanup preserves symlinked user hooks" test_clear_retired_codex_hook_artifacts_preserves_symlinked_user_hooks
run_test "retired hook cleanup removes dangling artifact symlinks" test_clear_retired_codex_hook_artifacts_removes_dangling_artifact_symlinks
run_test "darwin nrs offline force smoke" test_darwin_nrs_offline_force_smoke
run_test "darwin nrs no-change releases worktree lock" test_darwin_nrs_no_changes_releases_worktree_lock

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
else
  echo "==> codex-config fixtures: SKIPPED (tomlkit 미가용; 'nix shell .#pythonWithTomlkit --command bash tests/run-shell-script-tests.sh'로 전건 실행 권장; pre-push hook은 자동 wrap됨)" >&2
fi
