#!/usr/bin/env bash
# commit-msg-pinning.sh
# 목적: commit message에서 LLM 박제(pinning) 패턴을 감지하고 경고. 영구 산출물(commit/PR/이슈)에
#       세션 내부 메타데이터(라운드 번호/finding ID/partial hash)가 박혀 squash 후 dangling되거나
#       drift를 일으키는 것을 차단한다.
# 정책:
# - warn-only: 매치 시 stderr 경고만 출력하고 exit 0. commit 차단하지 않음. lefthook 단계 자체를
#   건너뛰려면 lefthook 표준 메커니즘 (`LEFTHOOK=0`, `--no-verify`)을 사용한다.
# - revert 예외: commit msg 첫 줄이 "revert" 또는 "Revert"로 시작하면 partial hash 검사 skip.
# 작동 범위: 이 hook은 신규 commit message만 검사한다. 과거 commit / squash commit body /
#   PR · 이슈 본문에 이미 박힌 잔존 박제는 **소급해서 수정하지 않으며** 본 hook 범위 밖이다.
set -euo pipefail

# 검사 대상 commit msg 파일 (lefthook이 {1}로 전달)
COMMIT_MSG_FILE="${1:-.git/COMMIT_EDITMSG}"

if [ ! -f "$COMMIT_MSG_FILE" ]; then
  exit 0
fi

# Partial commit hash 길이 경계: GitHub 단축 hash 7자 최소, 12자 상한 (full SHA-1 40자보다 짧고
# 사람이 손으로 인용하는 범위).
HASH_MIN=7
HASH_MAX=12

# commit msg 본문을 임시 파일에 정제 저장 (verbose diff 라인 `#` 주석 제거).
# 모든 grep을 파일 직접 읽기로 처리 — `echo "$VAR" | grep` 조합은 큰 메시지 + grep -q 조기
# 종료 시 echo가 SIGPIPE를 받아 set -o pipefail 환경에서 pipeline이 nonzero를 반환하고
# warn이 silent fail 한다 (PoC 검증). bash here-string도 동일 위험.
CLEAN_MSG=$(mktemp)
trap 'rm -f "$CLEAN_MSG"' EXIT
sed -e '/^#/d' "$COMMIT_MSG_FILE" > "$CLEAN_MSG"

# commit msg 첫 줄 (revert prefix 판단용) — head는 첫 줄만 읽으므로 SIGPIPE 위험 동일하지만
# 1줄 읽기는 buffer 크기 미만이라 실측 안전. 명시적 read로 더 견고하게.
read -r FIRST_LINE < "$CLEAN_MSG" || FIRST_LINE=""

warn() {
  echo "[WARN] pinning: $1" >&2
}

# check_ere — 단순 정규식 검사 흐름 통합 helper (PATTERN_A/B/C 공통 구조).
# 매치 시 warn + 줄번호 출력 + found=1 설정. found는 셸 전역 변수 (subshell 회피 위해 함수 안 사용).
# usage: check_ere "$PATTERN" "$WARN_MESSAGE"
check_ere() {
  local pattern="$1"
  local message="$2"
  if grep -qE "$pattern" "$CLEAN_MSG"; then
    warn "$message"
    grep -nE "$pattern" "$CLEAN_MSG" | sed 's/^/         /' >&2
    found=1
  fi
}

# 패턴 A — 진행 라운드 카운터: "Round N" (단어경계 + Round prefix 의무화).
# 단독 R[0-9]+는 false positive 너무 많아 제외 (정당한 약어 IPv4 R3, docs 표 R1/R2/R3 등).
PATTERN_A='\bRound [0-9]+\b'

