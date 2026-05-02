# Review Intensity 판단 절차

Review Intensity 판단의 실행 절차 (3단계 + 판단 실행 + SKIP/LITE 절차 + LITE 라운드 요약 형식). 판단 알고리즘 규칙 SSOT는 [`intensity-rules.md`](intensity-rules.md)다.

Review Intensity 판단은 **독립 에이전트**가 수행한다. 메인 LLM은 판단에 관여하지 않는다.
Codex 세션에서는 native subagent, Claude Code 세션과 headless 세션에서는 codex exec을 사용한다.
`full` modifier가 있으면 이 단계를 건너뛰고 exhaustive override로 직행한다.

## 3단계

| 단계 | 에이전트 수 | 사용자 승인 | 설명 |
|------|-----------|-----------|------|
| SKIP | 0 | 질문 도구 **필수** (런타임별 매핑: [`runtime-mapping.md`](runtime-mapping.md)) | DA 완전 생략 |
| LITE | Correctness 필수 + 관련 reviewer bundles | 불필요 | 필요한 bundle만 선택 실행 |
| FULL | 4 reviewer bundles | 불필요 | 4 reviewer bundle 기본 리뷰 |

`full` modifier는 위 표의 FULL과 다르다. 자동 FULL은 4 reviewer bundle이고,
modifier `full`은 Review Intensity를 건너뛰고 exhaustive 8-domain path로 진입한다.

## 판단 실행 절차

1. 변경 규모 판단용 입력을 준비한다.
   - for_pr: `git diff --stat main...HEAD` (파일 목록+라인 수만, 내용 불포함)
   - for_plan: 계획 요약 (변경 대상 파일 목록 + 변경 유형)
2. **Codex 세션 경로**:
   - fresh intensity subagent 1개를 standard review profile로 띄운다.
   - 프롬프트에는 [`intensity-rules.md`](intensity-rules.md)를 직접 읽고 SKIP/LITE/FULL 중 하나를 첫 줄에 반환하라고 지시한다. Intensity는 no-write role이므로 파일 수정, scratch PoC, main-agent-only command 실행을 금지한다.
   - 결과는 `wait_agent`로 받고, timeout만으로 실패 처리하거나 중간 kill/self-auditing 대체를 하지 않는다. 파싱이 끝나면 completed intensity thread를 `close_agent`로 닫는다.
3. **codex exec 경로** (Claude Code 세션 · headless 세션):
   - 모든 런타임은 [`runtime-mapping.md`](runtime-mapping.md)의 공통 주의(셸 호출 간 변수 유실)를 따른다.
   - 임시 디렉토리를 생성한다: `INTENSITY_DIR=$(mktemp -d /tmp/da-${_DA_SID}-intensity-XXXXXX)`
   - 프롬프트 파일을 생성한다 (umask 077로 권한 제한):
     ```zsh
     (umask 077; cat > "$INTENSITY_DIR/prompt.md" <<'PROMPT'
     run-da skill의 references/intensity-rules.md (홈 기준 경로:
     ~/.claude/skills/run-da/references/intensity-rules.md
     또는 repo의 modules/shared/programs/claude/files/skills/run-da/references/intensity-rules.md)를
     직접 읽어 판단 알고리즘 규칙을 적용하라.
     아래 변경 정보를 보고 SKIP/LITE/FULL 중 하나를 판정하라.
     결과의 첫 줄에 판정(SKIP/LITE/FULL), 이후에 근거를 기술하라.
     리뷰만 수행하고 파일을 수정하지 마라.

     {for_pr: `git diff --stat main...HEAD` 출력 / for_plan: 변경 대상 파일 목록 + 변경 유형}
     PROMPT
     )
     ```
   - **foreground 실행** (단일 exec이므로 결과를 즉시 확인):
     ```zsh
     # marker must apply to `codex`, not `cat` (issue #585): Codex 0.124+ hooks의 early-exit 신호.
     # standard review profile (model="gpt-5.5", effort="medium") — --ignore-user-config로 config.toml의
     # model과 effort가 모두 차단되므로 둘 다 explicit pin (review profile 매핑은 runtime-mapping.md SSOT).
     cat "$INTENSITY_DIR/prompt.md" | env CODEX_PROGRAMMATIC=1 codex-exec-supervised --sandbox read-only --ignore-user-config --ignore-rules --ephemeral \
       -c model="gpt-5.5" \
       -c model_reasoning_effort="medium" \
       -o "$INTENSITY_DIR/result.md" \
       - \
       2>"$INTENSITY_DIR/stderr.log"
     ```
