# tests/suites/skill-version-stamps.sh — skill version stamp drift warning fixtures (#1078)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# shellcheck disable=SC2154,SC2164

# fixture repo 골격 + 스크립트 사본 + 세 대상 SKILL.md (스탬프 버전은 인자로 주입)
create_version_stamp_fixture_repo() {
  local repo_root="$1" codex_stamp="$2" claude_stamp="$3"

  mkdir -p \
    "$repo_root/scripts/ai" \
    "$repo_root/modules/shared/programs/claude/files/skills/using-codex-exec" \
    "$repo_root/modules/shared/programs/claude/files/skills/using-claude-p" \
    "$repo_root/.claude/skills/configuring-codex"
  cp "$REPO_ROOT/scripts/ai/warn-skill-version-stamps.sh" \
    "$repo_root/scripts/ai/warn-skill-version-stamps.sh"

  cat > "$repo_root/modules/shared/programs/claude/files/skills/using-codex-exec/SKILL.md" <<EOF
## 작성 기준

- 확인 날짜: 2026-07-10
- 확인 버전: codex-cli $codex_stamp
- 재검증: \`command codex --version && command codex exec --help\`
EOF
  cat > "$repo_root/modules/shared/programs/claude/files/skills/using-claude-p/SKILL.md" <<EOF
## 작성 기준

- 확인 날짜: 2026-07-10
- 확인 버전: Claude Code v$claude_stamp
- 재검증: \`claude --version && claude --help && claude -p --help\`
EOF
  # 버전 뒤 괄호 부가 설명이 붙는 형식 (실제 configuring-codex 스탬프와 동일 shape)
  cat > "$repo_root/.claude/skills/configuring-codex/SKILL.md" <<EOF
## 작성 기준

- 확인 날짜: 2026-07-11
- 확인 버전: codex-cli $codex_stamp (codex-pin.json/runtime 일치)
- 재검증: \`codex --version && codex --help\`
EOF
}

# PATH 통제용 디렉토리: warn 스크립트의 외부 명령 의존은 dirname뿐(나머지는 bash 내장)이라,
# dirname만 담은 디렉토리 하나로 PATH를 좁혀 CLI 존재/부재를 결정론적으로 재현한다.
create_version_stamp_path_dir() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  ln -s "$(command -v dirname)" "$bin_dir/dirname"
}

# stub CLI 설치. shebang은 /bin/sh — /usr/bin/env가 좁힌 PATH에서 bash를 못 찾는 문제를 피한다.
create_version_stamp_cli_stubs() {
  local bin_dir="$1" codex_ver="$2" claude_ver="$3"

  create_version_stamp_path_dir "$bin_dir"
  cat > "$bin_dir/codex" <<EOF
#!/bin/sh
echo "codex-cli $codex_ver"
EOF
  cat > "$bin_dir/claude" <<EOF
#!/bin/sh
echo "$claude_ver (Claude Code)"
EOF
  chmod +x "$bin_dir/codex" "$bin_dir/claude"
}

test_warn_skill_version_stamps_matching_stays_quiet() {
  local sandbox repo_root bin_dir output
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  bin_dir="$sandbox/bin"
  create_version_stamp_fixture_repo "$repo_root" "0.144.1" "2.1.206"
  create_version_stamp_cli_stubs "$bin_dir" "0.144.1" "2.1.206"

  output=$(cd "$repo_root" && PATH="$bin_dir" "$BASH" scripts/ai/warn-skill-version-stamps.sh 2>&1)
  [ -z "$output" ] || fail "expected matching stamps to stay quiet, got: $output"
}

test_warn_skill_version_stamps_detects_drift() {
  local sandbox repo_root bin_dir output
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  bin_dir="$sandbox/bin"
  create_version_stamp_fixture_repo "$repo_root" "0.144.1" "2.1.206"
  # codex만 상승, claude는 일치 — codex 대상 2건만 WARN 되어야 한다
  create_version_stamp_cli_stubs "$bin_dir" "0.145.0" "2.1.206"

  output=$(cd "$repo_root" && PATH="$bin_dir" "$BASH" scripts/ai/warn-skill-version-stamps.sh 2>&1) \
    || fail "expected warn-only exit 0 on drift, got exit $?: $output"
  assert_contains "$output" "[WARN] using-codex-exec: 문서 스탬프 0.144.1 vs 설치 0.145.0"
  assert_contains "$output" "재검증: command codex --version && command codex exec --help"
  assert_contains "$output" "[WARN] configuring-codex: 문서 스탬프 0.144.1 vs 설치 0.145.0"
  assert_not_contains "$output" "using-claude-p"
  assert_contains "$output" "스킬 버전 스탬프 경고 2건 (warn-only"
}

test_warn_skill_version_stamps_skips_when_cli_absent() {
  local sandbox repo_root bin_dir output
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  bin_dir="$sandbox/bin"
  create_version_stamp_fixture_repo "$repo_root" "0.144.1" "2.1.206"
  # CLI stub 미설치 — dirname만 있는 PATH 디렉토리로 CLI 부재 환경(CI 등)을 재현한다
  create_version_stamp_path_dir "$bin_dir"

  output=$(cd "$repo_root" && PATH="$bin_dir" "$BASH" scripts/ai/warn-skill-version-stamps.sh 2>&1)
  [ -z "$output" ] || fail "expected silent skip when CLIs are absent, got: $output"
}

test_warn_skill_version_stamps_warns_on_cli_exec_failure() {
  local sandbox repo_root bin_dir output
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  bin_dir="$sandbox/bin"
  create_version_stamp_fixture_repo "$repo_root" "0.144.1" "2.1.206"
  create_version_stamp_cli_stubs "$bin_dir" "0.144.1" "2.1.206"
  # codex는 설치되어 있으나 --version이 실패 — CLI 부재의 silent skip과 달리
  # 출력 계약 drift 신호이므로 WARN으로 드러나야 한다.
  cat > "$bin_dir/codex" <<'EOF'
#!/bin/sh
exit 1
EOF
  chmod +x "$bin_dir/codex"

  output=$(cd "$repo_root" && PATH="$bin_dir" "$BASH" scripts/ai/warn-skill-version-stamps.sh 2>&1) \
    || fail "expected warn-only exit 0 on exec failure, got exit $?: $output"
  assert_contains "$output" "codex --version 실행·버전 파싱 실패"
  assert_not_contains "$output" "using-claude-p"
}

test_warn_skill_version_stamps_warns_on_unparseable_stamp() {
  local sandbox repo_root bin_dir output
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  bin_dir="$sandbox/bin"
  create_version_stamp_fixture_repo "$repo_root" "0.144.1" "2.1.206"
  create_version_stamp_cli_stubs "$bin_dir" "0.144.1" "2.1.206"
  # 스탬프 형식이 바뀌어 추출 규칙과 어긋난 경우 — 조용히 통과하면 체크가 무력화되므로 WARN
  printf '## 작성 기준\n\n- 확인 버전: unknown-format\n' \
    > "$repo_root/modules/shared/programs/claude/files/skills/using-codex-exec/SKILL.md"

  output=$(cd "$repo_root" && PATH="$bin_dir" "$BASH" scripts/ai/warn-skill-version-stamps.sh 2>&1) \
    || fail "expected warn-only exit 0 on unparseable stamp, got exit $?: $output"
  assert_contains "$output" "[WARN] using-codex-exec: '확인 버전' 스탬프 추출 실패"
}
