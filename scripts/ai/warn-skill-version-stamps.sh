#!/usr/bin/env bash
# warn-skill-version-stamps.sh
# 목적: 외부 CLI(codex/claude) 의존 스킬 SKILL.md의 "확인 버전" 스탬프와 설치 CLI 버전의
#       drift를 pre-commit에서 조기 경보 (#1078 — drift 전면 재작성 재발: PR #967, #1036, #1074)
# 정책:
# - 항상 warning-only (exit 0) — 버전 상승은 오류가 아니라 "재검증 명령을 실행할 때" 신호
# - CLI 부재 환경(CI 등)에서는 해당 대상을 조용히 skip (노이즈 금지)
# - 스탬프 형식의 SSOT는 각 SKILL.md "작성 기준" 절 — 이 체크가 형식에 맞춘다 (역방향 금지)
# - 우회: SKIP_AI_SKILL_CHECK=1 (또는 true/yes)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

warn() {
  echo "[WARN] $1" >&2
}

is_true() {
  local val="${1:-}"
  val="${val,,}"
  [ "$val" = "1" ] || [ "$val" = "true" ] || [ "$val" = "yes" ]
}

# 대상 선언: <스킬 이름>|<SKILL.md 상대경로>|<CLI 명령>|<스탬프 버전 prefix>
# 스탬프 라인은 "- 확인 버전: <prefix><버전>[ 부가 설명]" 형식이며, configuring-codex처럼
# 버전 뒤 괄호 텍스트가 붙어도 매칭한다. prefix의 trailing space는 필드 구분자 IFS='|'가
# whitespace를 포함하지 않아 read에서 보존된다.
TARGETS=(
  "using-codex-exec|modules/shared/programs/claude/files/skills/using-codex-exec/SKILL.md|codex|codex-cli "
  "using-claude-p|modules/shared/programs/claude/files/skills/using-claude-p/SKILL.md|claude|Claude Code v"
  "configuring-codex|.claude/skills/configuring-codex/SKILL.md|codex|codex-cli "
)

# CLI --version 출력의 첫 X.Y[.Z...] 토큰 추출
# (codex: "codex-cli 0.144.6" / claude: "2.1.216 (Claude Code)")
installed_version() {
  local cli="$1" output
  command -v "$cli" >/dev/null 2>&1 || return 1
  output="$("$cli" --version 2>/dev/null)" || return 1
  local pattern='([0-9]+(\.[0-9]+)+)'
  [[ "$output" =~ $pattern ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

# SKILL.md "작성 기준" 절의 "- 확인 버전:" 라인에서 prefix 뒤 버전 토큰 추출
stamp_version() {
  local file="$1" prefix="$2" line
  local pattern="^- 확인 버전: ${prefix}([0-9]+(\.[0-9]+)+)"
  while IFS= read -r line; do
    if [[ "$line" =~ $pattern ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  done < "$file"
  return 1
}

# 같은 절의 "- 재검증:" 라인에서 백틱 안 명령 텍스트 추출 (WARN 메시지 병기용)
recheck_command() {
  local file="$1" line
  local pattern='^- 재검증: `([^`]+)`'
  while IFS= read -r line; do
    if [[ "$line" =~ $pattern ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  done < "$file"
  return 1
}

main() {
  local entry skill rel_path cli prefix file
  local doc_ver cli_ver recheck warnings=0

  if is_true "${SKIP_AI_SKILL_CHECK:-}"; then
    return 0
  fi

  for entry in "${TARGETS[@]}"; do
    IFS='|' read -r skill rel_path cli prefix <<< "$entry"
    file="$REPO_ROOT/$rel_path"

    cli_ver="$(installed_version "$cli")" || continue

    if [ ! -f "$file" ]; then
      warn "$skill: SKILL.md 없음 ($rel_path) — 대상 목록 갱신 필요"
      warnings=$((warnings + 1))
      continue
    fi

    if ! doc_ver="$(stamp_version "$file" "$prefix")"; then
      warn "$skill: '확인 버전' 스탬프 추출 실패 ($rel_path) — 스탬프 형식 변경 시 이 체크의 추출 규칙도 갱신"
      warnings=$((warnings + 1))
      continue
    fi

    if [ "$doc_ver" != "$cli_ver" ]; then
      recheck="$(recheck_command "$file")" || recheck="$rel_path '작성 기준' 절의 재검증 명령 참조"
      warn "$skill: 문서 스탬프 $doc_ver vs 설치 $cli_ver — 재검증: $recheck"
      warnings=$((warnings + 1))
    fi
  done

  if [ "$warnings" -gt 0 ]; then
    warn "스킬 버전 스탬프 경고 ${warnings}건 (warn-only — 재검증 후 스탬프 갱신)"
  fi
}

main "$@" || warn "스킬 버전 스탬프 검사 중 내부 오류 발생 (warn-only)"
exit 0
