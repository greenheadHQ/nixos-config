# tests/suites/fragile-hardcoding-guard.sh — 도메인 테스트 정의 (sourced; aggregator가 lib/test-common.sh 후 source)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# shellcheck disable=SC2154,SC2164

# fragile-hardcoding-guard.sh PreToolUse 가드에 JSON stdin을 흘려, "줄 수 하드코딩" 제외(allow)
# 정규식의 어순 무관 동작과 정탐 보존을 박제한다 (이슈 #918). 가드는 Write/Edit tool_input이고
# file_path가 SKILL.md 패턴일 때만 검사하며, jq 부재 시 no-op exit 0이다(devShell에 jq 가용).
# JSON stdin → stdout permissionDecision 검증 패턴은 tests/test-codex-hook-fixtures.sh 참고.
_fragile_guard_decision() {
  # $1 = SKILL.md content. 가드의 stdout(+stderr)을 반환한다(deny JSON 또는 빈 출력).
  local content="$1"
  printf '{"tool_name":"Write","tool_input":{"file_path":"repo/modules/x/claude/files/skills/demo/SKILL.md","content":"%s"}}' "$content" | \
    bash "$REPO_ROOT/modules/shared/programs/claude/files/hooks/fragile-hardcoding-guard.sh" 2>&1
}

test_fragile_hardcoding_guard_line_count_word_order_independent() {
  local out
  # 오탐 케이스: 제외 키워드("제한")가 "줄" 앞 — 어순 무관화로 통과해야 한다(deny 없음).
  out=$(_fragile_guard_decision "가이드는 제한 100줄 기준으로 작성한다")
  assert_not_contains "$out" '"deny"'
  # 대조군 1: 키워드가 "줄" 뒤(의미 동일) — 통과.
  out=$(_fragile_guard_decision "가이드는 100줄 제한 기준으로 작성한다")
  assert_not_contains "$out" '"deny"'
  # 대조군 2: 기존 어순(수치 뒤 키워드 "이내") — 통과.
  out=$(_fragile_guard_decision "본문은 100줄 이내로 작성한다")
  assert_not_contains "$out" '"deny"'
}

test_fragile_hardcoding_guard_line_count_true_positive_preserved() {
  local out
  # 정탐 보존: 제외 키워드가 전혀 없는 순수 "N줄" 하드코딩은 어순 무관화 이후에도 deny된다.
  out=$(_fragile_guard_decision "이 문서는 120줄로 구성된다")
  assert_contains "$out" '"permissionDecision": "deny"'
}
