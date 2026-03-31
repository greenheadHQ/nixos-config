# Arbiter 동적 스케일링 규칙

Arbiter 에이전트의 실행 수, 실행 계약, 실패 처리를 정의한다.

## v1: 단순 스케일링

| Findings 개수 | Arbiter 수 |
|---|---|
| 0건 | 0 (SKIP) |
| 1건 이상 | 1 |

v1은 모든 findings를 단일 Arbiter에 일괄 전달한다.
교차 검증, 교차 Arbiter 비교는 v1 범위 밖이다.
실제 Arbiter 오판 사례가 누적된 후 교차 검증 도입을 검토한다.

## 실행 계약 (codex exec 계승)

Arbiter는 기존 DA 에이전트와 동일한 codex exec 계약을 따른다:

- `codex exec --full-auto --ephemeral`
- `run_in_background: true` (background Bash tool 호출)
- `-o "$ARBITER_DIR/arbiter-result.md"` 결과 파일
- `"$(cat "$ARBITER_DIR/arbiter-prompt.md")"` 인라인 인자
- `2>"$ARBITER_DIR/arbiter-stderr.log"` stderr 분리
- `-m` 플래그 생략 (config.toml 기본 모델)
- 프롬프트에서 "리뷰만 수행하고 파일을 수정하지 마라" 명시
- `--ephemeral`로 세션 히스토리 오염 방지

`& + wait` shell-level 병렬을 사용하지 않는다 (Bash tool sandbox 제약).
stdin pipe 대신 `"$(cat file)"` 인라인 인자를 사용한다.

## 실행 절차

```bash
# 1. Arbiter 임시 디렉토리 생성
ARBITER_DIR=$(mktemp -d /tmp/da-arbiter-XXXXXX)

# 2. Arbiter 프롬프트 파일 조립 (arbiter-prompt.md의 조립 규칙 참조)
cat > "$ARBITER_DIR/arbiter-prompt.md" << PROMPT
{조립된 Arbiter 프롬프트}
PROMPT

# 3. codex exec 실행 (background)
codex exec --full-auto --ephemeral \
  -o "$ARBITER_DIR/arbiter-result.md" \
  "$(cat "$ARBITER_DIR/arbiter-prompt.md")" \
  2>"$ARBITER_DIR/arbiter-stderr.log"

# 4. 결과 수집
# - arbiter-result.md가 있고 비어있지 않으면 성공
# - 없거나 빈 경우, 또는 exit code != 0이면 실패
```

## 실패 처리

codex exec 실패 시 (exit code != 0, 빈 결과 파일):

1. 해당 Arbiter 실행의 모든 findings를 NEEDS_MORE_INFO로 일괄 승격한다.
2. 사용자에게 AskUserQuestion으로 보고한다 (맥락 설명 의무 적용).
3. 재시도하지 않는다 (사용자가 판단).

## Codex 환경 대응

Codex에서 run-da 실행 시 AskUserQuestion 미지원:

- NEEDS_MORE_INFO 항목은 **CONFIRMED_ISSUE로 자동 승격**한다 (텍스트 보고만으로는 상태 전이가 불가능하므로).
- CONFIRMED_ISSUE는 동일하게 자동 수정한다.
- Codex 환경 감지: `AGENTS.override.md`가 존재하면 Codex로 간주한다.

## 향후 확장

Arbiter 오판 사례가 누적되면 교차 검증(Arbiter 2개+)이나 Known-Answer Calibration 도입을 검토한다.
