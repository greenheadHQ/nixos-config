# Step 3.5 / Step I-3.5: 외부 LLM 기술 자문

Step 3 직후, 사용자에게 옵션을 제시하기 전(Step 4 직전)에 외부 LLM(`codex exec`)에 anchoring-neutral 옵션 평가를 위임한다. 목적은 사용자가 메인 LLM의 첫 추천에 anchor되어 이후 DA가 결함을 지적해도 재설계를 거부하는 패턴(`#490` 사례)을 차단하는 것이다.

## 적용 범위

- **for_action Step 3.5**: 트레이드오프 항목이 1개 이상이면 무조건 호출.
- **for_issue Step I-3.5**: 블랙박스 체크리스트 "C. 트레이드오프"에 1+ 항목이면 호출. 단순 요구사항 명료화 위주의 인터뷰는 skip.
- **for_prd**: `for_action`과 동일 — 트레이드오프 1+이면 호출. (자체 plan 사본이 없고 PRD를 `.claude/prds/`에 직접 작성하므로 Step 3.5 호출은 PRD 작성 전 한 번이며, phase별 반복은 적용되지 않는다.)

## Step 3.5는 Step 5 DA와 다르다

| 항목 | Step 3.5 (consulting) | Step 5 (DA) |
|------|----------------------|-------------|
| 시점 | 사용자 질문 **전** | 사용자 답변 **후** |
| 입력 | 옵션 후보 + evidence | for_action plan 파일 또는 for_prd PRD draft/context |
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

## 현 상황 적합성 컨텍스트

자문이 "어떤 옵션이 본 작업의 현 상황에 가장 적합한가"를 평가할 수 있도록, 결정의 가중치를 결정짓는 사실을 명시한다. 자문은 이 컨텍스트를 사용해 `user_facing` layer의 비유 톤과 `disqualifiers` 적용 강도를 조절한다.

- 시간 제약: {예: "이번 주 내 머지", "다음 분기 전 안정화" — 없으면 "없음"}
- 가역성 요구: {예: "1 commit revert 가능해야 함", "DB 마이그레이션은 forward-only 허용"}
- 위험 허용도: {예: "production 영향 없음 (스킬 문서)", "유저 데이터 경로 — 보수적"}
- 사용자 기능/영향 범위: {예: "단일 스킬 본문", "전 호스트 deploy 영향"}
- 기존 패턴 일치도: {예: "유사 결정 선례 N건 — 동일 패턴 우선", "신규 — 패턴 없음"}
- 기타 결정에 영향을 주는 현장 사실: {유연 자유 기재}

## Decision points (메인 LLM 추천 제외)
- decision_id: {식별자}
  decision_type: {tradeoff | requirement_interpretation | scope_boundary | ...}
  user_question: {사용자에게 물을 질문 원안}
  candidates:
    - id: {A/B/C}
      description: {중립 묘사 — "간단", "추천" 같은 표현 금지}

## 검증 surface (가용 도구)
{static / unit / integration / E2E / ... — `./validation-paths.md` catalog 인용}

