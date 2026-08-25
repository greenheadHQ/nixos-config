#!/usr/bin/env bash
# verify-ai-compat.sh — Claude Code + Codex CLI 호환 구조 검증
# 사용: `./scripts/ai/verify-ai-compat.sh` 또는 devShell에서 `verify-ai-compat`
# tomlkit 미가용 환경에서는 자동으로 `nix shell .#pythonWithTomlkit --command bash "$0"`로
# 재실행된다 (아래 tomlkit self-wrap 섹션 참조).
#
# 스킬 제거/개명 퇴역 체크리스트:
# - 소스 디렉토리 삭제/이동: modules/shared/programs/claude/files/skills/ 또는 .claude/skills/
# - modules/shared/programs/claude/default.nix 배선 항목 제거
# - modules/shared/programs/codex/default.nix exposedCodexSkills/intentionallyNotExposed 항목 제거
# - 이 스크립트의 EXPECTED_* 목록에서 제거. 완전 퇴역(이 이름으로 재설치하지 않음)이면
#   RETIRED_SHARED_SKILLS에 등록해 홈 잔재를 감시한다. 단 user-scope 재설치(예: `npx skills add -g`)를
#   허용하는 스킬은 홈 잔재 검사(존재=FAIL)와 충돌하므로 등록하지 않고, 미등록 예외 근거를 남긴다
# - 전 스킬 코퍼스에서 스킬명 cross-reference grep (NOT-for, 산문 참조)
# - 전 스킬 evals/queries.json에서 혼동쌍 잔존 grep
# - nrs로 홈 디렉터리 심링크 정리 반영
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_SKILLS_DIR="$REPO_ROOT/.claude/skills"
TARGET_SKILLS_DIR="$REPO_ROOT/.agents/skills"
SHARED_SKILLS_DIR="$REPO_ROOT/modules/shared/programs/claude/files/skills"
CODEX_GLOBAL_SKILLS_DIR="$HOME/.codex/skills"
CLAUDE_GLOBAL_SKILLS_DIR="$HOME/.claude/skills"
# shellcheck disable=SC2034  # sourced lib(scripts/ai/lib/host-state-checks.sh)가 소비하는 전역
REPO_ROOT_REAL="$(readlink -f "$REPO_ROOT" 2>/dev/null || printf '%s' "$REPO_ROOT")"
GIT_COMMON_DIR="$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
MAIN_REPO_ROOT=""
if [ -n "$GIT_COMMON_DIR" ]; then
  # shellcheck disable=SC2034  # sourced lib(scripts/ai/lib/host-state-checks.sh)가 소비하는 전역
  MAIN_REPO_ROOT="$(cd "$GIT_COMMON_DIR/.." 2>/dev/null && pwd -P || true)"
fi

# shellcheck source=/dev/null
. "$REPO_ROOT/modules/shared/scripts/lib/rebuild/codex-legacy-hooks.sh"

# Nix SoT(default.nix)와 독립된 감사 오라클.
# 두 리스트는 서로 교집합이 없어야 하며, shared 디렉토리의 모든 스킬이 둘 중 하나에 속해야 한다.
EXPECTED_EXPOSED=(
  analyzing-da-sessions
  create-issue
  create-pr
  finding-unknowns
  finish-pr
  issuing-codex-pairing-code
  review-pr-feedback
  run-da
  using-gh-attach
  write-handoff
)
SHARED_EXPOSURE_EXCLUDE=(
  set-icons
  using-claude-p
  using-codex-exec
)
# Split retired names so the public stale-reference scan scope can stay
# zero-match while this verifier still checks deployed residue.
RETIRED_SHARED_SKILLS=(
  "syncing-codex""-harness"
  "codex-fan""-out"
)
RETIRED_EXECUTABLES=(
  ".local/bin/codex""-sync"
)

# SKILL.md tool-neutral lint has its own exclusion policy. It currently matches
# the shared exposure exclusions because these skills are legacy adapters,
# but future exposure-only exclusions must be added deliberately.
SKILL_NEUTRAL_LINT_EXCLUDE=(
  set-icons
  using-claude-p
  using-codex-exec
)

errors=0
warnings=0

pass() { echo "  [OK] $1"; }
fail() { echo "  [FAIL] $1" >&2; errors=$((errors + 1)); }
warn() { echo "  [WARN] $1" >&2; warnings=$((warnings + 1)); }

require_contract_text() {
  local relpath="$1"
  local needle="$2"
  local desc="$3"
  local path="$REPO_ROOT/$relpath"

  if [ ! -f "$path" ]; then
    fail "$desc 파일 없음: $relpath"
    return
  fi

  if grep -Fq -- "$needle" "$path"; then
    pass "$desc"
  else
    fail "$desc 누락: $relpath"
  fi
}

in_list() {
  local needle="$1"; shift
  local item
  for item in "$@"; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

# 현존 스킬 문서/evals만 검사한다. verify-ai-compat.sh 자기 자신과 이 검사 코드의
# RETIRED_SHARED_SKILLS 리터럴은 의도적으로 스캔 범위 밖이다.
list_skill_reference_files() {
  local root="$1"
  [ -d "$root" ] || return 0

  find "$root" \
    \( -path '*/SKILL.md' -o -path '*/references/*.md' -o -path '*/evals/queries.json' \) \
    -type f -print
}

verify_retired_shared_skill_references() {
  local candidate_list match_file skill_name candidate match_count match grep_rc

  candidate_list="$(mktemp "${TMPDIR:-/tmp}/verify-ai-retired-skill-ref-files.XXXXXX")"
  match_file="$(mktemp "${TMPDIR:-/tmp}/verify-ai-retired-skill-refs.XXXXXX")"
  list_skill_reference_files "$SOURCE_SKILLS_DIR" >"$candidate_list"
  list_skill_reference_files "$SHARED_SKILLS_DIR" >>"$candidate_list"
  sort -u -o "$candidate_list" "$candidate_list"

  for skill_name in "${RETIRED_SHARED_SKILLS[@]}"; do
    : >"$match_file"
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      if grep -nFH -- "$skill_name" "$candidate" >>"$match_file"; then
        :
      else
        grep_rc=$?
        if [ "$grep_rc" -gt 1 ]; then
          fail "retired shared 스킬 참조 검사 grep 실패: ${candidate#"$REPO_ROOT"/} (rc=$grep_rc)"
        fi
      fi
    done <"$candidate_list"

    if [ -s "$match_file" ]; then
      match_count="$(wc -l <"$match_file" | tr -d '[:space:]')"
      # 문서에는 "과거 X 스킬은 제거" 같은 이력 서술도 남을 수 있어,
      # retired 배포 잔재와 달리 우선 warn-only로 두고 사람이 의도를 판정한다.
      warn "retired shared 스킬 문서/evals 참조 잔존: $skill_name (${match_count}건)"
      while IFS= read -r match; do
        match="${match#"$REPO_ROOT"/}"
        echo "    $match" >&2
      done <"$match_file"
    else
      pass "retired shared 스킬 문서/evals 참조 없음: $skill_name"
    fi
  done

  rm -f "$candidate_list" "$match_file"
}

# shellcheck disable=SC1091  # source file은 repo 내부 고정 경로
. "$REPO_ROOT/scripts/ai/lib/host-state-checks.sh"


RUN_GUARDRAIL_FIXTURES=0
case "${1:-}" in
  "")
    ;;
  --run-fixture-tests)
    RUN_GUARDRAIL_FIXTURES=1
    shift
    ;;
  -h|--help)
    cat <<'EOF'
Usage: ./scripts/ai/verify-ai-compat.sh [--run-fixture-tests]

  --run-fixture-tests  Run only deterministic SKILL.md tool-neutral lint fixtures.
EOF
    exit 0
    ;;
  *)
    fail "unknown argument: $1"
    exit 2
    ;;
esac
if [ "$#" -gt 0 ]; then
  fail "unexpected extra arguments: $*"
  exit 2
fi