4. 메인 LLM이 결과를 읽고 판정에 따라 분기한다:
   - SKIP → 질문 도구로 사용자 승인 (아래 SKIP 절차)
   - LITE → reviewer bundle 선택 (아래 LITE 절차)
   - FULL → 4 reviewer bundles 실행
5. **실패 시 FULL 강제** — Codex 세션 경로에서는 응답 파싱 실패/agent failure, codex exec 경로에서는 결과 파일 없음·빈 결과·exit code 비정상·첫 줄 파싱 실패.
6. Review Intensity 판단 결과(SKIP/LITE/FULL)와 근거를 사용자에게 보고한다.

판단 알고리즘 규칙 상세 및 예시는 [`intensity-rules.md`](intensity-rules.md) 참조.

## SKIP 절차

1. 질문 도구로 사용자에게 DA 생략 승인을 요청한다:
   - 변경 내용 요약
   - SKIP 판단 근거
   - "DA를 생략해도 괜찮겠습니까?"
2. 사용자가 승인하면 DA를 생략하고 해당 모드(for_plan/for_pr)를 종료하여 상위 워크플로로 복귀한다.
3. 사용자가 거부하면 LITE 또는 FULL로 승격하여 DA를 진행한다.

질문 도구를 호출할 수 없는 런타임에서는 [`arbiter-scaling.md`](arbiter-scaling.md)의 "질문 도구 미지원 대응" 섹션을 따른다 (자동 LITE 승격 등).

## LITE 절차

1. `Correctness`는 항상 포함한다. (`SECURITY`와 `HALLUCINATION` 안전장치를 함께 유지한다.)
2. 코드 변경이면 `Regression`도 기본 포함한다 (기존 호출부 회귀 검출을 위해).
3. 나머지 bundle 중 변경 성격에 직접 관련된 bundle만 선택한다.
   선택 판단 기준: 해당 bundle의 "집중 대상"([`da-domains.md`](da-domains.md))이 이번 변경에 적용되는가.
4. 선택되지 않은 bundle은 `NOT_RUN`으로 기록한다.
5. 선택된 bundle만으로 [`../modes/for_plan.md`](../modes/for_plan.md) / [`../modes/for_pr.md`](../modes/for_pr.md)의 절차를 수행한다.
6. 종료 조건: **선택된 bundle 전부 CLEAR** (`NOT_RUN` bundle은 평가 대상 아님).

### LITE 예시

단일 함수명 정리 리팩터링 → **Correctness** + **Regression** + **Maintainability** 실행.
미실행: Design(NOT_RUN).
이유: Correctness는 항상 포함, Regression은 코드 변경이므로 기본 포함,
Maintainability는 이름/가독성 변화에 직접 관련된다.

### LITE 라운드 요약 형식

```text
Round N 요약 (LITE: 선택 M개/전체 4개 reviewer bundles): DA 발견 X건
→ Arbiter: CONFIRMED Y건, NOT_AN_ISSUE Z건, NEEDS_MORE_INFO W건
bundle별: Correctness CLEAR, Regression 2건(CONFIRMED 1, NOT_AN_ISSUE 1), ...
미실행: Design(NOT_RUN), ...
selective: trigger P건 → stable Q건, split R건, fragmented S건, partial_failure T건  ← selective consistency 발동 라운드에만 추가
```

selective consistency가 발동하지 않은 라운드는 마지막 줄을 생략한다. stability_status 집계 규칙은 [`protocol.md`](protocol.md)의 "라운드 요약 기록" 참조.