## Non-goals
{명시적 비목표}
```

**제외할 입력**:
- 메인 LLM의 추천·선호 표현 ("A가 더 간단해 보임", "B를 권장").
- 사용자가 미이해 상태에서 수락한 선택은 `user-proposed candidate` 라벨로만 표시.
- "기본값", "default", "Recommended" 같은 anchor 단어.

## 출력 JSON schema (고정)

자문 출력은 두 layer로 분리한다 (D2 — 두 layer schema):

- **`technical_matrix`** (메인 LLM 내부 전용): 7키 평가 매트릭스. 사용자에게 절대 노출하지 않는다. 메인 LLM이 합의 알고리즘(아래 D4) 입력으로만 사용. 기존 `evaluation_matrix` 필드를 명시적으로 재명명한 것이며, 의미는 동일하다.
- **`user_facing`** (사용자 노출 전용): 비유 + 평이한 한국어 description + 평이 disqualifier. AskUserQuestion(또는 등가 도구)에 그대로 사용. 기술 용어 금지, 매트릭스 7키 노출 금지.

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
          "description": "<중립 1-2 문장 — 메인 LLM 내부 reference용>",
          "technical_matrix": {
            "요구충족": "<요약>",
            "구현비용": "<요약>",
            "되돌리기쉬움": "<요약>",
            "운영위험": "<요약>",
            "검증가능성": "<요약>",
            "주요unknown": "<요약>",
            "비용시간추정": "<범위 또는 [UNVERIFIED]>"
          },
          "user_facing": {
            "label": "<옵션을 한 줄로 표현하는 평이 라벨 — 기술 용어/약어 금지>",
            "description": "<2-4 문장. 일상 비유 적극 사용. 사용자가 도메인 모르더라도 트레이드오프 직관 가능하게>",
            "analogy": "<핵심 트레이드오프 1-2 문장 비유 — 영양/요리/교통/주방 등 도메인 무관 비유>",
            "plain_disqualifier": "<이 옵션이 틀릴 수 있는 조건을 평이한 한국어로 1 문장. 기술 용어 금지>"
          },
          "disqualifiers": ["<이 옵션이 틀릴 수 있는 조건 (technical)>", "..."],
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

### 1-shot dummy 예시

자문 프롬프트에 그대로 임베드 가능하다. 메인 LLM은 자문 호출 시 본 dummy를 prompt에 포함해 schema 형태를 강하게 anchoring한다.

```json
{
  "decisions": [
    {
      "decision_id": "dummy-cache-strategy",
      "decision_type": "tradeoff",
      "user_question": "API 응답 캐시 무효화 정책을 어떻게 할까?",
      "options": [
        {
          "id": "A",
          "description": "TTL 기반 시간 만료 — 60초 후 자동 폐기",
          "technical_matrix": {
            "요구충족": "stale 데이터 60초 허용 시 OK",
            "구현비용": "라이브러리 옵션 1줄",
            "되돌리기쉬움": "TTL 0으로 즉시 비활성화",
            "운영위험": "trafic spike 시 thundering herd",
            "검증가능성": "단위 테스트 가능",
            "주요unknown": "실제 트래픽 패턴",
            "비용시간추정": "0.5h"
          },
          "user_facing": {
            "label": "1분 지나면 새로 받기",
            "description": "냉장고에 음식 1분 두고 그대로 먹는 방식. 빠르고 단순하지만, 60초 사이 누가 음식을 바꿔도 모른다.",
            "analogy": "1분짜리 모래시계 — 다 떨어지면 새로 받아온다",
            "plain_disqualifier": "데이터가 60초 안에 자주 바뀌고, 사용자가 그 변화를 즉시 봐야 한다면 부적합"
          },
          "disqualifiers": ["high-frequency mutation 케이스에서 stale window 허용 불가"],
          "evidence_gaps": ["실제 트래픽 mutation 빈도 미측정"]
        },
        {
          "id": "B",
          "description": "쓰기 발생 시 명시적 invalidate — event-driven",
          "technical_matrix": {
            "요구충족": "stale 0초 보장",
            "구현비용": "쓰기 경로마다 invalidate hook 추가",
            "되돌리기쉬움": "hook 제거로 비활성화 — 코드 분산",
            "운영위험": "invalidate 누락 시 영구 stale",
            "검증가능성": "통합 테스트 필요",
            "주요unknown": "쓰기 경로 누락 가능성",
            "비용시간추정": "3-5h"
          },
          "user_facing": {
            "label": "바뀔 때마다 즉시 갱신",
            "description": "음식이 바뀔 때 누가 알려주면 바로 새로 받는 방식. 항상 최신이지만, 알리는 사람이 한 명이라도 빠뜨리면 영원히 옛날 음식을 먹게 된다.",
            "analogy": "주방장이 메뉴 바꾸면 종업원이 모든 손님 테이블 돌며 알리는 방식",
            "plain_disqualifier": "쓰기 경로가 여러 곳에 흩어져 있고 누락 검증이 어렵다면 부적합"
          },
          "disqualifiers": ["쓰기 경로 발견되지 않은 entry point 존재 시 silent stale"],
          "evidence_gaps": ["전체 쓰기 경로 enumeration 미완료"]
        }
      ],
      "validation_needed": "통합 테스트 + 트래픽 분석",
      "ask_user_only_if": "stale 허용 윈도우와 invalidate 누락 위험 중 어느 쪽이 더 큰 비용인가",
      "can_agent_decide_if": "쓰기 경로 enumeration이 1 commit으로 완결되고 stale 허용 0 요구가 명시되어 있으면 B 자동 선택 가능"
    }
  ]
}
```

**금지** (메인 LLM은 codex 출력에서 이 필드들이 발견되면 무시 — anchoring 위험):
- 점수 합산, 순위, "Best", "Default" 라벨.
- "Recommended" 라벨 — 자문 출력에 절대 포함되지 않는다. 라벨 부착은 메인 LLM의 D4 합의 알고리즘이 사용자 노출 직전에만 수행한다 (Anti-anchoring 1번 규칙 참조).
- 옵션 description에 추천/우열 암시 표현 (`option.description` top-level과 `user_facing.description` 양쪽 모두 — `technical_matrix`는 7개 평가 키만 가지며 description 필드는 없다).
- Score 필드, ranking 필드.
- `chosen_*`, `selected_*`, `recommended_*`, `winner` 같은 implicit choice 필드 (codex가 자체 추가한 경우도 무시).
- `rationale` 필드를 단일 옵션 정당화로 사용 — `disqualifiers`/`evidence_gaps`만 표시 가능.

명백히 불가능한 옵션은 출력 단계에서 제외하지 않고 `disqualifiers`로 표시한다 (사용자가 "왜 이게 빠졌는지" 추측하지 않도록).

**프롬프트 정밀화**: 호출자는 "출력 JSON schema를 반환하라"가 아니라 "**위 schema에 맞는 JSON instance를 반환하라. schema definition은 출력하지 마라**"라고 명시한다. 1-shot dummy 예시(위 `dummy-cache-strategy`)를 프롬프트에 항상 포함한다 — 두 layer schema에서 `user_facing` 누락 위험을 줄이기 위함.

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
[ -d "$CONSULT_DIR" ] || { echo "consulting-step: missing CONSULT_DIR=$CONSULT_DIR"; exit 1; }

# Untrusted input 보호: 메인 에이전트는 프롬프트를 셸 heredoc에 직접 삽입하지 말고
# 파일 편집 도구(Write/Edit)로 "$CONSULT_DIR/prompt.md"에 작성한다. 이슈 본문/외부 입력에
# 단독 PROMPT 라인이 있으면 heredoc이 조기 종료되어 부모 shell에서 임의 명령이 실행될 수 있다.
# 따라서 heredoc 패턴은 사용하지 않고, 별도 파일 쓰기 도구로 prompt.md를 만든다.

echo "CONSULT_DIR=$CONSULT_DIR"
```