# ─── tomlkit bootstrap ───
# sync-codex-config.py의 `check` subcommand가 tomlkit에 의존한다. 정책과 재실행 guard는
# scripts/ai/lib/tomlkit-bootstrap.sh 단일 소스에서 관리한다.
# Python 사전 체크보다 먼저 실행한다. host python3가 없거나 3.11 미만이어도
# nix shell .#pythonWithTomlkit으로 self-wrap된 뒤 그 안의 python3로 다시 사전 체크를 수행한다.
# 그래야 파일 상단의 "tomlkit 미가용 시 자동 재실행" 계약이 실제로 성립한다.
_VERIFY_AI_COMPAT_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [ "$RUN_GUARDRAIL_FIXTURES" -eq 0 ]; then
  # shellcheck disable=SC1091  # source file은 repo 내부 고정 경로
  . "$_VERIFY_AI_COMPAT_REPO_ROOT/scripts/ai/lib/tomlkit-bootstrap.sh"
  tomlkit_bootstrap_require "$_VERIFY_AI_COMPAT_REPO_ROOT" "${BASH_SOURCE[0]}" "$@"
fi

# ─── Python 사전 체크 ───
# bootstrap 이후에도 ambient python3가 어떤 이유로 여전히 3.11 미만이면 명시적 실패.
# 일반적으로 이 분기에 도달하지 않는다 (nix shell이 Python 3.13+를 보장).
if ! command -v python3 >/dev/null 2>&1; then
  echo "  [FAIL] python3 not found in PATH (bootstrap 이후에도 부재)" >&2
  exit 1
fi
if [ "$RUN_GUARDRAIL_FIXTURES" -eq 1 ]; then
  if ! python3 - <<'PY' 2>/dev/null
import sys
if sys.version_info < (3, 10):
    raise SystemExit(1)
PY
  then
    echo "  [FAIL] python3 >= 3.10 is required for fixture mode" >&2
    exit 1
  fi
elif ! python3 - <<'PY' 2>/dev/null
import sys, tomllib  # tomllib requires 3.11+
if sys.version_info < (3, 11):
    raise SystemExit(1)
PY
then
  echo "  [FAIL] python3 >= 3.11 with tomllib is required (bootstrap 이후에도 버전 부족)" >&2
  exit 1
fi

# ─── TOML helper ───
# 통합 helper. 모든 TOML inspection을 단일 `_toml_inspect --what=<mode>`로 수행한다.
# 이전의 _toml_parse/_toml_get_scalar/_toml_has_table/_file_mode는 모두 여기로 통합했다.
# 현재 호출 지점이 있는 모드만 남겨두며, 새 모드가 필요하면 호출처와 함께 추가한다.
#
# Mode별 반환 계약 (soft-fail 계약 유지 — 한 체크 실패가 이후 섹션을 끊지 않도록):
#   --what=scalar <file> <dotted.path>
#       stdout: scalar 값(str/int/float/bool). 없거나 파싱 실패면 empty.
#       exit  : 항상 0 (command substitution 안전)
#   --what=parse  <file>
#       stdout: 없음.
#       exit  : 유효한 TOML이면 0, 아니면 1 (if/then 분기용)
#   --what=mode   <file>
#       stdout: 8진수 mode 문자열 (예: "600"). 실패 시 "?".
#       exit  : 항상 0
_toml_inspect() {
  # $1 = --what=<mode>, $2 = file, $3 = optional dotted path (scalar/table 전용)
  local what="${1#--what=}"
  shift
  python3 - "$what" "$@" <<'PY'
import os, stat, sys, tomllib

what = sys.argv[1]
args = sys.argv[2:]


def inspect_parse(path):
    try:
        with open(path, "rb") as f:
            tomllib.load(f)
    except Exception:
        sys.exit(1)
    sys.exit(0)


def inspect_scalar(path, dotted):
    # soft-fail: 파일/파싱/경로 문제는 empty stdout + exit 0.
    try:
        with open(path, "rb") as f:
            data = tomllib.load(f)
    except Exception:
        sys.exit(0)
    cur = data
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            sys.exit(0)
        cur = cur[part]
    if isinstance(cur, (str, int, float, bool)):
        print(cur)
    sys.exit(0)


def inspect_mode(path):
    try:
        print(f"{stat.S_IMODE(os.stat(path).st_mode):o}")
    except Exception:
        print("?")
    sys.exit(0)


dispatch = {
    "parse":  lambda: inspect_parse(args[0]),
    "scalar": lambda: inspect_scalar(args[0], args[1]),
    "mode":   lambda: inspect_mode(args[0]),
}
handler = dispatch.get(what)
if handler is None:
    print(f"_toml_inspect: unknown --what={what}", file=sys.stderr)
    sys.exit(2)
handler()
PY
}

# ─── SKILL.md 도구-중립성 lint helper ───
# shellcheck disable=SC1091  # source file은 repo 내부 고정 경로
. "$REPO_ROOT/scripts/ai/lib/skill-neutral-lint.sh"

if [ "$RUN_GUARDRAIL_FIXTURES" -eq 1 ]; then
  run_skill_neutral_fixture_tests
fi

echo "=== Codex 실행 정책 확인 ==="

CODEX_CONFIG="$HOME/.codex/config.toml"
if [ -f "$CODEX_CONFIG" ]; then
  _ap="$(_toml_inspect --what=scalar "$CODEX_CONFIG" approval_policy)"
  if [ "$_ap" = "never" ]; then
    pass "approval_policy = \"never\""
  else
    fail "approval_policy = \"never\" 미설정 (actual: \"$_ap\")"
  fi

  _sm="$(_toml_inspect --what=scalar "$CODEX_CONFIG" sandbox_mode)"
  if [ "$_sm" = "danger-full-access" ]; then
    pass "sandbox_mode = \"danger-full-access\""
  else
    fail "sandbox_mode = \"danger-full-access\" 미설정 (actual: \"$_sm\")"
  fi

  if grep -q 'nixos-config' "$CODEX_CONFIG"; then
    pass "프로젝트 trust 항목 존재 (선택)"
  else
    pass "프로젝트 trust 항목 없음 (선택)"
  fi
else
  fail "$HOME/.codex/config.toml 없음"
fi

echo ""
echo "=== Codex 바이너리 PATH resolve 확인 ==="

standalone_root="$HOME/.codex/packages/standalone"

# 회귀 가드 (#890): codex는 declarative nix overlay(nix profile/store)로 설치된다. mise npm
# backend에서 이관된 뒤로, 잔존 mise codex shim이 PATH 앞에서 codex(nix profile)를 shadow하면 안 된다 —
# config 미등록 dangling shim 호출은 mise version resolve(fork 폭주, os error 35)를 재유발한다.
# 의존처(codex-exec-supervised, shell의 codex/codex-apps 런처)가 전부
# command -v codex에 의존하므로 이 셸 컨텍스트에서 codex가 nix 경로로 resolve되는지 검증한다.
# 주의: mise shim은 그 자체가 nix mise 바이너리로의 symlink라 readlink -f 결과가 nix store가 되어
# shim을 못 거른다. 따라서 command -v가 돌려준 첫 PATH 매치 경로 자체로 mise/node 잔재를 판정하고,
# 그 외에는 readlink -f 타깃이 -codex- store path인지로 codex overlay를 확인한다.
# command -v는 바이너리를 실행하지 않고 PATH lookup만 하므로 fork 폭주를 유발하지 않는다.
if codex_path="$(command -v codex 2>/dev/null)" && [ -n "$codex_path" ]; then
  case "$codex_path" in
    */mise/shims/*)
      fail "codex가 mise shim으로 resolve됨 ($codex_path) — 잔존 shim이 codex(nix profile)를 shadow (#890). '~/.local/share/mise/shims/codex' 제거 후 nrs"
      ;;
    */installs/node/*)
      fail "codex가 mise node 글로벌로 resolve됨 ($codex_path) — 수동 npm 글로벌이 codex(nix profile)를 shadow (cleanupManualNodeCodex 확인)"
      ;;
    *)
      codex_resolved="$(readlink -f "$codex_path" 2>/dev/null || echo "$codex_path")"
      case "$codex_resolved" in
        "$standalone_root"/*)
          fail "codex가 Codex App standalone으로 resolve됨 ($codex_path → $codex_resolved) — remote-control payload가 일반 CLI PATH를 shadow함"
          ;;
        /nix/store/*-codex-*)
          pass "codex PATH resolve 정상 (nix overlay): $codex_path"
          ;;
        *)
          warn "codex가 nix overlay가 아닌 경로로 resolve됨 ($codex_path → $codex_resolved) — brew/수동 설치 잔재 가능"
          ;;
      esac
      ;;
  esac
else
  warn "codex가 PATH에서 resolve되지 않음 — codex(nix overlay) 미활성(nrs 전) 또는 비대화형 노출 회귀 가능"
fi

standalone_codex="$HOME/.codex/packages/standalone/current/bin/codex"
if [ -e "$standalone_codex" ] || [ -L "$standalone_codex" ]; then
  standalone_resolved="$(readlink -f "$standalone_codex" 2>/dev/null || echo "$standalone_codex")"
  case "$standalone_resolved" in
    "$standalone_root"/releases/*/bin/codex)
      pass "Codex App remote-control standalone 경로 정상: $standalone_codex → $standalone_resolved"
      ;;
    *)
      fail "Codex App remote-control standalone이 관리 경로 밖을 가리킴: $standalone_codex → $standalone_resolved"
      ;;
  esac
