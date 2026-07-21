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

# --from-head: working tree 대신 HEAD 커밋의 문서를 읽는다. pre-push에서 사용 —
# unstaged로만 고쳐진 스탬프가 "일치"로 보이면 구 스탬프가 담긴 HEAD가 조용히 push되므로,
# push 경계에서는 실제 push 대상 트리를 검사한다.
FROM_HEAD=false
[ "${1:-}" = "--from-head" ] && FROM_HEAD=true

# 대상 문서 읽기 — FROM_HEAD면 git 객체에서, 아니면 working tree에서.
doc_exists() {
  if $FROM_HEAD; then
    git -C "$REPO_ROOT" cat-file -e "HEAD:$1" 2>/dev/null
  else
    [ -f "$REPO_ROOT/$1" ]
  fi
}

doc_content() {
  if $FROM_HEAD; then
    git -C "$REPO_ROOT" show "HEAD:$1" 2>/dev/null
  else
    # $(<file)은 bash 내장 읽기 — PATH가 최소화된 hook 환경에서 외부 cat 의존을 피한다.
    printf '%s\n' "$(<"$REPO_ROOT/$1")"
  fi
}

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
# 대상 skill root를 추가/변경하면 lefthook.yml의 ai-skill-version-stamps glob과
# scripts/ai/check-lefthook-staged-config.sh의 기대 블록, tests/suites/skill-version-stamps.sh의
# fixture(대상 경로·스탬프·기대 경고 건수)도 함께 갱신한다 (4곳 수동 동기화).
TARGETS=(
  "using-codex-exec|modules/shared/programs/claude/files/skills/using-codex-exec/SKILL.md|codex|codex-cli "
  "using-claude-p|modules/shared/programs/claude/files/skills/using-claude-p/SKILL.md|claude|Claude Code v"
  "configuring-codex|.claude/skills/configuring-codex/SKILL.md|codex|codex-cli "
)

# 설치된 CLI의 --version 출력에서 첫 X.Y[.Z...] 토큰 추출
# (codex: "codex-cli 0.144.6" / claude: "2.1.216 (Claude Code)").
# CLI 존재 확인은 호출부 책임 — 여기 실패는 실행·파싱 실패를 뜻한다.
installed_version() {
  local cli="$1" output
  output="$("$cli" --version 2>/dev/null)" || return 1
  local pattern='([0-9]+(\.[0-9]+)+)'
  [[ "$output" =~ $pattern ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

# 파일 전체에서 "- 확인 버전:" 형식의 최초 일치 라인에서 prefix 뒤 버전 토큰 추출.
# 절 경계는 확인하지 않는다 — 이 고정 형식 라인은 "작성 기준" 절에만 존재한다는 전제이며,
# 다른 절에 같은 형식이 생기면 먼저 나오는 쪽이 이긴다.
stamp_version() {
  local rel_path="$1" prefix="$2" line
  local pattern="^- 확인 버전: ${prefix}([0-9]+(\.[0-9]+)+)"
  while IFS= read -r line; do
    if [[ "$line" =~ $pattern ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  done < <(doc_content "$rel_path")
  return 1
}

# 파일 전체에서 "- 재검증:" 형식의 최초 일치 라인에서 백틱 안 명령 텍스트 추출
# (WARN 메시지 병기용 — stamp_version과 같은 최초-일치 전제).
recheck_command() {
  local rel_path="$1" line
  local pattern='^- 재검증: `([^`]+)`'
  while IFS= read -r line; do
    if [[ "$line" =~ $pattern ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  done < <(doc_content "$rel_path")
  return 1
}

main() {
  local entry skill rel_path cli prefix
  local doc_ver cli_ver recheck warnings=0

  if is_true "${SKIP_AI_SKILL_CHECK:-}"; then
    return 0
  fi

  for entry in "${TARGETS[@]}"; do
    IFS='|' read -r skill rel_path cli prefix <<< "$entry"

    # CLI 부재만 조용히 skip한다 (정책: 미설치 환경 무소음). 설치된 CLI의
    # 실행·파싱 실패는 출력 계약 drift 신호이므로 WARN으로 드러낸다.
    command -v "$cli" >/dev/null 2>&1 || continue
    if ! cli_ver="$(installed_version "$cli")"; then
      warn "$skill: $cli --version 실행·버전 파싱 실패 — CLI 출력 형식 변경 시 이 체크의 추출 규칙도 갱신"
      warnings=$((warnings + 1))
      continue
    fi

    if ! doc_exists "$rel_path"; then
      warn "$skill: SKILL.md 없음 ($rel_path) — 대상 목록 갱신 필요"
      warnings=$((warnings + 1))
      continue
    fi

    if ! doc_ver="$(stamp_version "$rel_path" "$prefix")"; then
      warn "$skill: '확인 버전' 스탬프 추출 실패 ($rel_path) — 스탬프 형식 변경 시 이 체크의 추출 규칙도 갱신"
      warnings=$((warnings + 1))
      continue
    fi

    if [ "$doc_ver" != "$cli_ver" ]; then
      recheck="$(recheck_command "$rel_path")" || recheck="$rel_path '작성 기준' 절의 재검증 명령 참조"
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
