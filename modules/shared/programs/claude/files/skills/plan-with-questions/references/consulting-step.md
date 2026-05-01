# Step 3.5 / Step I-3.5: 외부 LLM 기술 자문

Step 3 직후, 사용자에게 옵션을 제시하기 전(Step 4 직전)에 외부 LLM(`codex exec`)에 anchoring-neutral 옵션 평가를 위임한다. 목적은 사용자가 메인 LLM의 첫 추천에 anchor되어 이후 DA가 결함을 지적해도 재설계를 거부하는 패턴(`#490` 사례)을 차단하는 것이다.

## 적용 범위

- **for_action Step 3.5**: 트레이드오프 항목이 1개 이상이면 무조건 호출.
- **for_issue Step I-3.5**: 블랙박스 체크리스트 "C. 트레이드오프"에 1+ 항목이면 호출. 단순 요구사항 명료화 위주의 인터뷰는 skip.
- **for_prd**: `for_action`과 동일 — 트레이드오프 1+이면 호출. (자체 산출물이 없고 `/prd`로 handoff하므로 Step 3.5 호출은 Step 1-6 내 한 번이며, phase별 반복은 적용되지 않는다.)

## Step 3.5는 Step 5 DA와 다르다

| 항목 | Step 3.5 (consulting) | Step 5 (DA) |
|------|----------------------|-------------|
| 시점 | 사용자 질문 **전** | 사용자 답변 **후** |
| 입력 | 옵션 후보 + evidence | 작성된 plan |
| 출력 | anchoring-neutral 평가 매트릭스 | 결함 verdict (CONFIRMED/NOT_AN_ISSUE/...) |
| 목적 | de-anchoring 전처리 | 사후 검증 |

## 입력 (codex exec 프롬프트 구조)

```
## 작업 목표
{이슈/요청 요약, 1-3 문장}

## Resolved evidence (Step 2 직접 확인)
- 파일: {경로 + 핵심 사실 — `verified` 라벨}
- 명령: {실행 결과}
- 패턴: {기존 코드베이스 컨벤션}

## 제약
{기술/시간/조직 제약}

## Decision points (메인 LLM 추천 제외)
- decision_id: {식별자}
  decision_type: {tradeoff | requirement_interpretation | scope_boundary | ...}
  user_question: {사용자에게 물을 질문 원안}
  candidates:
    - id: {A/B/C}
      description: {중립 묘사 — "간단", "추천" 같은 표현 금지}

## 검증 surface (가용 도구)
{static / unit / integration / E2E / ... — `prd/references/validation-paths.md` catalog 인용}

## Non-goals
{명시적 비목표}
```

**제외할 입력**:
- 메인 LLM의 추천·선호 표현 ("A가 더 간단해 보임", "B를 권장").
- 사용자가 미이해 상태에서 수락한 선택은 `user-proposed candidate` 라벨로만 표시.
- "기본값", "default", "Recommended" 같은 anchor 단어.

## 출력 JSON schema (고정)

```json
{
  "decisions": [
    {
      "decision_id": "<string>",
      "decision_type": "<tradeoff | requirement_interpretation | scope_boundary | ...>",
      "user_question": "<string>",
      "options": [
        {
          "id": "<A | B | C | ...>",
          "description": "<중립 1-2 문장>",
          "evaluation_matrix": {
            "요구충족": "<요약>",
            "구현비용": "<요약>",
            "되돌리기쉬움": "<요약>",
            "운영위험": "<요약>",
            "검증가능성": "<요약>",
            "주요unknown": "<요약>",
            "비용시간추정": "<범위 또는 [UNVERIFIED]>"
          },
          "disqualifiers": ["<이 옵션이 틀릴 수 있는 조건>", "..."],
          "evidence_gaps": ["<verify 필요 사항>", "..."]
        }
      ],
      "validation_needed": "<검증 surface 추천>",
      "ask_user_only_if": "<사용자 판단이 정말 필요한 조건>",
      "can_agent_decide_if": "<에이전트가 판단 가능한 조건>"
    }
  ]
}
```

**금지** (메인 LLM은 codex 출력에서 이 필드들이 발견되면 무시 — anchoring 위험):
- 점수 합산, 순위, "Best", "Recommended", "Default" 라벨.
- 옵션 description에 추천/우열 암시 표현.
- Score 필드, ranking 필드.
- `chosen_*`, `selected_*`, `recommended_*`, `winner` 같은 implicit choice 필드 (codex가 자체 추가한 경우도 무시).
- `rationale` 필드를 단일 옵션 정당화로 사용 — `disqualifiers`/`evidence_gaps`만 표시 가능.

명백히 불가능한 옵션은 출력 단계에서 제외하지 않고 `disqualifiers`로 표시한다 (사용자가 "왜 이게 빠졌는지" 추측하지 않도록).