fi

legacy_local_codex="$HOME/.local/bin/codex"
if [ -L "$legacy_local_codex" ]; then
  legacy_local_resolved="$(readlink -f "$legacy_local_codex" 2>/dev/null || echo "$legacy_local_codex")"
  case "$legacy_local_resolved" in
    "$standalone_root"/*)
      fail "\$HOME/.local/bin/codex가 Codex App standalone을 PATH shadow함: $legacy_local_codex → $legacy_local_resolved"
      ;;
  esac
fi

echo ""
echo "=== AGENTS.md 심링크 확인 ==="

if [ -L "$REPO_ROOT/AGENTS.md" ]; then
  target="$(readlink "$REPO_ROOT/AGENTS.md")"
  if [ "$target" = "CLAUDE.md" ]; then
    pass "AGENTS.md → CLAUDE.md"
  else
    fail "AGENTS.md → '$target' (expected: CLAUDE.md)"
  fi
else
  fail "AGENTS.md 심링크 없음"
fi

echo ""
echo "=== AGENTS.override.md 확인 ==="

if [ -f "$REPO_ROOT/AGENTS.override.md" ]; then
  pass "AGENTS.override.md 존재"
else
  fail "AGENTS.override.md 없음 (Codex 전용 보충 규칙 누락)"
fi

echo ""
echo "=== Codex native fan-out routing contract ==="

require_contract_text \
  "modules/shared/programs/claude/files/skills/run-da/references/hardening-contract.md" \
  "## Skill-internal fan-out authorization" \
  "hardening contract skill-internal fan-out authorization anchor"

require_contract_text \
  "modules/shared/programs/claude/files/skills/run-da/references/hardening-contract.md" \
  'does not authorize `codex-exec-supervised` fallback' \
  "hardening contract fallback non-authorization anchor"

require_contract_text \
  "modules/shared/programs/claude/files/skills/run-da/references/runtime-mapping.md" \
  "hardening-contract.md#skill-internal-fan-out-authorization" \
  "runtime mapping pointer to authorization contract"

require_contract_text \
  "modules/shared/programs/claude/files/skills/run-da/modes/audit.md" \
  '$run-da audit' \
  "run-da audit invocation anchor"

require_contract_text \
  "modules/shared/programs/claude/files/skills/run-da/modes/audit.md" \
  "auditor bundle 범위" \
  "run-da audit auditor bundle authorization scope"

require_contract_text \
  "modules/shared/programs/claude/files/skills/run-da/modes/audit.md" \
  "explicit delegation" \
  "run-da audit explicit delegation anchor"

require_contract_text \
  "modules/shared/programs/claude/files/skills/run-da/modes/audit.md" \
  "hardening-contract.md#skill-internal-fan-out-authorization" \
  "run-da audit hardening contract pointer"

_run_da_protocol="$REPO_ROOT/modules/shared/programs/claude/files/skills/run-da/references/protocol.md"
# require_contract_text는 -Fq 부분 일치라 "### R10"도 통과하므로 전체 줄 일치로 검증한다
for _run_da_heading in '### R1' '### R2'; do
  if grep -Fxq -- "$_run_da_heading" "$_run_da_protocol"; then
    pass "run-da PR comment example ${_run_da_heading#\#\#\# } heading"
  else
    fail "run-da PR comment example ${_run_da_heading#\#\#\# } heading 누락: ${_run_da_protocol#"$REPO_ROOT"/}"
  fi
done
if grep -Eiq '^### round [0-9]+' "$_run_da_protocol"; then
  fail "run-da PR comment example pinning round counter 재도입: ${_run_da_protocol#"$REPO_ROOT"/}"
else
  pass "run-da PR comment example avoids pinning round counters"
fi

require_contract_text \
  "AGENTS.override.md" \
  '$run-da' \
  "AGENTS.override mentions run-da"

require_contract_text \
  "AGENTS.override.md" \
  "explicit delegation" \
  "AGENTS.override explicit delegation anchor"

require_contract_text \
  "AGENTS.override.md" \
  '`codex-exec-supervised` fallback' \
  "AGENTS.override fallback anchor"

require_contract_text \
  "AGENTS.override.md" \
  "별도 사용자 승인" \
  "AGENTS.override separate approval anchor"

echo ""
echo "=== Codex CLI-default native capability probe ==="
# #1098: run-da native fan-out 계약의 CLI-default surface를 실측 판정한다.
# `codex debug prompt-input` stdout을 jq로 즉시 파이프해 developer 텍스트만 메모리
# 변수로 유지한다 — raw prompt는 디스크에 저장하지 않고 stdout/로그에도 출력하지
# 않으며, 최종 출력에는 정제된 tool 이름과 slot 숫자만 노출한다.
# 오탐/스푸핑 방지: tool·slot anchor를 developer 메시지 전체 합본이 아니라 "단일
# developer 메시지" 단위로 찾고, 두 anchor를 모두 포함하는 메시지가 정확히 하나일
# 때만 그 메시지(collaboration block)를 채택한다 — project-local AGENTS 산문 등
# 다른 메시지의 유사 문형이 tool/slot 판정에 섞이지 않게 한다. tool 존재 판정은
# 그 block의 고정 열거 문형("Call `a`, `b`, ... only as direct tool calls")에서만,
# slot은 root 포함이 명시된 전체 문형("There are N ... including you")에서 두 숫자가
# 일치할 때만 인정한다. anchor 미식별(0개/복수)이면 추측하지 않고 unknown으로 fail.
# 판별 축: lifecycle(explicit close 유무)과 batch-limit(slot 광고)을 분리 평가해
# public 2-profile(current/unknown)로 도출한다 (#1098 target shape; legacy는 실사용
# 0건으로 제거 — #1257. explicit close가 광고되는 과거 lifecycle 표면은 지원 종료
# 표면이므로 unknown(fail-safe)으로 강등한다).
# cancellation(중단 도구)은 profile 판별과 독립인 별도 capability로 보고만 한다
# (runtime-mapping.md: 중단은 광고된 도구가 있을 때만, 없으면 conservative wait).
# 이 판정은 surface_scope=cli-default 전용이며, active Desktop/다른 세션 표면의
# 증명이 아니다 (각 세션은 자기 표면으로 재판별 — runtime-mapping.md capability profile).
if command -v codex >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  # pipefail 하에서 codex/jq 실패가 assignment exit로 보존된다 (`|| true` 금지 —
  # 부분 출력이 성공으로 둔갑하는 것을 막는다). jq는 두 anchor를 모두 포함하는
  # developer 메시지가 정확히 1개일 때만 그 텍스트를 반환하고, 아니면 빈 문자열.
  if _cap_block="$(command codex debug prompt-input 'runtime capability probe' 2>/dev/null \
    | jq -r '[.[] | select(.role == "developer") | ([.content[]?.text // empty] | join("\n")) | select(test("only as direct tool calls") and test("available concurrency slots"))] | if length == 1 then .[0] else "" end')"; then
    if [ -z "$_cap_block" ]; then
      fail "capability probe: collaboration block 식별 실패 (두 anchor를 모두 포함한 developer 메시지가 0개 또는 복수) — surface_scope=cli-default profile=unknown, native 표면을 확인할 수 없어 codex exec fallback 또는 serial(동시 1) fail-safe만 가능"
    else
      # tool 열거 anchor 문장에서만 backtick 토큰을 추출한다.
      _cap_call_line="$(printf '%s' "$_cap_block" | grep -Eo 'Call [^.]*only as direct tool calls' | head -1 || true)"
      _cap_tools=""
      if [ -n "$_cap_call_line" ]; then
        _cap_tools="$(printf '%s' "$_cap_call_line" | grep -Eo '`[a-z_]+`' | tr -d '`' | paste -sd, - || true)"
      fi
      # slot: 같은 block에서 root 포함 전체 문형만 인정, 두 숫자 일치를 요구한다.
      # 상태 구분 — ok(N>=2) / no-child(N=1: 확인된 native fan-out 불가) / 빈 값(미확정).
      _cap_slot_line="$(printf '%s' "$_cap_block" | grep -Eo 'There are [0-9]+ available concurrency slots, meaning that up to [0-9]+ agents can be active at once, including you' | head -1 || true)"
      _cap_slots=""
      _cap_slot_state="unknown"
      if [ -n "$_cap_slot_line" ]; then
        _cap_slot_total="$(printf '%s' "$_cap_slot_line" | grep -Eo '[0-9]+' | sed -n 1p || true)"
        _cap_slot_active="$(printf '%s' "$_cap_slot_line" | grep -Eo '[0-9]+' | sed -n 2p || true)"
        if [ -n "$_cap_slot_total" ] && [ "$_cap_slot_total" = "$_cap_slot_active" ]; then
          if [ "$_cap_slot_total" -ge 2 ]; then
            _cap_slots="$_cap_slot_total"
            _cap_slot_state="ok"
          else
            _cap_slot_state="no-child"
          fi
        fi
      fi
      # lifecycle 축: spawn+wait 존재와 explicit close 유무만으로 판별한다.
      _cap_lifecycle="unavailable"
      case ",$_cap_tools," in
        *,spawn_agent,*)
          case ",$_cap_tools," in
            *,wait_agent,*)
              case ",$_cap_tools," in
                *,close_agent,*) _cap_lifecycle="explicit-close" ;;
                *) _cap_lifecycle="no-explicit-close" ;;
              esac
              ;;
          esac
          ;;
      esac
      # cancellation 축 (진단 보고 전용 — profile 판별에 미사용).
      _cap_interrupt="no"
      case ",$_cap_tools," in
        *,interrupt_agent,*) _cap_interrupt="yes" ;;
      esac
      # 도출: lifecycle 미확정·slot 미확정이면 unknown. explicit close가 광고되는
      # 표면은 지원 종료된 과거 lifecycle이므로 current로 오인하지 않고 unknown으로
      # 강등한다 (legacy profile 제거 — #1257).
      if [ "$_cap_lifecycle" = "unavailable" ] || [ "$_cap_slot_state" = "unknown" ] \
        || [ "$_cap_lifecycle" = "explicit-close" ]; then
        _cap_profile="unknown"
      else
        _cap_profile="current"
      fi
      if [ "$_cap_slot_state" = "no-child" ]; then
        fail "capability probe: surface_scope=cli-default profile=$_cap_profile lifecycle=$_cap_lifecycle interrupt=$_cap_interrupt slots=$_cap_slot_total — total slot이 root뿐(child 0)이라 native fan-out 불가, codex exec fallback을 사용"
      elif [ "$_cap_profile" = "unknown" ]; then
        if [ "$_cap_lifecycle" = "unavailable" ]; then
          # spawn/wait 자체가 없으면 native 실행이 아예 불가하다 — serial조차 안내하지 않는다.
          fail "capability probe: surface_scope=cli-default profile=unknown lifecycle=unavailable interrupt=$_cap_interrupt tools=[${_cap_tools:-none}] — native 도구 부재로 native fan-out 자체 불가, codex exec fallback만 가능"
        elif [ "$_cap_lifecycle" = "explicit-close" ]; then
          fail "capability probe: surface_scope=cli-default profile=unknown lifecycle=explicit-close interrupt=$_cap_interrupt tools=[$_cap_tools] — explicit close_agent가 광고되는 지원 종료 lifecycle 표면 (#1257에서 legacy profile 제거), run-da native fan-out은 serial(동시 1) fail-safe로만 동작 가능"
        else
          fail "capability probe: surface_scope=cli-default profile=unknown lifecycle=$_cap_lifecycle interrupt=$_cap_interrupt tools=[$_cap_tools] slots=unknown — slot 미확정, run-da native fan-out은 serial(동시 1) fail-safe로만 동작 가능"
        fi
      else
        pass "capability probe: surface_scope=cli-default profile=$_cap_profile lifecycle=$_cap_lifecycle interrupt=$_cap_interrupt tools=[$_cap_tools] slots=$_cap_slots"
      fi
    fi
  else
    fail "capability probe: codex debug prompt-input 또는 jq 파이프라인 실패 (surface_scope=cli-default 판정 불가)"
  fi
else
  fail "capability probe: codex 또는 jq 없음 (CLI-default surface 판정 불가)"
fi

echo ""
echo "=== 프로젝트 스킬 투영 확인 (디렉토리 심링크) ==="

if [ ! -d "$TARGET_SKILLS_DIR" ]; then
  fail ".agents/skills/ 디렉토리 없음"
else
  src_count=0
  dst_count=0

  for skill_dir in "$SOURCE_SKILLS_DIR"/*/; do
    [ -d "$skill_dir" ] || continue
    [ -f "$skill_dir/SKILL.md" ] || continue
    skill_name="$(basename "$skill_dir")"
    src_count=$((src_count + 1))

    projected_entry="$TARGET_SKILLS_DIR/$skill_name"
    expected_target="../../.claude/skills/$skill_name"

    # 디렉토리 심링크 여부 확인
    if [ ! -L "$projected_entry" ]; then
      if [ -d "$projected_entry" ]; then
        fail "레거시 실디렉토리: .agents/skills/$skill_name (심링크 전환 필요)"
      else
        fail "투영 누락: .agents/skills/$skill_name"
      fi
      continue
    fi

    # 심링크 대상 경로 확인
    actual_target="$(readlink "$projected_entry")"
    if [ "$actual_target" != "$expected_target" ]; then
      fail "심링크 대상 불일치: $skill_name ($actual_target != $expected_target)"
      continue
    fi

    # 대상 존재 확인 (깨진 심링크 = warn, Nix 생성 스킬 허용)
    if [ ! -e "$projected_entry" ]; then
      warn "깨진 심링크: .agents/skills/$skill_name (소스 미존재, Nix 생성 스킬일 수 있음)"
      continue
    fi

    # SKILL.md 접근 가능 확인
    if [ -f "$projected_entry/SKILL.md" ]; then
      pass "디렉토리 심링크 정상: $skill_name"
    else
      fail "SKILL.md 접근 불가: $skill_name"
    fi
  done

  # 고아 심링크 탐지 (깨진 심링크도 포함)
  for entry in "$TARGET_SKILLS_DIR"/*; do
    [ -L "$entry" ] || [ -d "$entry" ] || continue
    skill_name="$(basename "$entry")"
    dst_count=$((dst_count + 1))

    if [ -d "$SOURCE_SKILLS_DIR/$skill_name" ]; then
      continue
    fi

    if [ -L "$entry" ]; then
      target="$(readlink "$entry")"
      if [[ "$target" = /* ]] && [ -f "$entry/SKILL.md" ]; then
        pass "플러그인 스킬 심링크 정상: $skill_name"
        continue
      fi
    fi

    fail "고아 투영: .agents/skills/$skill_name (원본 없음)"
  done

  echo ""
  echo "  소스 스킬: ${src_count}개, 투영 스킬: ${dst_count}개"
fi

echo ""
echo "=== 글로벌 설정 확인 ==="

# ~/.codex/config.toml 관리 상태
# activation의 syncCodexConfig가 repo-managed 키와 사용자 소유 섹션을 merge한 regular file로
# 유지한다. PASS 기준: (a) regular file, (b) mode 0600, (c) TOML 파싱 성공,
#                     (d) template-managed key 존재 (model/approval_policy/sandbox_mode).
# mode 불일치는 fail로 승격, legacy symlink 감지 시 nrs --force 안내.
_codex_cfg="$HOME/.codex/config.toml"
if [ ! -e "$_codex_cfg" ]; then
  fail "$_codex_cfg 없음"
elif [ -L "$_codex_cfg" ]; then
  fail "$_codex_cfg 심링크 — syncCodexConfig 미적용 (NO_CHANGES 경로 회피 위해 \`nrs --force\` 실행 필요)"
elif [ ! -f "$_codex_cfg" ]; then
  fail "$_codex_cfg regular file 아님"
else
  _mode="$(_toml_inspect --what=mode "$_codex_cfg")"
  if [ "$_mode" = "600" ]; then
    pass "$_codex_cfg regular file, mode=0600"
  else
    fail "$_codex_cfg mode=$_mode (기대: 0600) — 권한 제한 실패"
  fi
  if ! _toml_inspect --what=parse "$_codex_cfg"; then
    fail "$_codex_cfg TOML 파싱 실패"
  fi
fi

# ~/.codex/AGENTS.md
if [ -L "$HOME/.codex/AGENTS.md" ]; then
  pass "$HOME/.codex/AGENTS.md 심링크"
elif [ -f "$HOME/.codex/AGENTS.md" ]; then
  warn "$HOME/.codex/AGENTS.md 일반 파일 (심링크 아님)"
else
  warn "$HOME/.codex/AGENTS.md 없음"
fi

# ─── template ↔ live drift 검증 ───
# sync-codex-config.py의 `check` 서브커맨드에게 drift 계산을 위임한다. writer와
# 동일한 `_walk_template_leaves` iterator를 쓰므로 ownership policy drift가 구조적으로
# 차단된다. 플랫폼별 하드코딩(예: 특정 [mcp_servers.*] 항목) 없이,
# 해당 플랫폼의 template 파일에 선언된 leaf만 자동으로 검증된다.
echo ""
echo "=== template ↔ live drift 검증 ==="

# Nix store에 복사된 template seed가 아니라 현재 flake 워킹트리의 template을 검증 기준으로 쓴다.
if [ "$(uname -s)" = "Darwin" ]; then
  _TEMPLATE="$REPO_ROOT/modules/shared/programs/codex/files/config.darwin.toml"
else
  _TEMPLATE="$REPO_ROOT/modules/shared/programs/codex/files/config.toml"
fi
_CHECK_SCRIPT="$REPO_ROOT/modules/shared/programs/codex/files/sync-codex-config.py"

if [ ! -f "$_TEMPLATE" ]; then
  fail "template 파일 없음: $_TEMPLATE"
elif [ ! -f "$_CHECK_SCRIPT" ]; then
  fail "sync-codex-config.py 없음: $_CHECK_SCRIPT"
else
  # rc 흡수 패턴: EXIT_DRIFT(1)는 데이터 있는 정상 경로이므로 `if ...; then rc=0; else rc=$?; fi`로
  # 받아 set -euo pipefail 하에서도 verifier가 조기 종료되지 않는다. EXIT_ERROR(2)만 섹션 종료.
  _check_stdout=""
  _check_stderr=""
  _check_rc=0
  _check_err_file="$(mktemp "${TMPDIR:-/tmp}/verify-ai-compat-check-err.XXXXXX")"
  if _check_stdout="$(python3 "$_CHECK_SCRIPT" check "$_TEMPLATE" "$CODEX_CONFIG" 2>"$_check_err_file")"; then
    _check_rc=0
  else
    _check_rc=$?
  fi
  _check_stderr="$(cat "$_check_err_file")"
  rm -f "$_check_err_file"

  case "$_check_rc" in
    0|1)
      # check.py JSON 소비는 scripts/ai/lib/render-check-report.py 단일 helper에 위임한다.
      # helper가 `OK_LINE/FAIL_LINE/INFO_LINE <message>` 형식의 directive를 stdout에 쓰고,
      # verifier는 그 라인을 case 분기로 pass/fail/info에 매핑만 한다.
      # subshell pipe 대신 process substitution을 써서 fail()의 errors 증가가 부모 shell로 반영되도록 한다.
      while IFS= read -r _line; do
        case "$_line" in
          "OK_LINE "*)   pass "${_line#OK_LINE }" ;;
          "FAIL_LINE "*) fail "${_line#FAIL_LINE }" ;;
          "INFO_LINE "*) echo "  → ${_line#INFO_LINE }" >&2 ;;
          *)             fail "render-check-report.py 알 수 없는 directive: $_line" ;;
        esac
      done < <(printf '%s' "$_check_stdout" | python3 "$REPO_ROOT/scripts/ai/lib/render-check-report.py")
      ;;
    2)
      # EXIT_ERROR는 template read/parse, target read/parse 모두를 포함한 hard error 공용 신호다.
      # 원인을 제자리에서 단정하지 말고 subprocess stderr를 그대로 노출한다.
      fail "check.py EXIT_ERROR: ${_check_stderr:-(no stderr)}"
      ;;
    *)
      fail "check.py 비정상 종료 (rc=$_check_rc): $_check_stderr"
      ;;
  esac
fi

echo ""
echo "=== Shared 글로벌 스킬 노출 정책 확인 ==="

if [ ! -d "$SHARED_SKILLS_DIR" ]; then
  fail "shared skills 디렉토리 없음: $SHARED_SKILLS_DIR"
else
  shared_count=0
  for skill_dir in "$SHARED_SKILLS_DIR"/*/; do
    [ -d "$skill_dir" ] || continue
    [ -f "$skill_dir/SKILL.md" ] || continue
    skill_name="$(basename "$skill_dir")"
    shared_count=$((shared_count + 1))

    exposed_path="$CODEX_GLOBAL_SKILLS_DIR/$skill_name"

    if in_list "$skill_name" "${EXPECTED_EXPOSED[@]}"; then
      if [ ! -L "$exposed_path" ]; then
        fail "노출 누락: ~/.codex/skills/$skill_name (심링크 없음)"
        continue
      fi
      # Canonical target 검증: readlink -f 결과가 shared source에 도달해야 함
      resolved="$(readlink -f "$exposed_path" 2>/dev/null || true)"
      expected_real="$(readlink -f "$skill_dir" 2>/dev/null || true)"
      expected_suffix="modules/shared/programs/claude/files/skills/$skill_name"
      if ! resolved_target_matches_repo_suffix "$resolved" "$expected_real" "$expected_suffix"; then
        fail "노출 대상 불일치: $skill_name (actual=$resolved expected=$expected_real expected_suffix=*/$expected_suffix)"
        continue
      fi
      pass "shared 노출 정상: $skill_name"
    elif in_list "$skill_name" "${SHARED_EXPOSURE_EXCLUDE[@]}"; then
      # broken symlink도 노출 상태로 간주 (-e는 깨진 심링크에 false; -L || -e로 둘 다 검출)
      if [ -L "$exposed_path" ] || [ -e "$exposed_path" ]; then
        fail "의도적 비노출이 노출됨: $skill_name"
      else
        pass "의도적 비노출 확인: $skill_name"
      fi
    else
      fail "미분류 shared 스킬: $skill_name (EXPECTED_EXPOSED 또는 SHARED_EXPOSURE_EXCLUDE 중 하나에 등록 필요)"
    fi
  done

  echo ""
  echo "  shared 스킬: ${shared_count}개, 노출 기대값: ${#EXPECTED_EXPOSED[@]}개, 비노출 기대값: ${#SHARED_EXPOSURE_EXCLUDE[@]}개"
