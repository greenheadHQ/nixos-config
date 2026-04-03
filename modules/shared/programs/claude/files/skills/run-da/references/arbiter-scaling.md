# Arbiter 동적 스케일링 규칙

Arbiter 에이전트의 실행 수, 실행 계약, 실패 처리를 정의한다.

## 기본값: single strong arbiter

P0 기본값은 **항상 단일 강한 Arbiter 1개**다.
`run-da`의 reviewer fan-out을 4 bundle로 줄이더라도, Arbiter는 기본적으로 늘리지 않는다.
비용을 늘려 여러 Arbiter를 붙이기보다, 한 명의 강한 Arbiter가 selective escalation set을 판정하는 구조를 유지한다.

## v1: 단순 스케일링

| Findings 개수 | Arbiter 수 |
|---|---|
| 0건 | 0 (SKIP) |
| 1건 이상 | 1 |

v1은 selective propagation으로 추린 escalated findings를 단일 Arbiter에 전달한다.
교차 검증, 교차 Arbiter 비교는 기본값이 아니다.

## 예외적 확장 조건

다음 조건이 명확히 충족될 때만 Arbiter 2개+ 확장을 검토한다.

1. 같은 위치에 대해 reviewer bundle 간 결론이 실질적으로 충돌하고, 단일 Arbiter가 반복해서 `NEEDS_MORE_INFO`만 반환할 때
2. `CRITICAL`급 `Correctness` finding처럼 오판 비용이 매우 큰데, 확인/기각 근거가 서로 강하게 충돌할 때
3. 반복 세션에서 단일 Arbiter의 drift 또는 false-negative 패턴이 누적되어 보정이 필요하다는 실증이 있을 때

위 조건이 없으면 Arbiter를 늘리지 않는다. reviewer 수가 많다는 이유만으로 자동 확장하지 않는다.

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
cat > "$ARBITER_DIR/arbiter-prompt.md" <<'PROMPT'
{조립된 Arbiter 프롬프트 — 비신뢰 텍스트(계획 원문, DA 결과) 포함 시 반드시 quoted heredoc 사용}
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

Codex 환경 감지: 환경 변수 `CODEX_CI=1`이 설정되어 있으면 Codex로 간주한다.
(`CODEX_CI`는 codex의 `UNIFIED_EXEC_ENV`에 하드코딩되어 모든 subprocess에 강제 주입된다. 검증 기준: codex-cli v0.117.0+)

Codex에서 run-da 실행 시 AskUserQuestion(`request_user_input`) 미지원 (검증: codex-cli v0.118.0, Default 모드에서 `request_user_input` 호출 시 에러 반환):

- NEEDS_MORE_INFO 항목은 **CONFIRMED_ISSUE로 자동 승격**한다 (텍스트 보고만으로는 상태 전이가 불가능하므로).
- CONFIRMED_ISSUE는 동일하게 자동 수정한다.
- SKIP 판정 시 AskUserQuestion 불가 → **자동 LITE 승격**.
- 3회 반복 규칙 도달 시 AskUserQuestion 불가 → **자동 수용** (지적대로 수정).
- 5회 라운드 초과 시 AskUserQuestion 불가 → **자동 종료** (현재 상태로 CLEAR 간주, DA 루프 종료).

## Review Intensity 판단 에이전트 실행 계약

DA 에이전트/Arbiter와 동일한 codex exec 계약을 따르되, 다음이 다르다:

| 항목 | DA/Arbiter | Review Intensity |
|------|-----------|-----------------|
| 입력 | diff 전체 또는 계획 전체 | `git diff --stat` 또는 계획 파일 목록 |
| 출력 | findings/verdicts | SKIP/LITE/FULL + 근거 (첫 줄 판정 + 이후 근거) |
| 참조 | da-domains.md, arbiter-prompt.md | intensity-rules.md |
| 실패 시 | NEEDS_MORE_INFO 승격 | **FULL 강제** |

- `--full-auto --ephemeral`로 실행한다.
- 프롬프트에서 "references/intensity-rules.md를 직접 읽어 규칙을 적용하라"고 지시한다.
- 프롬프트 파일은 `umask 077`로 권한 제한한다.
- 메인 LLM은 결과 파일을 읽고 판정에 따라 분기한다. AskUserQuestion(SKIP 시)은 메인 LLM이 호출한다.
- Codex 환경에서의 SKIP 처리는 위 "Codex 환경 대응" 섹션의 규칙을 따른다.

## 향후 확장

위 예외 조건이 실제로 반복 검증되면 교차 검증(Arbiter 2개+)이나 Known-Answer Calibration 도입을 검토한다.
그 전까지는 single strong arbiter가 기본 계약이다.