**프롬프트 정밀화**: 호출자는 "출력 JSON schema를 반환하라"가 아니라 "**위 schema에 맞는 JSON instance를 반환하라. schema definition은 출력하지 마라**"라고 명시한다. 가능하면 1-shot 예시(dummy decision의 JSON instance)를 프롬프트에 포함한다.

## codex exec 호출 명령 템플릿 (SSOT)

본 reference가 Step 3.5 codex exec 명령의 단일 진실 원천이다. SKILL.md / for_action.md / for_issue.md는 본 섹션을 link만 하고 명령을 복제하지 않는다.

호출 패턴은 **3 셸 호출로 분리**한다. 같은 셸 안에서 heredoc 작성 + `codex exec`를 background로 체이닝하면 stdin EOF/heredoc 종료 경합으로 hang이 발생한다 (`using-codex-exec/references/known-issues.md` 명시 패턴). 또한 `trap ... EXIT`는 각 셸 종료 시 즉시 발동하므로 multi-shell 흐름에서 `result.json`이 읽히기 전에 삭제된다 — trap 사용 금지, 명시 cleanup만 사용.

### 셸 호출 1 — 디렉토리 + prompt 파일 생성 (foreground)

```zsh
# 세션 namespace
_FO_SID="${CODEX_COMPANION_SESSION_ID:+${CODEX_COMPANION_SESSION_ID:0:8}}"
if [ -z "$_FO_SID" ]; then
  if command -v sha1sum >/dev/null 2>&1; then
    _FO_SID="$(printf '%s' "$PWD-consult" | sha1sum | head -c 8)"
  else
    _FO_SID="$(printf '%s' "$PWD-consult" | shasum | head -c 8)"
  fi
fi
CONSULT_DIR=$(mktemp -d /tmp/consult-${_FO_SID}-XXXXXX)

# Untrusted input 보호: 메인 에이전트는 프롬프트를 셸 heredoc에 직접 삽입하지 말고
# 파일 편집 도구(Write/Edit)로 "$CONSULT_DIR/prompt.md"에 작성한다. 이슈 본문/외부 입력에
# 단독 PROMPT 라인이 있으면 heredoc이 조기 종료되어 부모 shell에서 임의 명령이 실행될 수 있다.
# 따라서 heredoc 패턴은 사용하지 않고, 별도 파일 쓰기 도구로 prompt.md를 만든다.

echo "CONSULT_DIR=$CONSULT_DIR"
```

메인 에이전트는 stdout의 `CONSULT_DIR` 리터럴 값을 후속 호출에서 재사용한다 (Bash tool 호출 간 변수 비공유).

### 셸 호출 2 — codex exec 실행 (background, timeout 강제)

```zsh
# 위 CONSULT_DIR 리터럴 값을 그대로 사용. timeout으로 budget 강제.
# pipe 좌측에 timeout을 두면 cat (producer)에만 적용되고 codex exec (consumer)는
# 무기한 실행되므로, timeout이 codex exec 프로세스 자체에 적용되도록
# stdin 파일 redirect를 사용한다.
timeout 180 env CODEX_PROGRAMMATIC=1 codex exec \
    -C /tmp/consult-<sid>-XXXXXX \
    --skip-git-repo-check \
    --ignore-user-config \
    --sandbox read-only --ephemeral \
    -c model="gpt-5.5" \
    -c model_reasoning_effort="high" \
    -o /tmp/consult-<sid>-XXXXXX/result.json \
    - \
    < /tmp/consult-<sid>-XXXXXX/prompt.md \
    2>/tmp/consult-<sid>-XXXXXX/stderr.log
```

- **`timeout 180`**: 1-3분 budget 강제. timeout 시 메인 에이전트는 result.json을 무시하고 Step 4에서 Step 3 raw 옵션을 anti-anchoring 4 규칙으로 직접 제시한다 (External Consult: `[UNVERIFIED: timed out]` 기록).
- **`-C /tmp/consult-<sid>-XXXXXX`**: cwd를 repo 외 scratch로 이동. repo의 `.codex/config.toml`(Slack/Linear MCP 등 project-scoped connector) 로드 차단.
- **`--skip-git-repo-check`**: scratch 디렉토리는 git repo 밖이라 codex가 `Not inside a trusted directory`로 거부 — 이 플래그가 필수.
- **`--ignore-user-config`**: `$CODEX_HOME/config.toml` 로드 차단. **이 플래그가 user config의 `model` 설정도 무시하므로 `-c model="gpt-5.5"` 명시가 필수다** (run-da `arbiter-scaling.md` 동일 규칙).
- **`-c model="gpt-5.5"`**: model pin (위 사유로 필수).
- **`--sandbox read-only`**: 모델 shell 실행이 write를 못 한다. **단 read-only sandbox는 파일시스템 write만 차단한다** — `~/.config`, `~/.ssh`, `/run/agenix` 등 secret 경로 read는 허용된다. 따라서 Step 3.5 입력에는 sanitized excerpt만 전달하고, 자문 결과는 untrusted output으로 취급해 Step 4 anti-anchoring schema 검증을 거쳐야 한다.
- **`--ephemeral`**: 세션 영속화 안 함.
- **`-o`**: 마지막 모델 응답을 파일에 저장. **JSON 스키마 강제는 아니다** — `--output-schema` 별도 필요. 우리 흐름은 호출 후 `jq -e . < result.json`으로 파싱 검증, 실패 시 raw 옵션 fallback.
- **xhigh**: 명시적 심층 자문 요청 시에만 (`model_reasoning_effort="xhigh"`).