fi

for skill_name in "${RETIRED_SHARED_SKILLS[@]}"; do
  for retired_root in "$CODEX_GLOBAL_SKILLS_DIR" "$CLAUDE_GLOBAL_SKILLS_DIR"; do
    retired_path="$retired_root/$skill_name"
    retired_label="${retired_path/#$HOME/\$HOME}"
    if [ -L "$retired_path" ] || [ -e "$retired_path" ]; then
      fail "retired shared 스킬 잔재 발견: $retired_label"
    else
      pass "retired shared 스킬 잔재 없음: $retired_label"
    fi
  done
done
for retired_executable in "${RETIRED_EXECUTABLES[@]}"; do
  retired_path="$HOME/$retired_executable"
  retired_label="${retired_path/#$HOME/\$HOME}"
  if [ -L "$retired_path" ] || [ -e "$retired_path" ]; then
    fail "retired executable 잔재 발견: $retired_label"
  else
    pass "retired executable 잔재 없음: $retired_label"
  fi
done

echo ""
echo "=== Retired 스킬 문서/evals 잔존 참조 확인 ==="

verify_retired_shared_skill_references

echo ""
echo "=== SKILL.md 도구-중립성 lint ==="

_skill_lint_exclude_args=()
for _skill_lint_exclude in "${SKILL_NEUTRAL_LINT_EXCLUDE[@]}"; do
  _skill_lint_exclude_args+=(--exclude "$_skill_lint_exclude")
