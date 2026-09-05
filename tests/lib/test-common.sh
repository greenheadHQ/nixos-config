# tests/lib/test-common.sh — 공통 테스트 헬퍼 (sourced; aggregator가 env 세팅 후 첫 source)
# shellcheck shell=bash
# SC2154: REPO_ROOT/FIXTURE_DIR/TEST_TMP_FILE는 aggregator가 정의. SC2164: aggregator의
#   set -euo pipefail이 런타임 상속되어 cd 실패는 abort됨(sourced라 shellcheck가 미인지).
# shellcheck disable=SC2154,SC2164
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
new_sandbox() {
  local dir
  # macOS의 TMPDIR은 "/"로 끝나 그대로 이으면 "T//…"가 된다. 검증 대상 코드는 경로를
  # 정규화해 돌려주므로 sandbox 경로도 "//" 없이 만들어야 문자열 비교가 성립한다.
  local base="${TMPDIR:-/tmp}"
  base="${base%/}"
  dir=$(mktemp -d "${base}/shell-script-tests.XXXXXX")
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

assert_wt_wrapper_nix() {
  local nix_file="$1"
  grep -Fq '  home.file.".local/bin/wt" =' "$nix_file" \
    || fail "expected $nix_file to define home.file.\".local/bin/wt\""
  grep -Fq '        export WT_PYTHON="${pythonWithTomlkit}/bin/python3"' "$nix_file" \
    || fail "expected wt wrapper to export WT_PYTHON from pythonWithTomlkit"
  grep -Fq '        exec "${config.home.homeDirectory}/.local/bin/.wt-real" "$@"' "$nix_file" \
    || fail "expected wt wrapper to exec .wt-real"
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

install_fixture_git_global_ignore() {
  local home_dir="$1"
  local ignore_file="$home_dir/.config/git/ignore"
  local git_nix="$REPO_ROOT/modules/shared/programs/git/default.nix"

  grep -Fq '      ".agents/skills/wt-plugin--*"' "$git_nix" \
    || fail "expected global git ignore to include wt-managed plugin skill projections"
  mkdir -p "$(dirname "$ignore_file")"
  if ! grep -qxF '.agents/skills/wt-plugin--*' "$ignore_file" 2>/dev/null; then
    printf '%s\n' '.agents/skills/wt-plugin--*' >> "$ignore_file"
  fi
}
install_deployed_layout() {
  local sandbox="$1"
  local flake_path="${2:-$REPO_ROOT}"
  local home_dir="$sandbox/home"
  local generated_dir="$sandbox/generated"
  local shell_nix="$REPO_ROOT/modules/shared/programs/shell/default.nix"

  mkdir -p "$home_dir/.local/bin" "$home_dir/.local/lib" "$generated_dir"
  install_fixture_git_global_ignore "$home_dir"

  # shellcheck disable=SC2016  # Literal Nix source strings.
  register_copy_exec "$shell_nix" ".local/bin/.wt-real" \
    '${sharedScriptsDir}/wt.sh' "modules/shared/scripts/wt.sh"
  assert_wt_wrapper_nix "$shell_nix"
  cat > "$home_dir/.local/bin/wt" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export WT_PYTHON="$(command -v python3)"
exec "$home_dir/.local/bin/.wt-real" "\$@"
EOF
  chmod +x "$home_dir/.local/bin/wt"

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
# GNU `stat -c` / BSD `stat -f` 를 모두 지원하는 helper. "%a"/"%p" 3자리 octal을 반환.
_portable_file_mode() {
  # BSD fallback은 /usr/bin/stat 절대경로 — PATH 재해석으로 GNU stat이 -f를 오해석하는 것 방지
  # (repo CLAUDE.md "macOS BSD vs GNU 도구 라우팅" 규칙).
  stat -c '%a' "$1" 2>/dev/null || /usr/bin/stat -f '%Lp' "$1" 2>/dev/null
}
