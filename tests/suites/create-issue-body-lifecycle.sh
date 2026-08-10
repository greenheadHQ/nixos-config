# tests/suites/create-issue-body-lifecycle.sh — create-issue 문서 실행 계약 fixture
# shellcheck shell=bash
# shellcheck disable=SC2154

_create_issue_file_mode() {
  local mode
  if mode="$(stat -c '%a' "$1" 2>/dev/null)"; then
    printf '%s\n' "$mode"
    return
  fi
  /usr/bin/stat -f '%Lp' "$1"
}

_create_issue_extract_step5a_recipe() {
  local skill_file="$1"

  awk '
    /^#### Step 5-A — 이슈 등록$/ {
      in_step = 1
      next
    }
    in_step && /^[[:space:]]*```bash[[:space:]]*$/ {
      in_fence = 1
      next
    }
    in_fence && /^[[:space:]]*```[[:space:]]*$/ {
      exit
    }
    in_fence {
      line = $0
      sub(/^   /, "", line)
      print line
    }
  ' "$skill_file"
}

_create_issue_write_recipe_fixture() {
  local skill_file="$1" recipe_file="$2"
  local extracted_file="$recipe_file.extracted"

  _create_issue_extract_step5a_recipe "$skill_file" > "$extracted_file"
  [[ -s "$extracted_file" ]] || fail "create-issue Step 5-A bash fence was not found"

  awk '
    $0 == "# <작성된 본문>을 $ISSUE_BODY에 기록 (파일 편집 도구)" {
      print "fixture_write_body \"$ISSUE_BODY\""
      replacements++
      next
    }
    { print }
    END {
      if (replacements != 1) {
        exit 42
      }
    }
  ' "$extracted_file" > "$recipe_file" \
    || fail "create-issue body writer placeholder must appear exactly once"
}

_create_issue_write_runner() {
  local runner_file="$1"

  cat > "$runner_file" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

fixture_mode() {
  local mode
  if mode="$(stat -c '%a' "$1" 2>/dev/null)"; then
    printf '%s\n' "$mode"
    return
  fi
  /usr/bin/stat -f '%Lp' "$1"
}

fixture_write_body() {
  local body_path="$1"
  local dir_mode

  [[ -n "${ISSUE_BODY_DIR:-}" ]] || {
    echo "fixture: ISSUE_BODY_DIR is not set" >&2
    return 90
  }
  [[ "$body_path" == "$ISSUE_BODY_DIR/body.md" ]] || {
    echo "fixture: unexpected body path: $body_path" >&2
    return 91
  }
  [[ -d "$ISSUE_BODY_DIR" ]] || {
    echo "fixture: body directory does not exist" >&2
    return 92
  }
  dir_mode="$(fixture_mode "$ISSUE_BODY_DIR")"
  [[ "$dir_mode" == "700" ]] || {
    echo "fixture: body directory mode is $dir_mode, expected 700" >&2
    return 93
  }
  if [[ -e "$body_path" || -L "$body_path" ]]; then
    echo "fixture: body target existed before the first edit" >&2
    return 94
  fi

  case "${WRITER_KIND:-regular}" in
    regular)
      cp "$EXPECTED_BODY_FILE" "$body_path"
      chmod 0644 "$body_path"
      ;;
    symlink)
      ln -s "$SYMLINK_TARGET" "$body_path"
      ;;
    *)
      echo "fixture: unknown writer kind: $WRITER_KIND" >&2
      return 95
      ;;
  esac

  printf '%s\n' "$body_path" > "$WRITER_TRACE"
}

. "$RECIPE_FILE"
EOF
  chmod +x "$runner_file"
}

_create_issue_write_fake_gh() {
  local gh_file="$1"

  cat > "$gh_file" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

[[ "$#" == "8" ]] || {
  echo "fake gh: unexpected argument count: $#" >&2
  exit 80
}
[[ "$1" == "issue" && "$2" == "create" ]] || {
  echo "fake gh: only issue create is allowed" >&2
  exit 81
}
[[ "$3" == "--title" && "$5" == "--label" && "$7" == "--body-file" ]] || {
  echo "fake gh: unexpected arguments" >&2
  exit 82
}

body_file="$8"
[[ -f "$body_file" && ! -L "$body_file" ]] || {
  echo "fake gh: body must be a regular non-symlink file" >&2
  exit 83
}

if body_mode="$(stat -c '%a' "$body_file" 2>/dev/null)"; then
  :
else
  body_mode="$(/usr/bin/stat -f '%Lp' "$body_file")"
fi
[[ "$body_mode" == "600" ]] || {
  echo "fake gh: body mode is $body_mode, expected 600" >&2
  exit 84
}
cmp -s "$EXPECTED_BODY_FILE" "$body_file" || {
  echo "fake gh: body bytes changed" >&2
  exit 85
}

printf '%s\n' "$body_file" >> "$GH_TRACE"
if [[ "${GH_FAIL:-0}" == "1" ]]; then
  exit 42
fi
printf '%s\n' 'https://github.com/example/repo/issues/999'
EOF
  chmod +x "$gh_file"
}