done
_run_skill_neutral_lint_checked \
  --mode live \
  --repo-root "$REPO_ROOT" \
  --root "$SOURCE_SKILLS_DIR" \
  --root "$SHARED_SKILLS_DIR" \
  "${_skill_lint_exclude_args[@]}"

echo ""
echo "=== Codex helper 스크립트 확인 ==="

# Codex 프로비저닝된 helper가 shared source를 정확히 가리키는지 검증 (#486 F4/F8)
verify_codex_helper() {
  local helper="$1"
  local helper_path="$HOME/.codex/scripts/$helper"
  local helper_source="$REPO_ROOT/modules/shared/programs/claude/files/scripts/$helper"
  if [ ! -L "$helper_path" ]; then
    fail "$helper_path 심링크 없음"
    return
  fi
  local resolved expected
  resolved="$(readlink -f "$helper_path" 2>/dev/null || true)"
  expected="$(readlink -f "$helper_source" 2>/dev/null || true)"
  local expected_suffix="modules/shared/programs/claude/files/scripts/$helper"
  if ! resolved_target_matches_repo_suffix "$resolved" "$expected" "$expected_suffix"; then
    fail "$helper_path 대상 불일치: actual=$resolved expected=$expected expected_suffix=*/$expected_suffix"
  else
    pass "Codex helper 정상: $helper"
  fi
}

