# Step 3.5 codex exec 호출 명령 SSOT

본 reference는 Step 3.5 (또는 Step I-3.5, for_prd의 P4) 에서 외부 LLM 자문을 위해 호출하는 `codex exec` 명령의 단일 SSOT 다.

SKILL.md, modes/for_action.md, modes/for_issue.md, modes/for_prd.md, references/consulting-step.md는 본 파일을 link만 하고 명령을 복제하지 않는다.

## 관련 SSOT

- 자문 단계의 목적, 입력 schema, 출력 JSON schema, anti-anchoring 4 규칙, 추천 라벨 합의 알고리즘, fallback enum의 단일 SSOT는 [`consulting-step.md`](./consulting-step.md) 다.
- supervised wrapper (`codex-exec-supervised`) 의 setsid + timeout 동작 SSOT는 [`../../using-codex-exec/references/known-issues.md`](../../using-codex-exec/references/known-issues.md) 의 §15 다.

## 호출 패턴: 3 셸 호출 분리

호출 패턴은 3 셸 호출로 분리한다. 같은 셸 안에서 heredoc 작성과 `codex exec` 를 background로 체이닝하면 stdin EOF / heredoc 종료 경합으로 hang이 발생한다 ([`../../using-codex-exec/references/known-issues.md`](../../using-codex-exec/references/known-issues.md) 명시 패턴).

또한 `trap ... EXIT` 는 각 셸 종료 시 즉시 발동하므로 multi-shell 흐름에서 `result.json` 이 읽히기 전에 삭제된다. trap 사용 금지, 명시 cleanup만 사용한다.

### 셸 호출 1: 디렉토리 + prompt 파일 생성 (foreground)

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
# 파일 편집 도구 (Write / Edit) 로 "$CONSULT_DIR/prompt.md" 에 작성한다.
# 이슈 본문이나 외부 입력에 단독 PROMPT 라인이 있으면 heredoc이 조기 종료되어
# 부모 shell에서 임의 명령이 실행될 수 있다. 따라서 heredoc 패턴은 사용하지 않고
# 별도 파일 쓰기 도구로 prompt.md를 만든다.

echo "CONSULT_DIR=$CONSULT_DIR"
```

메인 에이전트는 stdout의 `CONSULT_DIR` 리터럴 값을 후속 호출에서 재사용한다 (Bash tool 호출 간 변수 비공유).

literal 재사용 환각 주의 (issue #632): 이 3-call flow는 출력된 `CONSULT_DIR` 리터럴과 dir / file guard를 유지한다. Generic rule의 단일 SSOT는 [`../../using-codex-exec/references/known-issues.md`](../../using-codex-exec/references/known-issues.md#literal-재사용-시-random-suffix-환각-금지-issue-632) 다.

### 셸 호출 2: codex exec 실행 (background, supervised wrapper)

Background 실행 계약: 아래 명령 자체에는 `&` 를 붙이지 않는다. 호출자는 지원 런타임의 background 실행 옵션 (예: Claude Code Bash tool의 `run_in_background: true`) 으로 본 명령을 띄우고, 메인 에이전트가 Step 3.5 결과 도착까지 다른 작업을 병렬 진행한다. 셸 수준 `&` chain은 stdin EOF / heredoc 종료 경합으로 hang을 만들 수 있으므로 금지한다 ([`../../using-codex-exec/references/known-issues.md`](../../using-codex-exec/references/known-issues.md) 참조).


```zsh
# 위 CONSULT_DIR 리터럴 값을 그대로 사용. supervised wrapper가 setsid + timeout 으로
# process group kill을 보장한다 (issue #593, known-issues.md §15).
# CODEX_EXEC_TIMEOUT_SECONDS=1800 으로 wrapper default와 동일한 30분 budget 적용한다.
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

플래그별 역할:

- `codex-exec-supervised` (Layer 2 = Layer 1 + `-C scratch` + `--skip-git-repo-check`) — supervised wrapper가 setsid + timeout 또는 gtimeout capability-probe로 npm wrapper detach 부재로 인한 native binary 잔존을 차단한다. 단일 SSOT는 [`../../using-codex-exec/references/known-issues.md`](../../using-codex-exec/references/known-issues.md) 의 §15 다.
- `CODEX_EXEC_TIMEOUT_SECONDS=1800`: wrapper default (1800s = 30분) 와 동일하다. Step 3.5 의 consult는 high 또는 xhigh reasoning과 자문 schema 처리에 30분까지 허용한다. consult-specific 단축 override는 callsite 별 elapsed p95 또는 p99 측정이 누적된 뒤 재평가 대상이다. timeout 시 메인 에이전트는 `result.json` 을 무시하고 Step 4 에서 Step 3 의 raw 옵션을 anti-anchoring 4 규칙으로 직접 제시한다 (External Consult: `[UNVERIFIED: timed out]` 기록).
- `-C "$CONSULT_DIR"` (Layer 2) — cwd를 repo 외 scratch로 이동한다. `CONSULT_DIR` 값은 stdout에 출력된 실제 리터럴 경로다 (예: `/tmp/consult-c4a35fc4-AbCdEf`). repo의 `.codex/config.toml` (project-scoped MCP connector) 로드를 차단한다.
- `--skip-git-repo-check` (Layer 2) — scratch 디렉토리는 git repo 밖이라 codex가 `Not inside a trusted directory` 로 거부한다. 이 플래그가 필수다.
- `--ignore-user-config` (Layer 1) — `$CODEX_HOME/config.toml` 로드를 차단한다. 이 플래그가 user config의 `model` 설정도 무시하므로 `-c model="gpt-5.5"` 명시가 필수다 (run-da의 `arbiter-scaling.md` 와 동일 규칙).
- `-c model="gpt-5.5"` (Layer 1) — model pin (위 사유로 필수).
- `--sandbox read-only` (Layer 1) — 모델 shell 실행이 write를 못 한다. 단 read-only sandbox는 파일시스템 write만 차단한다: `~/.config`, `~/.ssh`, `/run/agenix` 등 secret 경로 read는 허용된다. 따라서 Step 3.5 입력에는 sanitized excerpt만 전달하고, 자문 결과는 untrusted output으로 취급하여 Step 4 의 anti-anchoring schema 검증을 거쳐야 한다.
- `--ephemeral` (Layer 1) — 세션 영속화를 하지 않는다.
- `-o`: 마지막 모델 응답을 파일에 저장한다. JSON 스키마 강제는 아니다: `--output-schema` 가 별도로 필요하다. 우리 흐름은 호출 후 `jq -e . < result.json` 으로 파싱 검증하고, 실패 시 raw 옵션 fallback으로 진행한다.
- xhigh: 명시적 심층 자문 요청 시에만 사용한다 (`model_reasoning_effort="xhigh"`).