메인 에이전트는 stdout의 `CONSULT_DIR` 리터럴 값을 후속 호출에서 재사용한다 (Bash tool 호출 간 변수 비공유).

> **literal 재사용 환각 주의 (issue #632)**: 이 3-call flow는 출력된 `CONSULT_DIR` 리터럴과 dir/file guard를 유지한다. Generic rule은 [`using-codex-exec/known-issues.md`](../../using-codex-exec/references/known-issues.md#literal-재사용-시-random-suffix-환각-금지-issue-632)를 따른다.

### 셸 호출 2 — codex exec 실행 (background, supervised wrapper)

```zsh
# 위 CONSULT_DIR 리터럴 값을 그대로 사용. supervised wrapper가 setsid + timeout으로
# process group kill을 보장한다 (issue #593, known-issues.md §15).
# CODEX_EXEC_TIMEOUT_SECONDS=1800으로 wrapper default와 동일한 30분 budget 적용 (consult-specific 단축 override 폐지 — 측정 누적 후 재평가 대상).
CONSULT_DIR=/tmp/consult-c4a35fc4-AbCdEf
[ -d "$CONSULT_DIR" ] || { echo "consulting-step: missing CONSULT_DIR=$CONSULT_DIR"; exit 1; }
[ -f "$CONSULT_DIR/prompt.md" ] || { echo "consulting-step: missing prompt=$CONSULT_DIR/prompt.md"; exit 1; }
CODEX_EXEC_TIMEOUT_SECONDS=1800 env CODEX_PROGRAMMATIC=1 codex-exec-supervised \
    -C "$CONSULT_DIR" \
    --skip-git-repo-check \
    --ignore-user-config \
    --ignore-rules \
    --sandbox read-only --ephemeral \
    -c model="gpt-5.5" \
    -c model_reasoning_effort="high" \
    -o "$CONSULT_DIR/result.json" \
    - \
    < "$CONSULT_DIR/prompt.md" \
    2>"$CONSULT_DIR/stderr.log"
```

- **`codex-exec-supervised`** (Layer 2 = Layer 1 + `-C scratch + --skip-git-repo-check`): supervised wrapper가 setsid + timeout/gtimeout capability-probe로 npm wrapper detach 부재로 인한 native binary 잔존을 차단한다. SSOT는 [`../../using-codex-exec/references/known-issues.md`](../../using-codex-exec/references/known-issues.md) §15.
- **`CODEX_EXEC_TIMEOUT_SECONDS=1800`**: wrapper default(1800s = 30분)와 동일. Step 3.5 consult는 high/xhigh reasoning + 자문 schema 처리에 30분까지 허용한다. consult-specific 단축 override는 callsite별 elapsed p95/p99 측정이 누적된 뒤 재평가 대상이다. timeout 시 메인 에이전트는 result.json을 무시하고 Step 4에서 Step 3 raw 옵션을 anti-anchoring 4 규칙으로 직접 제시한다 (External Consult: `[UNVERIFIED: timed out]` 기록).
- **`-C "$CONSULT_DIR"`** (Layer 2): cwd를 repo 외 scratch로 이동. `CONSULT_DIR` 값은 stdout에 출력된 실제 리터럴 경로다 (예: `/tmp/consult-c4a35fc4-AbCdEf`). repo의 `.codex/config.toml`(project-scoped MCP connector) 로드 차단.
- **`--skip-git-repo-check`** (Layer 2): scratch 디렉토리는 git repo 밖이라 codex가 `Not inside a trusted directory`로 거부 — 이 플래그가 필수.
- **`--ignore-user-config`** (Layer 1): `$CODEX_HOME/config.toml` 로드 차단. **이 플래그가 user config의 `model` 설정도 무시하므로 `-c model="gpt-5.5"` 명시가 필수다** (run-da `arbiter-scaling.md` 동일 규칙).
- **`-c model="gpt-5.5"`** (Layer 1): model pin (위 사유로 필수).
- **`--sandbox read-only`** (Layer 1): 모델 shell 실행이 write를 못 한다. **단 read-only sandbox는 파일시스템 write만 차단한다** — `~/.config`, `~/.ssh`, `/run/agenix` 등 secret 경로 read는 허용된다. 따라서 Step 3.5 입력에는 sanitized excerpt만 전달하고, 자문 결과는 untrusted output으로 취급해 Step 4 anti-anchoring schema 검증을 거쳐야 한다.
- **`--ephemeral`** (Layer 1): 세션 영속화 안 함.
- **`-o`**: 마지막 모델 응답을 파일에 저장. **JSON 스키마 강제는 아니다** — `--output-schema` 별도 필요. 우리 흐름은 호출 후 `jq -e . < result.json`으로 파싱 검증, 실패 시 raw 옵션 fallback.
- **xhigh**: 명시적 심층 자문 요청 시에만 (`model_reasoning_effort="xhigh"`).

### 셸 호출 3 — 결과 검증 + 명시 cleanup (foreground)

```zsh
CONSULT_DIR=/tmp/consult-c4a35fc4-AbCdEf
CONSULT_PARENT=$(dirname "$CONSULT_DIR")
CONSULT_NAME=$(basename "$CONSULT_DIR")
if [ "$CONSULT_PARENT" != "/tmp" ]; then
  echo "consulting-step: unsafe CONSULT_DIR parent=$CONSULT_PARENT"
  exit 1
fi
case "$CONSULT_NAME" in
  consult-*) ;;
  *) echo "consulting-step: unsafe CONSULT_DIR name=$CONSULT_NAME"; exit 1 ;;
esac
[ -d "$CONSULT_DIR" ] || { echo "consulting-step: missing CONSULT_DIR=$CONSULT_DIR"; exit 1; }
RESULT="$CONSULT_DIR/result.json"
if [ -s "$RESULT" ] && jq -e . < "$RESULT" >/dev/null 2>&1; then
  # D4 합의 알고리즘 Step 2 — schema-level 검증
  # 한국어 키는 jq dot 접근에서 INVALID_CHARACTER로 compile fail하므로 quoted key + has()로 검증한다 (jq 1.8 검증).
  # option 단위 boolean을 array로 모은 뒤 length>0 + all()로 평가하여, jq -e가 마지막 출력 기준으로 partial PASS되는 함정을 방지한다.
  if jq -e '
    [
      .decisions[]?.options[]? as $opt | (
        ($opt.technical_matrix | type == "object") and
        ($opt.technical_matrix | has("요구충족")) and
        ($opt.technical_matrix | has("구현비용")) and
        ($opt.technical_matrix | has("되돌리기쉬움")) and
        ($opt.technical_matrix | has("운영위험")) and
        ($opt.technical_matrix | has("검증가능성")) and
        ($opt.technical_matrix | has("주요unknown")) and
        ($opt.technical_matrix | has("비용시간추정")) and
        (($opt.disqualifiers // null) | type == "array") and
        (($opt.evidence_gaps // null) | type == "array") and
        ($opt.user_facing | type == "object") and
        ($opt.user_facing | has("label")) and
        ($opt.user_facing | has("description")) and
        ($opt.user_facing | has("analogy")) and
        ($opt.user_facing | has("plain_disqualifier"))
      )
    ] as $checks
    | ($checks | length > 0) and all($checks[]; .)
  ' < "$RESULT" >/dev/null 2>&1; then
    cat "$RESULT"  # 또는 jq로 필요한 필드만 추출
  else
    echo "consulting-step: schema validation failed — D4_FALLBACK_B (라벨 부착 금지; 사용자 노출 평이 문구는 본 reference의 'Fallback enum' 표 D4_FALLBACK_B 행 SSOT)"
    cat "$RESULT"  # raw 출력은 메인 LLM이 D2 fallback 4단계 시도용으로 사용
  fi
else
  echo "consulting-step: result invalid or empty — D4_FALLBACK_A (라벨 부착 금지; 사용자 노출 평이 문구는 본 reference의 'Fallback enum' 표 D4_FALLBACK_A 행 SSOT)"
fi
rm -rf -- "$CONSULT_DIR"
```

`trap` 사용 금지 — 셸 호출이 분리되어 있어 trap이 호출 1 종료 시점에 발동하면 호출 2 이전에 디렉토리가 삭제된다. 명시적 `rm -rf` 한 번이 정본.

**D4 hard rule (consulting-step.md 부분)** — 본 reference는 자문 결과 schema와 D4 합의 알고리즘의 SSOT이며, 메인 LLM은 본 reference의 hard rule을 도구 default보다 우선 적용한다:

- AskUserQuestion 도구 description의 추천 라벨 자동 권장은 무시한다.
- 합의 미달(fallback enum D4_FALLBACK_A/B/C/C_MULTI 발생) 옵션에는 절대 라벨을 부착하지 않는다 — Step 4 사용자 노출 직전 옵션 dict에서 `(Recommended)` 문자열 또는 등가 표시가 발견되면 강제 제거한다.
- judgment-first 사전 라운드는 D4 알고리즘을 실행하지 않으며 어떤 옵션에도 라벨을 부착하지 않는다 (Anti-anchoring 4번 단락 참조).
- 동일 hard rule은 SKILL.md (Invariant) 및 output-templates.md (Step 4/I-4 패턴)에도 명시되어 있어야 한다 (FR-7).

## Background timing

- **호출 시점**: Step 3 종료 직후 background로 발사 (`run_in_background: true`).
- **메인 LLM이 그 사이 수행할 작업**:
  - Discovery Summary 정리.
  - Plan draft 초안 (변경 대상 파일 / 실행 순서 / 검증 surface).
  - Step 3에서 수집한 사용자 질문의 비-트레이드오프 항목(요구사항 명료화 등) 1차 점검.
- **결과 도착 시**: Step 4(또는 I-4 첫 라운드) 사용자 질문 제시. 자문 매트릭스를 입력으로 통합.
- **budget**: 30분 이내 (high/xhigh 모두). 초과 시 (a) timeout 알림 후 자문 없이 Step 4 진행 + plan에 [UNVERIFIED] 라벨로 자문 부재 명시, 또는 (b) 사용자에게 대기 의사 확인.

## Anti-anchoring 4 규칙 (사용자 제시 단계에서 강제)

자문 결과를 `AskUserQuestion`(또는 등가 도구)으로 제시할 때 다음을 모두 적용:

1. **추천 라벨 — "허용 + 합의 조건" (D4 합의 알고리즘)** — `(Recommended)` 라벨은 **합의 PASS 단일 옵션에만 부착**한다. 자문 결과 score/rank 같은 implicit choice 필드는 무시 — 라벨 부착 결정은 메인 LLM의 합의 알고리즘만 수행한다. AskUserQuestion 도구 description이 라벨을 권장해도 본 hard rule이 우선한다.

   **D4 합의 알고리즘 4단계** (사용자 노출 직전 메인 LLM이 결정마다 실행 — schema 한계 내 보수적 합의 정의):

   ```text
   Step 1. Step 3.5 Codex 자문 정상 종료 + result.json valid?
       - NO → D4_FALLBACK_A: 라벨 부착 금지 + 사용자 노출은 아래 "Fallback enum" 표 D4_FALLBACK_A 행 평이 문구 SSOT
   Step 2. technical_matrix schema 검증 (7키 + disqualifiers + evidence_gaps + user_facing 모두 존재 + 타입 일치)?
       - FAIL → fallback B: 라벨 부착 금지 + 사용자에게 schema 위반 평이 보고
   Step 3. 후보 필터 — 자문이 부여한 disqualifier 0개 + evidence_gaps ≤ 1개를 만족하는 옵션 집합 생성:
       - 후보 0개 → fallback C: 라벨 부착 금지 + 사용자에게 평이 보고 ("자문이 모든 옵션에 disqualifier 또는 evidence_gaps를 부여 — 추천 후보 없음")
       - 후보 1개 → Step 4로 진행
       - 후보 2+ → fallback C-multi: 라벨 부착 금지 + 후보 옵션들을 user_facing layer로 모두 사용자에게 표시. 메인 LLM이 "현 상황 적합성 컨텍스트"(시간 제약/가역성/위험 허용도/영향 범위/기존 패턴 일치도)로 한 옵션에 대한 tentative 선호를 *별도로* 평이하게 표명할 수 있으나 (Recommended) 라벨은 부착하지 않는다 (schema에 자문 추천 신호 필드가 없어 메인 LLM 단독 선택을 "합의"로 라벨링하지 않는 보수적 정책 — 정합 강화는 future schema extension의 추천/반대 신호 필드 + 메인 LLM 후보와의 일치 검증으로 가능)
   Step 4. 합의 PASS — Step 3에서 후보가 정확히 1개로 좁혀진 경우에만 도달. 그 옵션에 (Recommended) 라벨 부착 + Decision Log에 합의 단계별 evidence 기록 (자문 disqualifier 0 + evidence_gaps ≤ 1 + 메인 LLM이 동일 후보에 대해 별다른 disqualifier 발견 없음 확인)
   ```

   본 4단계는 first-match가 아닌 단계 순차 진행이다. 라벨 부착의 의미는 "자문이 schema 한계 안에서 부여한 신호와 메인 LLM 평가가 동일 단일 옵션을 가리킨다"이며, 이는 schema에 추천/반대 신호 필드가 없는 현 단계에서 schema 한계 내 가장 보수적인 합의 정의다. fallback C-multi(후보 2+)는 라벨 없이 사용자가 직접 선택하는 케이스로, 라벨 부착이 무리한 추론이 되는 영역을 명확히 분리한다.

   **합의 미달 옵션에 라벨 부착 절대 금지**는 본 reference의 hard rule이며, SKILL.md/output-templates.md 양쪽에 동일 hard rule이 명시되어 있어야 한다 (FR-7).
2. **옵션 순서 셔플 (decision_id 기반 stable)** — `decision_id`를 seed로 옵션 배열 순서를 결정적(deterministic)으로 셔플한다. 같은 `decision_id`를 다시 보여주면 같은 순서가 나온다 (재현성). 다른 `decision_id`이면 다른 순서 (primacy bias 분산). mapping(원본 ↔ 셔플)은 메인 LLM 내부 기록에 보존.
3. **disqualifier 표시** — 각 옵션의 사용자 노출 description에 "이 선택이 틀릴 수 있는 조건"을 함께 표기. 자문 출력의 `user_facing.plain_disqualifier`를 그대로 사용 (technical `disqualifiers`는 메인 LLM 내부 기록 전용). 평이 disqualifier 누락 시 D2 fallback 4단계(아래) 적용.
4. **judgment-first** — 트레이드오프 옵션 제시 직전 별도 질문으로 사용자 기준을 먼저 묻는다 (예: "이 결정에서 가장 중요한 기준은? (a) 구현 속도 (b) 운영 안정성 (c) 되돌리기 용이성 (d) 검증 가능성"). 그 다음 옵션 제시.

   **judgment-first 라운드 라벨 부착 절대 금지**: 기준 선택 라운드는 사용자가 *옵션 보기 전에* 추상 기준을 고르는 단계다. 여기에 `(Recommended)` 라벨이 부착되면 anti-anchoring 효과가 source에서부터 무력화된다. 따라서 judgment-first 라운드는 D4 합의 알고리즘을 **실행하지 않으며**, `user_facing.label`만 사용해 기준을 평이하게 표시한다. 본 금지는 `decision_type`이 `tradeoff`인 결정의 judgment-first 사전 라운드에 무조건 적용된다 (자문 출력의 합의 결과와 무관).

상세 메시지 패턴은 [`output-templates.md`](./output-templates.md#step-4--step-i-4-질문-패턴) 참조.

## D2 backward-compat fallback 4단계 (user_facing 누락 시)

자문 출력에 `user_facing` layer가 누락(또는 부분 누락)된 경우 메인 LLM은 graceful degrade로 다음 4단계를 순서대로 시도한다. 어느 단계에서든 사용자 노출 텍스트가 만들어지면 거기서 멈추고 사용자에게 표시한다. **D2 fallback은 D4 Step 2(schema 검증) fail 후의 텍스트 복구 시도이며, D2 fallback이 텍스트를 만들어내도 라벨은 부착하지 않는다** (D4 Step 2가 이미 fallback B로 격하됐으므로). 본 stage 표는 D2 텍스트 복구 흐름이며, 옆의 D4 fallback 표(아래)와는 별개 시스템이다.

```text
Stage 1. legacy 필드명 호환 (technical_matrix 우선, 없으면 evaluation_matrix)
    - 새 schema 출력은 technical_matrix.요구충족을 평이 한국어로 풀고 disqualifiers 첫 항목을 plain_disqualifier로 변환한다.
    - legacy 출력(`evaluation_matrix`만 있는 사본)이면 evaluation_matrix.요구충족을 동일 변환 대상으로 사용한다.
    - 둘 다 부재 → Stage 2.
    - 텍스트 생성 성공 → D2 텍스트 복구 OK (D4 라벨 결정과는 별개로 D4는 Step 2 fail로 fallback B 유지).

Stage 2. generic 비유 적용
    - Stage 1 텍스트가 여전히 기술 용어 위주이면 도메인 무관 비유(요리/교통/주방)로 유추 description 생성.
    - 텍스트 생성 성공 → D2 텍스트 복구 OK.

Stage 3. 메인 LLM 자체 작성 (내부 enum: D2_FALLBACK_USER_FACING)
    - Stage 1/2 모두 실패 → 메인 LLM이 description/analogy/plain_disqualifier 3 필드를 자체 생성.
    - 내부 Decision Log에 D2_FALLBACK_USER_FACING enum 기록 (감사 흔적).
    - 사용자 노출은 fallback enum 표(아래)의 D2_FALLBACK_USER_FACING 행 평이 한국어 문구만 사용 — enum 라벨 자체는 사용자에게 노출하지 않는다 (정상 user_facing layer 의무와 fallback 경로 사용자 노출 정책 일관 유지).

Stage 4. 위 모두 실패 → D4_FALLBACK_A 동등 처리
    - 자문 user_facing이 사용 불가능한 채로 결정 진행 불가 → D4_FALLBACK_A와 동등하게 처리 (사용자 노출 평이 문구는 아래 "Fallback enum" 표 D4_FALLBACK_A 행 SSOT 사용).
```

### Fallback enum (내부 Decision Log 전용, 사용자 노출 금지)

Fallback enum 라벨은 내부 Decision Log 기록과 검증용으로만 사용한다. **사용자에게는 enum 라벨 자체를 노출하지 않는다** — 사용자에게는 평이한 한국어 문구만 보여 user_facing layer 외 기술 taxonomy 노출을 차단한다 (정상 경로의 user_facing 의무와 fallback 경로의 사용자 노출 정책 일관 유지).

| 내부 enum (Decision Log) | D4 단계 / D2 stage | 사용자 노출 평이 문구 (예시) |
|---|---|---|
| `D4_FALLBACK_A` | D4 Step 1 — 자문 timeout 또는 result.json invalid | "자문이 완료되지 못했어요. 추천 없이 옵션을 그대로 보여드릴게요." |
| `D4_FALLBACK_B` | D4 Step 2 — schema 검증 fail (7키 + disqualifiers + evidence_gaps + user_facing) | "자문 결과 형식이 맞지 않아 평이 설명만 복구했어요. 추천 없이 비교만 보여드릴게요." |
| `D4_FALLBACK_C` | D4 Step 3 — disqualifier 0 + evidence_gaps ≤ 1 후보 0개 | "각 옵션에 미해결 사항이 남아 있어 추천을 정할 수 없어요. 옵션을 그대로 보여드릴게요." |
| `D4_FALLBACK_C_MULTI` | D4 Step 3 — 후보 2+ (schema 한계 내 보수적 합의 정의 미달) | "두 옵션 모두 후보로 남아요. (선택적) 메인 LLM tentative 선호: 옵션 X (가중치 근거: ...)" |
| `D2_FALLBACK_USER_FACING` | D2 Stage 3 — user_facing layer 누락으로 메인 LLM 자체 작성 | "옵션 설명을 메인 LLM이 평이하게 다시 풀어 썼어요." (텍스트 출처 표기일 뿐, D4 라벨 부착과는 별개 축) |

내부 enum은 다음 두 출처에만 등장한다:
1. Decision Log의 External Consult 필드 (감사용 — verdict 흐름 기록).
2. 본 reference + bias-measurement.md baseline 검증 (정책 일관성 확인용).

사용자 노출 메시지는 평이 한국어 문구만 사용하며, 내부 enum 라벨은 노출하지 않는다 (모든 fallback 메시지가 정상 user_facing layer와 동일한 톤을 유지하도록).

### 후보 다수 케이스의 사용자 노출 패턴

후보가 2+ (D4_FALLBACK_C_MULTI)인 케이스는 사용자에게 두 옵션 모두 user_facing layer로 표시한다. 메인 LLM은 "현 상황 적합성 컨텍스트" 가중치로 도출한 tentative 선호를 *별도 단락*으로 평이하게 표명할 수 있다 — 단 어떤 옵션에도 `(Recommended)` 라벨을 부착하지 않는다 (schema 한계 내 보수적 합의 정의가 라벨 의미를 보장한다).

## Decision Log 기록

자문 결과로 사용자 선택이 바뀐 경우 기록 target은 모드별로 다르다:

- **for_action**: plan 파일 `Decision Log`에 ADR 미니 기록.
- **for_prd**: PRD draft/context에 기록하고, PRD 작성 후 master `Change Log`와 특정 phase가 영향받는 경우 phase `Discoveries / Decisions`에 이관.

**Durable output에 임시 dir path 기록 금지 (회귀 방지)**: 셸 호출 사이에 `CONSULT_DIR` 리터럴 값을 재사용하는 것은 runtime 요구사항이지만, plan/PRD/PR/issue/comment 같은 durable output에는 `/tmp/consult-XXXXXXXX-YYYYYY/result.json` 같은 임시 경로 리터럴을 박지 않는다. 임시 경로는 세션 종료 시 사라지는 ephemeral identifier이며, dir suffix의 hex 토큰이 `pinning-guard.sh` PATTERN_D에 의해 차단된다(라벨: "짧은 임시 hex 식별자 박제"). durable output에는 자문 회차 자연어 요약(예: "1차 자문(전체 N결정)")·`decision_id` list·verdict 요약만 기록한다.

**스코프**: 본 금지는 _agent가 이번 작업으로 새로 생성하는_ generated plan/PRD/PR/issue/comment에만 적용된다. 본 reference 문서 자체의 셸 호출 예시(아래 셸 호출 1/2/3 코드블록의 placeholder hex 값)는 runtime 동작을 가르치는 SSOT 가이드이므로 정책 적용 대상이 아니다 — durable output 차단은 *새 박제 추가*에만 작동하며 기존 SSOT 예시는 보존된다.

for_action 기록 형식:

```
## DL-N: <decision_id>
- Status: accepted
- Context: Step 3에서 메인 LLM이 옵션 A를 후보로 작성. Step 3.5 외부 자문에서 옵션 A의 disqualifier 발견.
- Decision: 옵션 B 채택.
- Consequences: <영향>
- External Consult: <자문 회차 자연어 요약 + decision_id list + verdict 요약. result.json 같은 임시 경로 리터럴 박제 금지.>
```

## Validation (Phase 2 Exit Criteria 보조)

- dummy decision (옵션 A/B 2개) 1개로 Step 3.5 round-trip 1회 성공.
- 출력 JSON에 "Recommended" / "Best" / "Default" 라벨 부재 확인 (`rg`).
- 옵션 순서가 다른 `decision_id` 입력 2건에 대해 다름 / 같은 `decision_id` 재호출 시 동일 (decision_id-seeded stable shuffle 검증).
- 30분 이내 결과 도착 (`time codex exec ...`).
- `--sandbox read-only`로 호출했을 때 file write 시도가 sandbox에서 차단됨 (negative test).