verify_codex_helper "fleiss-kappa.py"

# Claude helper도 양쪽 scope에 동일 source가 프로비저닝되는지 확인 (selective consistency harness)
verify_claude_helper() {
  local helper="$1"
  local helper_path="$HOME/.claude/scripts/$helper"
  local helper_source="$REPO_ROOT/modules/shared/programs/claude/files/scripts/$helper"
  if [ ! -L "$helper_path" ]; then
    fail "$helper_path 심링크 없음"
    return
  fi
  local resolved expected
  resolved="$(readlink -f "$helper_path" 2>/dev/null || true)"
  expected="$(readlink -f "$helper_source" 2>/dev/null || true)"
  local expected_suffix="modules/shared/programs/claude/files/scripts/$helper"
  if ! resolved_target_matches_repo_suffix "$resolved" "$expected" "$expected_suffix"; then
    fail "$helper_path 대상 불일치: actual=$resolved expected=$expected expected_suffix=*/$expected_suffix"
  else
    pass "Claude helper 정상: $helper"
  fi
}

verify_claude_helper "fleiss-kappa.py"

echo ""
echo "=== Hooks 산출물 확인 ==="

# stale guard: <repo>/.codex/hooks.json 또는 <repo>/.codex/hooks.compatibility.json은
# 폐기된 패턴이라 잔재 시 fail. 단 user-level ~/.codex/hooks.json은 공식 hook source라
# 존재 자체가 아니라 알려진 legacy entry만 검사한다.
if [ -e "$REPO_ROOT/.codex/hooks.json" ] || [ -L "$REPO_ROOT/.codex/hooks.json" ] || \
   [ -e "$REPO_ROOT/.codex/hooks.compatibility.json" ] || [ -L "$REPO_ROOT/.codex/hooks.compatibility.json" ]; then
  fail "stale Codex hook artifacts present (.codex/hooks*.json)"
else
  pass "repo-local Codex hook artifacts 없음"
fi

_user_hooks_json="$HOME/.codex/hooks.json"
_user_hooks_report="$HOME/.codex/hooks.compatibility.json"

if [ -e "$_user_hooks_report" ] || [ -L "$_user_hooks_report" ]; then
  fail "stale user-level Codex hook artifact present ($_user_hooks_report) — run nrs to remove retired hooks.compatibility.json"
else
  pass "user-level Codex hooks.compatibility.json 없음"
fi

if [ -L "$_user_hooks_json" ] && [ ! -e "$_user_hooks_json" ]; then
  fail "$_user_hooks_json dangling symlink — user-level hook file must be repaired manually"
elif [ -f "$_user_hooks_json" ]; then
  if ! command -v jq >/dev/null 2>&1; then
    fail "jq 없음 — $_user_hooks_json stale entry 검사 불가"
  else
    _user_stale_hook_count=""
    if ! _user_stale_hook_count="$(jq -r "$(codex_legacy_user_hook_count_jq_filter)" "$_user_hooks_json")"; then
      fail "$_user_hooks_json JSON 파싱 실패 — user-level hook 파일을 수동 점검하세요"
    elif [ "$_user_stale_hook_count" -gt 0 ] 2>/dev/null; then
      if [ -L "$_user_hooks_json" ]; then
        fail "stale user-level Codex hook entries present ($_user_hooks_json count=$_user_stale_hook_count) — symlinked hook files are preserved by nrs; remove known Claude-era entries manually"
      else
        fail "stale user-level Codex hook entries present ($_user_hooks_json count=$_user_stale_hook_count) — run nrs to prune known Claude-era entries"
      fi
    else
      pass "user-level Codex hooks.json stale legacy entry 없음"
    fi
  fi
else
  pass "user-level Codex hooks.json 없음"
fi

echo ""
echo "=== Codex active hooks 검사 ==="

# Codex 0.124+ stable hook host-state 검사:
#   1) ~/.codex/config.toml의 [[hooks.UserPromptSubmit]]에 expected managed command가 포함되어 있는지.
#      sync-codex-config.py는 같은 event의 사용자 추가 entry를 보존하지 않으므로 사용자 hook 추가는
#      template 미선언 event로 등록하는 것이 보존된다. 본 검사는 managed entry 존재만 확인한다.
#   2) ~/.codex/config.toml의 [[hooks.Stop]]는 정확히 single managed dispatcher entry — Codex가
#      same-event multiple command를 concurrent 실행하므로 ordering 보장을 dispatcher에 위임한다.
#   3) ~/.codex/config.toml의 [[hooks.PostToolUse]]에 expected pinning-alert managed command가 포함되어 있는지.
#      issue #603에서 PostToolUse도 template-owned event로 전환되었다 (warn-only pinning alert).
#   4) expected command shim이 위임하는 Codex hook artifact 6개 + shared lib 2개 실재
#   5) tests/test-codex-hook-fixtures.sh deterministic 모드 통과 (live fixture 미실행)
# fail() 한 건이라도 발생하면 errors++ → exit 1 (FAIL gate).

_active_hooks_runner="$REPO_ROOT/tests/test-codex-hook-fixtures.sh"
# Hook contract expectation oracle: tests/lib/codex-hook-expectations.sh가 단일 정의 위치.
# shellcheck source=../../tests/lib/codex-hook-expectations.sh
. "$REPO_ROOT/tests/lib/codex-hook-expectations.sh"

if [ ! -f "$CODEX_CONFIG" ]; then
  fail "$CODEX_CONFIG 없음 — active hooks 검사 불가"
elif ! _toml_inspect --what=parse "$CODEX_CONFIG"; then
  # tomllib hard-exit 대신 soft-fail로 wrap. 다른 검사 섹션과 동일 accumulate 패턴 유지
  # (errors++ → 최종 summary에서 한꺼번에 보고).
  fail "$CODEX_CONFIG TOML 파싱 실패 — active hooks 구조 검사 skip"
