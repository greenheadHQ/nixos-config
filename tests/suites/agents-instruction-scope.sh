# tests/suites/agents-instruction-scope.sh — 도메인 테스트 정의 (sourced; aggregator가 lib/test-common.sh 후 source)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의.
# shellcheck disable=SC2154

# user-scope 지시 파일의 런타임 경계를 박제한다.
# Claude Code용 `claude/files/CLAUDE.md`에는 Agent tool 기반 위임 결정표가 들어 있고,
# 이는 Codex 세션에 전달되면 자기 자신에게 위임하거나 존재하지 않는 서브에이전트를
# 찾게 만든다. 따라서 Codex용 `codex/files/AGENTS.md`는 별도 사본으로 유지하며,
# 양쪽에 모두 필요한 규칙만 담는다.

_ais_claude_md() {
  printf '%s' "$REPO_ROOT/modules/shared/programs/claude/files/CLAUDE.md"
}

_ais_codex_md() {
  printf '%s' "$REPO_ROOT/modules/shared/programs/codex/files/AGENTS.md"
}

_ais_codex_nix() {
  printf '%s' "$REPO_ROOT/modules/shared/programs/codex/default.nix"
}

# Codex 지시 파일에 Claude Code 런타임 전용 어휘가 섞이면 실패한다.
test_agents_scope_codex_has_no_claude_only_directives() {
  local f pattern
  f="$(_ais_codex_md)"
  [[ -f "$f" ]] || fail "codex AGENTS.md 없음: $f"
  # [WHY] 패턴을 -e로 명시한다. 지시 파일의 줄은 마크다운 목록이라 '-'로 시작하고,
  # 그대로 넘기면 grep이 옵션으로 해석해 invalid option으로 죽는다.
  for pattern in '조율자' '위임 결정표' 'scout' 'executor에 위임' 'Agent tool'; do
    if grep -qF -e "$pattern" "$f"; then
      fail "codex AGENTS.md에 Claude 전용 지시가 누출됨: '$pattern'"
    fi
  done
}

# Codex 지시 파일의 모든 내용 줄은 Claude 지시 파일에도 존재해야 한다.
# 공통 규칙을 한쪽만 고치는 drift를 잡는다 (Codex 파일은 공통 규칙의 부분집합).
test_agents_scope_common_rules_stay_in_sync() {
  local codex claude line
  codex="$(_ais_codex_md)"
  claude="$(_ais_claude_md)"
  [[ -f "$codex" ]] || fail "codex AGENTS.md 없음"
  [[ -f "$claude" ]] || fail "claude CLAUDE.md 없음"
  while IFS= read -r line; do
    [[ -z "${line// /}" ]] && continue
    if ! grep -qxF -e "$line" "$claude"; then
      fail "codex AGENTS.md의 줄이 claude CLAUDE.md에 없음 (동기화 깨짐): ${line:0:60}…"
    fi
  done < "$codex"
}

# Claude 전용 지시가 Claude 쪽에는 실제로 남아 있어야 한다.
# 위 두 테스트만 있으면 "양쪽 다 비우기"로도 통과하므로 반대 방향을 고정한다.
test_agents_scope_claude_keeps_delegation_table() {
  local f
  f="$(_ais_claude_md)"
  [[ -f "$f" ]] || fail "claude CLAUDE.md 없음"
  grep -qF -e '위임 결정표' "$f" || fail "claude CLAUDE.md에서 위임 결정표가 사라졌다"
}

# 배선이 공유 소스로 되돌아가면 실패한다.
test_agents_scope_codex_wiring_does_not_share_claude_md() {
  local nix
  nix="$(_ais_codex_nix)"
  [[ -f "$nix" ]] || fail "codex default.nix 없음"
  if grep -E '"\.codex/AGENTS\.md"' -A2 "$nix" | grep -qF 'claudeFilesPath}/CLAUDE.md'; then
    fail "codex AGENTS.md 배선이 claude CLAUDE.md 공유로 되돌아갔다"
  fi
  grep -E '"\.codex/AGENTS\.md"' -A2 "$nix" | grep -qF 'codex/files/AGENTS.md' \
    || fail "codex AGENTS.md 배선이 codex 전용 사본을 가리키지 않는다"
}