test_create_issue_documented_body_lifecycle_is_safe() {
  local sandbox skill_file recipe_file runner_file stub_bin expected_body
  local fixture_path writer_trace gh_trace output rc body_path body_dir symlink_target target_mode

  sandbox="$(new_sandbox)"
  skill_file="$REPO_ROOT/modules/shared/programs/claude/files/skills/create-issue/SKILL.md"
  recipe_file="$sandbox/step5a-recipe.sh"
  runner_file="$sandbox/run-recipe.sh"
  stub_bin="$sandbox/bin"
  expected_body="$sandbox/expected.md"
  writer_trace="$sandbox/writer.trace"
  gh_trace="$sandbox/gh.trace"

  mkdir -p "$stub_bin" "$sandbox/tmp"
  printf '%s\n' '# fixture issue body' 'private fixture payload' > "$expected_body"
  _create_issue_write_recipe_fixture "$skill_file" "$recipe_file"
  _create_issue_write_runner "$runner_file"
  _create_issue_write_fake_gh "$stub_bin/gh"
  fixture_path="$stub_bin:$PATH"

  output="$(
    TMPDIR="$sandbox/tmp" \
      PATH="$fixture_path" \
      RECIPE_FILE="$recipe_file" \
      EXPECTED_BODY_FILE="$expected_body" \
      WRITER_TRACE="$writer_trace" \
      GH_TRACE="$gh_trace" \
      "$BASH" "$runner_file" 2>&1
  )" || fail "documented create-issue success path failed: $output"

  assert_contains "$output" "ISSUE_URL=https://github.com/example/repo/issues/999"
  body_path="$(<"$writer_trace")"
  body_dir="$(dirname "$body_path")"
  [[ ! -e "$body_path" && ! -L "$body_path" ]] \
    || fail "successful issue creation left the body file behind"
  [[ ! -e "$body_dir" ]] \
    || fail "successful issue creation left the private body directory behind"
  assert_file_contains "$gh_trace" "$body_path"

  : > "$writer_trace"
  : > "$gh_trace"
  set +e
  output="$(
    TMPDIR="$sandbox/tmp" \
      PATH="$fixture_path" \
      RECIPE_FILE="$recipe_file" \
      EXPECTED_BODY_FILE="$expected_body" \
      WRITER_TRACE="$writer_trace" \
      GH_TRACE="$gh_trace" \
      GH_FAIL=1 \
      "$BASH" "$runner_file" 2>&1
  )"
  rc=$?
  set -e

  [[ "$rc" != "0" ]] || fail "documented create-issue failure path returned success"
  body_path="$(<"$writer_trace")"
  body_dir="$(dirname "$body_path")"
  [[ -f "$body_path" && ! -L "$body_path" ]] \
    || fail "failed issue creation did not preserve the body file"
  [[ -d "$body_dir" ]] \
    || fail "failed issue creation did not preserve the private body directory"
  cmp -s "$expected_body" "$body_path" \
    || fail "failed issue creation changed the preserved body bytes"
  assert_contains "$output" "ISSUE_BODY_PATH=$body_path"
  assert_file_contains "$gh_trace" "$body_path"

  : > "$writer_trace"
  : > "$gh_trace"
  symlink_target="$sandbox/symlink-target.md"
  cp "$expected_body" "$symlink_target"
  chmod 0644 "$symlink_target"
  set +e
  output="$(
    TMPDIR="$sandbox/tmp" \
      PATH="$fixture_path" \
      RECIPE_FILE="$recipe_file" \
      EXPECTED_BODY_FILE="$expected_body" \
      WRITER_TRACE="$writer_trace" \
      GH_TRACE="$gh_trace" \
      WRITER_KIND=symlink \
      SYMLINK_TARGET="$symlink_target" \
      "$BASH" "$runner_file" 2>&1
  )"
  rc=$?
  set -e

  [[ "$rc" != "0" ]] || fail "documented create-issue path accepted a symlink body"
  [[ ! -s "$gh_trace" ]] || fail "documented create-issue path called gh with a symlink body"
  target_mode="$(_create_issue_file_mode "$symlink_target")"
  [[ "$target_mode" == "644" ]] \
    || fail "symlink rejection changed the external target mode"
}