### 셸 호출 3 — 결과 검증 + 명시 cleanup (foreground)

```zsh
RESULT=/tmp/consult-<sid>-XXXXXX/result.json
if [ -s "$RESULT" ] && jq -e . < "$RESULT" >/dev/null 2>&1; then
  cat "$RESULT"  # 또는 jq로 필요한 필드만 추출
else
  echo "consulting-step: result invalid or empty — fallback to Step 3 raw options"
fi
rm -rf -- /tmp/consult-<sid>-XXXXXX
```

`trap` 사용 금지 — 셸 호출이 분리되어 있어 trap이 호출 1 종료 시점에 발동하면 호출 2 이전에 디렉토리가 삭제된다. 명시적 `rm -rf` 한 번이 정본.

## Background timing

- **호출 시점**: Step 3 종료 직후 background로 발사 (`run_in_background: true`).
- **메인 LLM이 그 사이 수행할 작업**:
  - Discovery Summary 정리.
  - Plan draft 초안 (변경 대상 파일 / 실행 순서 / 검증 surface).
  - Step 3에서 수집한 사용자 질문의 비-트레이드오프 항목(요구사항 명료화 등) 1차 점검.
- **결과 도착 시**: Step 4(또는 I-4 첫 라운드) 사용자 질문 제시. 자문 매트릭스를 입력으로 통합.
- **budget**: 1-3분 (high). 초과 시 (a) timeout 알림 후 자문 없이 Step 4 진행 + plan에 [UNVERIFIED] 라벨로 자문 부재 명시, 또는 (b) 사용자에게 대기 의사 확인.

## Anti-anchoring 4 규칙 (사용자 제시 단계에서 강제)

자문 결과를 `AskUserQuestion`(또는 등가 도구)으로 제시할 때 다음을 모두 적용:

1. **"(Recommended)" 라벨 금지** — `option.label`에 추천 표시 안 함. 자문 출력에 score/rank가 있어도 무시.
2. **옵션 순서 셔플 (decision_id 기반 stable)** — `decision_id`를 seed로 옵션 배열 순서를 결정적(deterministic)으로 셔플한다. 같은 `decision_id`를 다시 보여주면 같은 순서가 나온다 (재현성). 다른 `decision_id`이면 다른 순서 (primacy bias 분산). mapping(원본 ↔ 셔플)은 메인 LLM 내부 기록에 보존.
3. **disqualifier 표시** — 각 `option.description`에 "이 선택이 틀릴 수 있는 조건"을 함께 표기. 자문 출력의 `disqualifiers` 필드를 그대로 사용.
4. **judgment-first** — 트레이드오프 옵션 제시 직전 별도 질문으로 사용자 기준을 먼저 묻는다 (예: "이 결정에서 가장 중요한 기준은? (a) 구현 속도 (b) 운영 안정성 (c) 되돌리기 용이성 (d) 검증 가능성"). 그 다음 옵션 제시.

상세 메시지 패턴은 [`output-templates.md`](./output-templates.md#step-4--step-i-4-질문-패턴) 참조.

## Decision Log 기록

자문 결과로 사용자 선택이 바뀐 경우 plan 파일 Decision Log에 ADR 미니 기록:

```
## DL-N: <decision_id>
- Status: accepted
- Context: Step 3에서 메인 LLM이 옵션 A를 후보로 작성. Step 3.5 외부 자문에서 옵션 A의 disqualifier 발견.
- Decision: 옵션 B 채택.
- Consequences: <영향>
- External Consult: <자문 결과 요약 또는 result.json 경로>
```

## Validation (Phase 2 Exit Criteria 보조)

- dummy decision (옵션 A/B 2개) 1개로 Step 3.5 round-trip 1회 성공.
- 출력 JSON에 "Recommended" / "Best" / "Default" 라벨 부재 확인 (`rg`).
- 옵션 순서가 다른 `decision_id` 입력 2건에 대해 다름 / 같은 `decision_id` 재호출 시 동일 (decision_id-seeded stable shuffle 검증).
- 1-3분 내 결과 도착 (`time codex exec ...`).
- `--sandbox read-only`로 호출했을 때 file write 시도가 sandbox에서 차단됨 (negative test).
