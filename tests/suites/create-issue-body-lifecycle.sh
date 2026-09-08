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
    /^### Step 5-A — 이슈 등록$/ {
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
    /^ATTACH_ARGS=\(\)/ {
      print "ATTACH_ARGS=(); if [[ -n \"${ATTACH_FILE:-}\" ]]; then ATTACH_ARGS=(--attach \"$ATTACH_FILE\"); fi"
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
unset OWNER REPO ISSUE_REPO

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

if [[ "$*" == "repo view --json nameWithOwner -q .nameWithOwner" ]]; then
  [[ "${GH_REPO_FAIL:-0}" == "0" ]] || exit 40
  printf '%s\n' 'example/repo'
  exit 0
fi
expected_count=10
[[ -z "${ATTACH_FILE:-}" ]] || expected_count=12
[[ "$#" == "$expected_count" ]] || {
  echo "fake gh: unexpected argument count: $#" >&2
  exit 80
}
[[ "$1" == "issue" && "$2" == "create" ]] || {
  echo "fake gh: only issue create is allowed" >&2
  exit 81
}
[[ "$3" == "-R" && "$4" == "example/repo" && "$5" == "--title" && "$7" == "--label" && "$9" == "--body-file" ]] || {
  echo "fake gh: unexpected arguments" >&2
  exit 82
}

if [[ -n "${ATTACH_FILE:-}" ]]; then
  [[ "${11}" == "--attach" && "${12}" == "$ATTACH_FILE" ]] || exit 86
fi
body_file="${10}"
# 유효성 검사에서 거부돼도 호출 사실을 남긴다.
printf '%s\n' "$body_file" >> "$GH_TRACE"
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

if [[ "${GH_FAIL:-0}" == "1" ]]; then
  exit 42
fi
if [[ "${GH_PARTIAL:-0}" == "1" ]]; then
  printf '%s\n' 'https://github.com/example/repo/issues/999'
  exit 1
fi
printf '%s\n' 'https://github.com/example/repo/issues/999'
EOF
  chmod +x "$gh_file"
}

test_create_issue_documented_body_lifecycle_is_safe() {
  local sandbox skill_file recipe_file runner_file stub_bin expected_body
  local fixture_path writer_trace gh_trace output rc body_path body_dir symlink_target target_mode
  local retry_file retry_output retry_tmp_dir

  sandbox="$(new_sandbox)"
  skill_file="$REPO_ROOT/modules/shared/programs/claude/files/skills/create-issue/references/publishing.md"
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
  retry_tmp_dir="$sandbox/tmp with 'single' \"double\" "'$(printf unexpected-substitution)'
  mkdir -p "$retry_tmp_dir"
  set +e
  output="$(
    TMPDIR="$retry_tmp_dir" \
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
  assert_file_contains "$gh_trace" "$body_path"

  # 실패 안내만 새 셸로 복사해도 같은 파일을 복원하고 재검사하되 자동으로 다시 게시하지 않는다.
  # fixture가 경로를 재주입하지 않고 실제 출력의 할당문과 명령을 실행한다.
  retry_file="$sandbox/retry.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
    'unset ISSUE_BODY ISSUE_BODY_PATH' > "$retry_file"
  printf '%s\n' "$output" | awk '
    /^ISSUE_BODY=/ { print; assignments++ }
    /^  \[ -f / { sub(/^  /, ""); print; commands++ }
    END { if (assignments != 1 || commands != 1) exit 42 }
  ' >> "$retry_file" || fail "failure output must contain one body assignment and one body validation command"
  printf '%s\n' 'printf "%s\n" "$ISSUE_BODY"' >> "$retry_file"
  # 에디터가 본문을 0644로 재생성한 경우에도 게시 시점에는 0600이어야 한다.
  chmod 0644 "$body_path"
  retry_output="$(
    PATH="$fixture_path" \
      EXPECTED_BODY_FILE="$expected_body" \
      GH_TRACE="$gh_trace" \
      GH_FAIL=0 \
      "$BASH" "$retry_file" 2>&1
  )" || fail "documented create-issue retry failed in a new shell: $retry_output"
  [[ "$retry_output" == "$body_path" ]] || fail "new shell did not restore the exact preserved path"
  [[ "$(_create_issue_file_mode "$body_path")" == "600" ]] || fail "body recheck did not restore private permissions"
  assert_line_count "$gh_trace" "$body_path" 1

  # 같은 재시도 안내가 symlink 본문은 chmod/gh 호출 전에 차단해야 한다.
  symlink_target="$sandbox/symlink-target.md"
  cp "$expected_body" "$symlink_target"
  chmod 0644 "$symlink_target"
  rm "$body_path"
  ln -s "$symlink_target" "$body_path"
  set +e
  retry_output="$(
    PATH="$fixture_path" \
      EXPECTED_BODY_FILE="$expected_body" \
      GH_TRACE="$gh_trace" \
      GH_FAIL=0 \
      "$BASH" "$retry_file" 2>&1
  )"
  rc=$?
  set -e
  [[ "$rc" != "0" ]] || fail "documented create-issue retry accepted a symlink body"
  assert_line_count "$gh_trace" "$body_path" 1
  target_mode="$(_create_issue_file_mode "$symlink_target")"
  [[ "$target_mode" == "644" ]] \
    || fail "retry symlink rejection changed the external target mode"
  cmp -s "$expected_body" "$symlink_target" \
    || fail "retry symlink rejection changed the external target bytes"

  # A partial attachment failure can still publish the issue. Preserve its URL,
  # body and one creation attempt; a space-containing media path stays one arg.
  : > "$gh_trace"
  set +e
  output="$(
    TMPDIR="$sandbox/tmp" PATH="$fixture_path" RECIPE_FILE="$recipe_file" \
      EXPECTED_BODY_FILE="$expected_body" WRITER_TRACE="$writer_trace" \
      GH_TRACE="$gh_trace" GH_PARTIAL=1 ATTACH_FILE="$sandbox/capture one.png" \
      "$BASH" "$runner_file" 2>&1
  )"
  rc=$?
  set -e
  [[ "$rc" != "0" ]] || fail "partial attachment failure was reported as success"
  assert_contains "$output" "ISSUE_URL=https://github.com/example/repo/issues/999"
  body_path="$(<"$writer_trace")"
  [[ -f "$body_path" ]] || fail "partial failure lost the recovery body"
  [[ "$(wc -l < "$gh_trace" | tr -d '[:space:]')" == "1" ]] \
    || fail "partial attachment failure retried issue creation"

  : > "$gh_trace"
  set +e
  output="$(
    TMPDIR="$sandbox/tmp" PATH="$fixture_path" RECIPE_FILE="$recipe_file" \
      EXPECTED_BODY_FILE="$expected_body" WRITER_TRACE="$writer_trace" \
      GH_TRACE="$gh_trace" GH_REPO_FAIL=1 \
      "$BASH" "$runner_file" 2>&1
  )"
  rc=$?
  set -e
  [[ "$rc" != "0" ]] || fail "repository lookup failure was ignored"
  [[ ! -s "$gh_trace" ]] || fail "issue creation ran without a confirmed repository"

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