# 패턴 B — DA finding ID 형식: BUNDLE-순번 (BUNDLE은 Title Case 풀이름 / UPPERCASE 세부 도메인 /
# 약어 모두 가능, suffix는 항상 숫자 시작). DA 출력 형식 SSOT는 modules/.../run-da/references/da-domains.md.
# 본 토큰 enum은 SSOT 스냅샷이며 자동 동기화되지 않는다 — da-domains.md에서 bundle/세부 도메인을
# 추가/제거하면 본 패턴도 함께 갱신해야 한다. 숫자 시작 suffix 의무화로 자연어 (Design-pattern,
# Regression-fix, YAGNI-concern, F-string, CIR-section, REG-istry 등) false positive 회피.
# 'F' 토큰은 SSOT 정의 없어 제거. 'DESIGN'/'REGR'은 'Design'/'REG'와 중복이라 제거.
PATTERN_B='\b(Correctness|Design|Regression|Maintainability|SECURITY|HALLUCINATION|SIDE_EFFECT|CONSISTENCY|READABILITY|CLEAN_CODE|YAGNI|NGMI|CORR|MAINT|REG|CIR)-[0-9][A-Za-z0-9-]*\b'

# 패턴 C — DA 키워드 컨텍스트: "DA for_pr" / "DA for_plan" / "DA 피드백".
# 앞쪽 단어경계 + 컨텍스트 좁힘. "DA Round N"은 패턴 A가 처리하므로 중복 분기 제거 (alert fatigue 회피).
PATTERN_C='\bDA (for_pr|for_plan|피드백)\b'

# 패턴 D — partial hex 박제. 백틱 토큰뿐 아니라 raw `7e75df6` / `(7e75df6)` / `commit 7e75df6`
# 같은 일반 인용 형태도 감지한다 (Codex review로 백틱 전용 PATTERN_D가 raw hex 박제 사례를
# 놓치는 점이 확인됨). 길이 7-12자 + hex 알파벳(a-f) 1개 이상 의무 (full SHA 40자 제외 + 순수 숫자열 제외).
# commit msg 첫 줄이 revert로 시작하면 검사 전체를 skip (정당한 git revert hash 인용 회피).
# hex 매직 상수(`deadbeef` 등) 인용은 매치되나 발생 빈도 낮음 — 의도적 인용이면 amend로 무시 가능.
# `(cherry picked from commit ...)` 같은 자동 생성 라인의 hash 인용은 박제로 간주 — 자동 머지 hash가
# 이후 squash로 dangling될 위험이 있어 의도적으로 차단 (false positive 시 amend).
# grep -oE는 광범위 후보(\b16진 7-40자\b)를 잡고, awk가 길이/알파벳/full SHA 조건을 후처리한다.
PATTERN_D='\b[a-f0-9]{7,40}\b|`[a-f0-9]+`'

found=0

check_ere "$PATTERN_A" "라운드 카운터(\`Round N\`) 박제 감지. 영구 산출물에는 자연어 설명으로 표현하라."
check_ere "$PATTERN_B" "DA finding ID 박제 감지. 라운드/finding ID는 휘발성 보고에만 사용하고 commit message에는 박지 마라."
check_ere "$PATTERN_C" "DA 키워드 박제 감지. 검토 라운드/모드 표기는 commit message에 박지 말고 PR 코멘트 또는 휘발성 작업 노트에 둬라."

if [[ ! "$FIRST_LINE" =~ ^[Rr]evert ]]; then
  # PATTERN_D awk 후처리: 길이 7-12, hex 알파벳 1개 이상, full SHA(>=40) 제외.
  # awk는 명시적 exit 없이 모든 입력을 처리 — set -o pipefail 안전 (||true로 추가 안전망).
  pinning_hash_report=$(grep -noE "$PATTERN_D" "$CLEAN_MSG" 2>/dev/null \
    | awk -v min="$HASH_MIN" -v max="$HASH_MAX" '
        { idx = index($0, ":"); lineno = substr($0, 1, idx - 1); tok = substr($0, idx + 1);
          gsub(/`/, "", tok); n = length(tok);
          if (n < min || n > max) next;
          if (tok !~ /[a-f]/) next;
          print "         " lineno ": " tok }
      ' || true)
  if [ -n "$pinning_hash_report" ]; then
    warn "Partial commit hash 박제 감지. squash 머지 시 dangling 위험. 안정 식별자(PR 번호, 머지된 SHA)로 대체하라."
    echo "$pinning_hash_report" >&2
    found=1
  fi
fi

if [ "$found" -eq 1 ]; then
  warn "위 경고는 차단하지 않습니다 (warn-only). 검토 후 amend로 정정하거나 의도적 사용이면 무시하세요."
fi

exit 0