else
  # tomllib로 hooks 구조 파싱 (bootstrap에서 python3 ≥ 3.11 보장).
  # parse는 위에서 이미 성공 확인했으므로 여기서 traceback이 나오면 race(파일 교체) 외 케이스는 없다.
  # UserPromptSubmit은 expected managed command가 포함되었는지만 검증 (사용자 추가 entry 허용).
  # Stop은 정확히 single managed dispatcher entry 강제 (concurrent 회피 contract).
  _hooks_dump=""
  if ! _hooks_dump="$(python3 - "$CODEX_CONFIG" "$EXPECTED_USER_PROMPT_COMMAND" "$EXPECTED_STOP_DISPATCHER_COMMAND" "$EXPECTED_PRE_TOOL_USE_PINNING_GUARD_COMMAND" "$EXPECTED_POST_TOOL_USE_PINNING_COMMAND" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    data = tomllib.load(f)
expected_ups = sys.argv[2]
expected_stop = sys.argv[3]
expected_pre = sys.argv[4]
expected_post = sys.argv[5]
hooks = data.get("hooks", {})
ups = hooks.get("UserPromptSubmit", []) or []
stop = hooks.get("Stop", []) or []
pre = hooks.get("PreToolUse", []) or []
post = hooks.get("PostToolUse", []) or []

ups_managed = any(
    h.get("command") == expected_ups
    for entry in ups
    for h in (entry.get("hooks", []) or [])
)
print(f"UPS_TOTAL_COUNT {len(ups)}")
print(f"UPS_HAS_MANAGED {'1' if ups_managed else '0'}")

print(f"STOP_COUNT {len(stop)}")
if len(stop) == 1:
    sub = stop[0].get("hooks", []) or []
    print(f"STOP_INNER_COUNT {len(sub)}")
    if sub:
        print(f"STOP_COMMAND {sub[0].get('command', '')}")

pre_managed = any(
    h.get("command") == expected_pre
    for entry in pre
    for h in (entry.get("hooks", []) or [])
)
print(f"PRE_TOTAL_COUNT {len(pre)}")
print(f"PRE_HAS_MANAGED {'1' if pre_managed else '0'}")

post_managed = any(
    h.get("command") == expected_post
    for entry in post
    for h in (entry.get("hooks", []) or [])
)
print(f"POST_TOTAL_COUNT {len(post)}")
print(f"POST_HAS_MANAGED {'1' if post_managed else '0'}")
PY
  )"; then
    fail "$CODEX_CONFIG hooks 구조 파싱 실패 (race 또는 invariant 위반)"
  else
    _ups_total_count="$(printf '%s\n' "$_hooks_dump" | awk '$1=="UPS_TOTAL_COUNT"{print $2}')"
    _ups_has_managed="$(printf '%s\n' "$_hooks_dump" | awk '$1=="UPS_HAS_MANAGED"{print $2}')"
    _stop_count="$(printf '%s\n' "$_hooks_dump" | awk '$1=="STOP_COUNT"{print $2}')"
    _stop_inner_count="$(printf '%s\n' "$_hooks_dump" | awk '$1=="STOP_INNER_COUNT"{print $2}')"
    _stop_command="$(printf '%s\n' "$_hooks_dump" | sed -n 's/^STOP_COMMAND //p')"
    _pre_total_count="$(printf '%s\n' "$_hooks_dump" | awk '$1=="PRE_TOTAL_COUNT"{print $2}')"
    _pre_has_managed="$(printf '%s\n' "$_hooks_dump" | awk '$1=="PRE_HAS_MANAGED"{print $2}')"
    _post_total_count="$(printf '%s\n' "$_hooks_dump" | awk '$1=="POST_TOTAL_COUNT"{print $2}')"
    _post_has_managed="$(printf '%s\n' "$_hooks_dump" | awk '$1=="POST_HAS_MANAGED"{print $2}')"

    if [ "${_ups_total_count:-0}" -ge 1 ] 2>/dev/null; then
      pass "[[hooks.UserPromptSubmit]] entry 존재 (count=$_ups_total_count)"
    else
      fail "[[hooks.UserPromptSubmit]] entry 부재 (count=${_ups_total_count:-?})"
    fi

    if [ "$_ups_has_managed" = "1" ]; then
      pass "UserPromptSubmit에 expected managed command 포함: $EXPECTED_USER_PROMPT_COMMAND"
    else
      fail "UserPromptSubmit에 expected managed command 없음 (expected='$EXPECTED_USER_PROMPT_COMMAND')"
    fi

    # Stop은 dispatcher 단일 entry contract — concurrent 실행 회피.
    # 사용자 추가 hook은 template 미선언 event(예: SessionStart)에 등록할 때만
    # sync-codex-config.py가 보존한다. Stop dispatcher 경유 sub-script 추가는 _stop-dispatcher.sh가
    # tracked 파일이라 user-config로 지원되지 않는다 (config.toml 주석 참조).
    if [ "${_stop_count:-0}" = "1" ] && [ "${_stop_inner_count:-0}" = "1" ]; then
      pass "[[hooks.Stop]] single managed dispatcher entry (concurrent 회피)"
    else
      fail "[[hooks.Stop]]은 정확히 single dispatcher entry여야 함 (outer=${_stop_count:-?} inner=${_stop_inner_count:-?})"
    fi

    if [ "$_stop_command" = "$EXPECTED_STOP_DISPATCHER_COMMAND" ]; then
      pass "Stop dispatcher command = $EXPECTED_STOP_DISPATCHER_COMMAND"
    else
      fail "Stop dispatcher command 불일치 (actual='$_stop_command' expected='$EXPECTED_STOP_DISPATCHER_COMMAND')"
    fi

    # PreToolUse는 issue #587에서 template-owned로 등록 — pinning-guard managed entry 포함 여부 검사.
    if [ "${_pre_total_count:-0}" -ge 1 ] 2>/dev/null; then
      pass "[[hooks.PreToolUse]] entry 존재 (count=$_pre_total_count)"
    else
      fail "[[hooks.PreToolUse]] entry 부재 (count=${_pre_total_count:-?})"
    fi

    if [ "$_pre_has_managed" = "1" ]; then
      pass "PreToolUse에 expected managed command 포함: $EXPECTED_PRE_TOOL_USE_PINNING_GUARD_COMMAND"
    else
      fail "PreToolUse에 expected managed command 없음 (expected='$EXPECTED_PRE_TOOL_USE_PINNING_GUARD_COMMAND')"
    fi

    # PostToolUse는 issue #603에서 template-owned로 등록 — pinning-alert managed entry 포함 여부 검사.
    # 사용자 추가 entry는 sync-codex-config.py 정책상 보존되지 않지만, 본 검사는 managed entry 존재만 확인.
    if [ "${_post_total_count:-0}" -ge 1 ] 2>/dev/null; then
      pass "[[hooks.PostToolUse]] entry 존재 (count=$_post_total_count)"
    else
      fail "[[hooks.PostToolUse]] entry 부재 (count=${_post_total_count:-?})"
    fi

    if [ "$_post_has_managed" = "1" ]; then
      pass "PostToolUse에 expected managed command 포함: $EXPECTED_POST_TOOL_USE_PINNING_COMMAND"
    else
      fail "PostToolUse에 expected managed command 없음 (expected='$EXPECTED_POST_TOOL_USE_PINNING_COMMAND')"
    fi
  fi
fi

# command resolution: $HOME 확장 후 hook 사본이 실재 + executable + canonical target이
# 어떤 nixos-config checkout의 modules/shared/programs/codex/files/hooks/<name>인지 검증.
# worktree 환경에서는 activation이 mkOutOfStoreSymlink target을 main checkout(nixosConfigPath)으로
# 두지만 verifier는 worktree REPO_ROOT에서 실행되므로 두 경로가 다를 수 있다. 따라서 path suffix
# 매칭(.../modules/shared/programs/codex/files/hooks/<name>)과 readlink target 실재만 검사하여
# main checkout / worktree 양쪽에서 false fail이 나지 않도록 한다.
_check_hook_executable ".codex/hooks/record-prompt-submit.sh"
_check_hook_executable ".codex/hooks/_stop-dispatcher.sh"
for _sub in "${EXPECTED_DISPATCHER_SUB_SCRIPTS[@]}"; do
  _check_hook_executable ".codex/hooks/$_sub"