### 셸 호출 3: 결과 검증 + 명시 cleanup (foreground)

Schema 키 set의 executable validator mirror: 아래 셸 호출 3 의 `jq -e` 검증은 schema의 7개 `technical_matrix` 키 (`요구충족`, `구현비용`, `되돌리기쉬움`, `운영위험`, `검증가능성`, `주요unknown`, `비용시간추정`) 와 `disqualifiers`, `evidence_gaps`, `user_facing` 4 필드 (`label`, `description`, `analogy`, `plain_disqualifier`) 를 하드코딩한다.

schema 정의의 단일 SSOT는 [`consulting-step.md`](./consulting-step.md) 의 출력 JSON schema 섹션이며, 본 jq 스니펫은 그 schema의 executable mirror 다 (SSOT 자체가 아니라 mirror 책임). schema 정의가 변경되면 본 mirror도 함께 갱신해야 한다 (manual sync contract). 자동 검증 강화는 별도 follow-up (예: `verify-ai-compat.sh`에 schema key set drift 검증 추가).


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
  # 추천 라벨 합의 알고리즘 Step 2 — schema-level 검증
  # 한국어 키는 jq dot 접근에서 INVALID_CHARACTER로 compile fail 하므로
  # quoted key + has() 로 검증한다 (jq 1.8 검증).
  # option 단위 boolean을 array로 모은 뒤 length>0 + all() 로 평가하여,
  # jq -e가 마지막 출력 기준으로 partial PASS 되는 함정을 방지한다.
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
    echo "consulting-step: schema validation failed — D4_FALLBACK_B (라벨 부착 금지)"
    cat "$RESULT"  # raw 출력은 메인 LLM이 텍스트 복구 4단계 시도용으로 사용
  fi
else
  echo "consulting-step: result invalid or empty — D4_FALLBACK_A (라벨 부착 금지)"
fi
rm -rf -- "$CONSULT_DIR"
```

fallback 사용자 노출 평이 문구의 단일 SSOT는 [`consulting-step.md`](./consulting-step.md#fallback-enum-내부-decision-log-전용-사용자-노출-금지) 의 "Fallback enum" 표다. 위 echo 메시지의 식별자 (`D4_FALLBACK_A`, `D4_FALLBACK_B`) 는 내부 Decision Log 용이며 사용자에게 노출하지 않는다.

`trap` 사용 금지: 셸 호출이 분리되어 있어 trap이 호출 1 종료 시점에 발동하면 호출 2 이전에 디렉토리가 삭제된다. 명시적 `rm -rf` 한 번이 SSOT 다.

## Durable output에 임시 경로 박제 금지 (회귀 방지)

셸 호출 사이에 `CONSULT_DIR` 리터럴 값을 재사용하는 것은 runtime 요구사항이지만, plan / PRD / PR / issue / comment 같은 durable output에는 temporary scratch consult output 리터럴을 박지 않는다. 임시 경로는 세션 종료 시 사라지는 ephemeral identifier 다.

durable output 적합성은 작성자가 본 prose 가이드와 CLAUDE.md의 `Durable output pinning policy` 를 직접 따르는 형태로 보장한다 — `pinning-patterns.sh` 의 hard-fail enforcement는 라운드 카운터, DA finding ID, DA 키워드만 잡고 임시 경로 hex는 잡지 않는다.

durable output에는 다음만 기록한다:

- 자문 회차 자연어 요약 (예: "1차 자문 (전체 N 결정)")
- `decision_id` list
- verdict 요약

스코프: 본 금지는 _agent 가 이번 작업으로 새로 생성하는_ generated plan / PRD / PR / issue / comment 에만 적용된다. 본 reference 문서 자체의 셸 호출 예시 (위 셸 호출 1/2/3 코드블록의 placeholder hex 값) 는 runtime 동작을 가르치는 SSOT 가이드이므로 정책 적용 대상이 아니다. durable output 차단은 *새 박제 추가* 에만 작동하며 기존 SSOT 예시는 보존된다.

## Validation

- dummy decision (옵션 A / B 2개) 1개로 Step 3.5 round-trip 1회 성공.
- 출력 JSON에 `Recommended`, `Best`, `Default` 라벨 부재 확인 (`rg`).
- 옵션 순서가 다른 `decision_id` 입력 2건에 대해 다름. 같은 `decision_id` 재호출 시 동일 (decision_id-seeded stable shuffle 검증).
- 30분 이내 결과 도착 (`time codex exec ...`).
- `--sandbox read-only` 로 호출했을 때 file write 시도가 sandbox에서 차단됨 (negative test).