done
_check_hook_executable ".codex/hooks/pinning-alert.sh"
_check_hook_executable ".codex/hooks/pinning-guard.sh"

_check_executable_symlink_suffix ".claude/hooks/pinning-guard.sh" \
  "modules/shared/programs/claude/files/hooks/pinning-guard.sh"

_check_readable_symlink_suffix() {
  local relpath="$1" expected_suffix="$2"
  local abspath="$HOME/$relpath"
  if [ ! -e "$abspath" ]; then
    fail "프로비저닝 파일 없음: $abspath"
    return
  fi
  if [ ! -r "$abspath" ]; then
    fail "프로비저닝 파일 읽기 불가: $abspath"
    return
  fi
  local resolved
  resolved="$(readlink -f "$abspath" 2>/dev/null || true)"
  if [ -z "$resolved" ] || [ ! -f "$resolved" ]; then
    fail "프로비저닝 파일 readlink 실패 또는 target 부재: $relpath (resolved=$resolved)"
    return
  fi
  case "$resolved" in
    */"$expected_suffix")
      pass "프로비저닝 파일 OK: $relpath"
      ;;
    *)
      fail "프로비저닝 파일 target suffix 불일치: $relpath (resolved=$resolved expected_suffix=*/$expected_suffix)"
      ;;
  esac
}

_pinning_lib_suffix="modules/shared/programs/claude/files/lib/pinning-patterns.sh"
_check_readable_symlink_suffix ".claude/lib/pinning-patterns.sh" "$_pinning_lib_suffix"
_check_readable_symlink_suffix ".codex/lib/pinning-patterns.sh" "$_pinning_lib_suffix"
_hook_runtime_lib_suffix="modules/shared/programs/claude/files/lib/hook-runtime.sh"
_check_readable_symlink_suffix ".claude/lib/hook-runtime.sh" "$_hook_runtime_lib_suffix"
_check_readable_symlink_suffix ".codex/lib/hook-runtime.sh" "$_hook_runtime_lib_suffix"

# Pinning patterns shared library 검사:
#   scripts/ai/commit-msg-pinning.sh 및 Pre/PostToolUse pinning hook들이 공통 lib를 source한다.
#   패턴 정의와 scan helper drift는 lib provisioning + direct source checks로 검증한다.
echo ""
echo "=== Pinning patterns shared library 검사 ==="
_pinning_lib="$REPO_ROOT/modules/shared/programs/claude/files/lib/pinning-patterns.sh"
_pinning_hooks=(
  "$REPO_ROOT/scripts/ai/commit-msg-pinning.sh"
  "$REPO_ROOT/modules/shared/programs/claude/files/hooks/pinning-alert.sh"
  "$REPO_ROOT/modules/shared/programs/claude/files/hooks/pinning-guard.sh"
  "$REPO_ROOT/modules/shared/programs/codex/files/hooks/pinning-alert.sh"
  "$REPO_ROOT/modules/shared/programs/codex/files/hooks/pinning-guard.sh"
)
for _var in PATTERN_A PATTERN_B PATTERN_C PINNING_REPORT_INDENT PINNING_PATTERN_A_LABEL PINNING_PATTERN_B_LABEL PINNING_PATTERN_C_LABEL; do
  _lib_line="$(grep -m1 -E "^${_var}=" "$_pinning_lib" || true)"
  if [ -n "$_lib_line" ]; then
    pass "pinning $_var shared lib 정의 OK"
  else
    fail "pinning $_var 정의 부재 ($_pinning_lib)"
  fi
done
for _fn in pinning_findings_records pinning_findings_text pinning_match_count pinning_should_check_path pinning_is_prd_or_plan_path pinning_canonicalize_existing_parent_path pinning_apply_patch_added_sections pinning_apply_patch_section_paths pinning_apply_patch_section_lines_for_path pinning_findings_records_for_path pinning_findings_text_for_path pinning_match_count_for_path pinning_guard_findings_text_for_path; do
  if grep -m1 -E "^${_fn}\(\)" "$_pinning_lib" >/dev/null 2>&1; then
    pass "pinning $_fn shared lib 함수 OK"
  else
    fail "pinning $_fn 함수 부재 ($_pinning_lib)"
  fi
done
for _hook in "${_pinning_hooks[@]}"; do
  _hook_basename="${_hook#"$REPO_ROOT"/}"
  if grep -Eq '^[[:space:]]*\.[[:space:]]+"\$PINNING_LIB"' "$_hook"; then
    pass "pinning shared lib source OK: $_hook_basename"
  else
    fail "pinning shared lib source 부재: $_hook_basename"
  fi
done

# ─── USED-BY oracle ───
# claude/files/lib/ 의 공유 라이브러리 (pinning-patterns.sh, session-state.sh, hook-runtime.sh)
# 헤더의 `# USED-BY:` 블록에 선언된 use-site 와 실제 source 호출 패턴 일치를 strict 검증한다.
#
# 각 USED-BY 라인은 `<path>   # via $VAR_NAME` 형식이어야 한다. 형식 위반 라인은 silent skip
# 하지 않고 awk 가 `BAD\t<line>` sentinel 을 emit, shell 이 fail 로 보고한다.
#
# `via $VAR_NAME` 의 의미: use-site 의 source local 변수 (예: `PINNING_LIB`, `SESSION_STATE_LIB`,
# `HOOK_RUNTIME_LIB`). hook_load_lib helper 의 env override 변수 (예: `PINNING_PATTERNS_LIB`)
# 와는 다르다. helper 호출은 `<expected_var>=$(hook_load_lib <env_var> "..." <basename>)` 형태로
# expected_var 변수에 할당하고 그 변수를 source 한다.
#
# 매칭 조건: 같은 파일에 `<expected_var>=...<lib_basename>...` 변수 할당 + `. "$<expected_var>"`
# 또는 `source "$<expected_var>"` 호출. helper 호출도 변수 할당 RHS 의 일부이므로 같은 매칭이 적용된다.
# `# shellcheck source=` 주석 라인은 oracle 대상에서 제외 (실제 source 호출이 아니므로).
verify_used_by_oracle "$REPO_ROOT/modules/shared/programs/claude/files/lib/pinning-patterns.sh" "pinning-patterns.sh"
verify_used_by_oracle "$REPO_ROOT/modules/shared/programs/claude/files/lib/session-state.sh" "session-state.sh"
verify_used_by_oracle "$REPO_ROOT/modules/shared/programs/claude/files/lib/hook-runtime.sh" "hook-runtime.sh"

# fixture self-test (deterministic, live 미실행).
if [ ! -x "$_active_hooks_runner" ]; then
  fail "tests/test-codex-hook-fixtures.sh 실행 불가 (path=$_active_hooks_runner)"
else
  _runner_log="$(mktemp "${TMPDIR:-/tmp}/codex-hook-fixtures-runner.XXXXXX")"
  if "$_active_hooks_runner" --no-live >"$_runner_log" 2>&1; then
    pass "test-codex-hook-fixtures.sh deterministic 통과"
  else
    fail "test-codex-hook-fixtures.sh deterministic 실패 — 아래 로그 참조"
    sed 's/^/    /' "$_runner_log" >&2
  fi
  rm -f "$_runner_log"
fi

echo ""
echo "=== 원본 무결성 확인 ==="

cd "$REPO_ROOT"
if git diff --quiet .claude/skills/ 2>/dev/null; then
  pass ".claude/skills/ 원본 무변경"
else
  warn ".claude/skills/ 에 uncommitted 변경 있음"
fi

echo ""
echo "========================================="
if [ "$errors" -gt 0 ]; then
  echo "검증 실패: ${errors}개 오류, ${warnings}개 경고"
  exit 1
elif [ "$warnings" -gt 0 ]; then
  echo "검증 통과 (경고 ${warnings}개)"
  exit 0
else
  echo "검증 완전 통과"
  exit 0
fi
