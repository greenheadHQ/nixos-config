# Mode: for_plan

계획 단계 DA 1회 — 구현 계획 또는 실행 근거 문서 대상.

## 대상 정의

for_plan 대상은 구현 계획, 계획 파일, 대화 컨텍스트뿐 아니라 이슈/PRD 본문처럼 이후 실행의 근거가 될 문서를 포함한다.

문서 대상일 때는 구현 가능성 외에도 자기완결성, 근거를 실제로 측정·확인할 수 있는지, 스코프 경계와 제외 범위가 명확한지를 검토한다. 문서 QA는 기존 reviewer bundle의 관점으로 수행하며 새 reviewer나 별도 단계를 만들지 않는다.

## Step 0: Review Intensity 판단

[`../references/intensity-procedure.md`](../references/intensity-procedure.md)의 판단 실행 절차를 따른다.

- `MAX` modifier가 있으면 이 단계를 건너뛰고 exhaustive override(6개 세부 도메인)로 진입한다.
- SKIP → SKIP 절차를 따른다. 단 `GATE-REMOVAL-SIMPLIFY`([`../references/intensity-rules.md`](../references/intensity-rules.md))가 매치되면 SKIP이어도 종료 전에 메인이 Step 1의 의사결정 컨텍스트 팩 + degraded 조사([`../references/decision-regression-audit.md`](../references/decision-regression-audit.md) Step A·B·D)를 수행한다. 게이트 미매치 SKIP만 승인 시 for_plan을 종료한다.
- LITE → LITE 절차에 따라 실행할 reviewer bundle을 선택한다.
- FULL → 4 reviewer bundles를 실행한다.

## Step 1: 계획 내용 수집 + 의사결정 컨텍스트 팩

현재 계획 파일, 실행 근거 문서, 또는 대화 컨텍스트에서 검토 대상 내용을 수집한다.

검토 시작 자문 항목: 이 계획이나 문서가 제안하는 변경 규모·복잡도가 원래 pain point의 크기에 비례하는가, 더 작은 해법이 있는가. 판정 결과는 DA 보고에 포함한다. 불비례하다고 판단되면 finding으로 제기하고 축소 대안을 함께 제시한다.

계획이 제거·단순화·되돌림·리팩터 방향이거나 변경 대상이 git상 왕복 핫스팟이면, [`../references/decision-regression-audit.md`](../references/decision-regression-audit.md)의 발동 조건에 따라 "의사결정 컨텍스트 팩"(해당 문서 Step A)을 수집한다 — 메인이 commit/PR/issue(+있으면 CIR/ADR·로컬 세션 로그)에서 과거 결정·되돌림 이력을 추려, Step 2의 reviewer 프롬프트와 Step 5의 Arbiter 프롬프트에 selective propagation으로 주입한다. 그 외 변경은 Review Intensity에 연동한다(FULL=전체 조사, LITE=경량, SKIP=생략).

`fresh` 반복 세션에서 local dismissal ledger가 있으면, changeset freeze 직후 current changeset key와 일치하는 valid entry만 읽는다. ledger entry는 Step 2 reviewer prompt에 넣지 않고, Step 3 결과 수집 후 Arbiter 진입 전 exact match suppression에만 사용한다. 세부 key/schema/invalidation 규칙은 [`../references/dismissal-ledger.md`](../references/dismissal-ledger.md)를 따른다.

## Outer round phase model: changeset 동결 + read/write 분리

각 outer round는 `changeset 동결 → review phase → write phase` 순서로 진행한다.

- changeset 동결: Step 2 진입 전에 이번 라운드의 검토 표면을 고정한다. for_plan은 계획 원문과 관련 파일/맥락, for_pr은 `git diff main...HEAD`와 현재 workspace 상태가 frozen changeset이다. dismissal ledger를 사용할 때도 이 frozen changeset key와 exact match하는 entry만 valid하다.
- review phase: Step 2 reviewer fan-out부터 Step 5e 상태 전이와 사용자 전건 보고까지다. 이 구간에는 메인 에이전트와 delegated reviewer/Arbiter 모두 active changeset을 바꾸지 않는다. patch/edit/apply_patch, write-mode formatter, codegen/regeneration으로 생기는 generated output 변경, lockfile 재생성, commit/push를 금지한다. formatter/generator는 check/diff-only 모드처럼 파일 변경이 없을 때만 허용한다.
- write phase: 한 라운드의 Arbiter 판정과 필요한 사용자 판단이 끝난 뒤에만 시작한다. CONFIRMED_ISSUE와 사용자가 수용한 NEEDS_MORE_INFO/`split` 항목을 queue에 모아 메인 에이전트가 batch로 반영한다.
- CRITICAL 기본값: CRITICAL도 review phase 중 즉시 patch하지 않는다. 해당 라운드의 Arbiter 판정이 닫힌 뒤 write phase 첫 항목으로 반영하며, 해결 전에는 다음 outer round로 진행하지 않는다.
- 새 changeset 선언: write phase가 끝나면 다음 라운드는 "새 changeset" 리뷰로 명시하고, round summary에 batch 변경 범위(수정한 계획/파일, generated output 유무, diffstat)를 기록한다.

## Step 2: reviewer bundle 병렬 실행

선택된 reviewer bundle 또는 explicit exhaustive override의 세부 도메인별 DA 에이전트를 병렬 실행한다. 런타임별 도구 매핑은 [`../references/runtime-mapping.md`](../references/runtime-mapping.md) 참조.
호출 단위 실행 프로파일과 사용자 지정 실행 파라미터(model/effort/tier)는 [`../SKILL.md`](../SKILL.md)의 정의가 정본이다. 예: `run-da for_plan agent=codex-high`.

### Codex 세션 경로

- 선택된 review unit마다 fresh native subagent 1개를 standard review profile로 `spawn_agent` 실행한다.
- 각 프롬프트는 [`../references/da-domains.md`](../references/da-domains.md)의 공통 프롬프트 구조에 계획 전체 내용을 포함하고, "계획 외의 관련 파일도 직접 읽어 탐색하라", "out-of-repo scratch PoC만 허용한다", "`run-da` canonical contract의 stateful-violation 금지 작업(`tracked write`, `branch mutation`, `commit/push`, `GitHub write`, `main-agent-only command`, `host mutation`)을 축약 없이 따르라" ([`../references/hardening-contract.md`](../references/hardening-contract.md) 참조), "규칙 위반은 finding 대신 `VIOLATION`으로 반환하라"를 명시한다.
- 선택된 review unit 수가 capability profile의 batch 상한을 넘으면 batch한다 (slot 판별·회수 규칙은 [`../references/runtime-mapping.md`](../references/runtime-mapping.md#codex-native-lifecycle-capability-profile) SSOT).
- `wait_agent` timeout만으로 실패 처리하거나 reviewer를 kill/self-auditing으로 대체하지 않는다.
- `fresh` modifier와 selective propagation 규칙은 동일하게 적용한다.

### codex exec 경로 (Claude Code 세션 · headless 세션)

- 실행 전 [`../../using-codex-exec/SKILL.md`](../../using-codex-exec/SKILL.md)의 패턴 4 (exec 우회)와 패턴 5 (DA 피드백 루프)를 참조한다.
- 세션별 임시 디렉토리를 생성하고 stdout으로 출력한다. 모든 런타임은 [`../references/runtime-mapping.md`](../references/runtime-mapping.md)의 공통 주의(셸 호출 간 변수 유실)를 따른다.
  ```zsh
  _DA_SID=c4a35fc4
  DA_DIR=$(mktemp -d /tmp/da-${_DA_SID}-plan-XXXXXX)
  [ -d "$DA_DIR" ] || { echo "missing DA_DIR=$DA_DIR"; exit 1; }
  printf 'DA_DIR=%s\n' "$DA_DIR"
  ```
- 선택된 review unit별 프롬프트 파일 생성 호출은 stdout의 `DA_DIR` 리터럴 값을 재설정하고 guard한다:
  ```zsh
  DA_DIR=/tmp/da-c4a35fc4-plan-AbCdEf
  UNIT=correctness
  [ -d "$DA_DIR" ] || { echo "missing DA_DIR=$DA_DIR"; exit 1; }
  # 계획 원문은 untrusted input이다. shell heredoc에 직접 삽입하지 말고,
  # 파일 편집 도구나 구조화 writer로 "$DA_DIR/$UNIT.md"에 작성한다.
  ```
- 선택된 review unit 수만큼 다음 guard prefix를 적용한 뒤 [`../references/arbiter-scaling.md`](../references/arbiter-scaling.md)의 role별 명령 `reviewer / Auditor` 템플릿을 런타임별로 기동한다:
  ```zsh
  DA_DIR=/tmp/da-c4a35fc4-plan-AbCdEf
  UNIT=correctness
  [ -d "$DA_DIR" ] || { echo "missing DA_DIR=$DA_DIR"; exit 1; }
  [ -f "$DA_DIR/$UNIT.md" ] || { echo "missing prompt=$DA_DIR/$UNIT.md"; exit 1; }
  ```
  `--ignore-user-config`/`--ignore-rules`/effort resolution 등 command literal은 [`../references/arbiter-scaling.md`](../references/arbiter-scaling.md)의 role별 명령이 SSOT다. Claude Code 세션의 기본 병렬 경로와 fallback 경로(codex exec 사전점검 실패 원인 고지 후 사용자 확인 시)는 [`../references/runtime-mapping.md`](../references/runtime-mapping.md)의 "런타임 도구 매핑" 표 binding을 따른다. headless 세션은 serial foreground (완료 알림·`&+wait` 없음).
- Claude Code 세션: 병렬 실행 완료 알림을 수신하면 sleep/poll 없이 바로 결과를 수집한다. headless 세션: 각 subprocess 종료를 직렬로 확인한다.
- 모든 런타임 공통: `& + wait` shell-level 병렬 금지, `cat file | env CODEX_PROGRAMMATIC=1 codex-exec-supervised --sandbox read-only --ignore-user-config --ignore-rules --ephemeral ... -` stdin pipe (Layer 1)로 프롬프트 전달. pipe EOF가 stdin을 닫으므로 `< /dev/null`은 불필요. 인라인 인자 `"$(cat file)"`는 사용하지 않는다. `CODEX_PROGRAMMATIC=1` env assignment는 codex 프로세스에 적용되어야 한다 (회피: `CODEX_PROGRAMMATIC=1 cat ...`은 cat에만 적용 — issue #585).
- [`../../using-codex-exec/SKILL.md`](../../using-codex-exec/SKILL.md) 패턴 5의 실행 흐름(`-o` 사용법, 결과 파일 검증, 명령 실행 순서)만 참고한다. 프롬프트 내용 규칙은 본 스킬의 `fresh`/프롬프트 조향 금지 규칙이 우선한다.

## Step 3: reviewer 결과 수신 + 종합 리포트

- Codex 세션 경로: 결과를 수집한 뒤 ([`../references/runtime-mapping.md`](../references/runtime-mapping.md#result-collection) binding), 다음 round/retry 전에 capability profile의 slot 회수 규칙을 적용한다 (legacy만 `close_agent` — [`../references/runtime-mapping.md`](../references/runtime-mapping.md#codex-native-lifecycle-capability-profile) SSOT).
- Codex 세션 경로: 사후 변조 감지 — fan-out 직전에 `git status --porcelain=v1 --untracked-files=all` 출력을 메인 에이전트 컨텍스트에 보존하고, 모든 결과 수신 후 같은 명령으로 재실행해 비교한다. delta가 있으면 원인 불문 `STATEFUL VIOLATION (workspace changed during review)`으로 fail-closed BLOCKED 처리하고 write phase로 진행하지 않는다 — native child는 read-only sandbox를 구조적으로 강제할 수 없고([`../SKILL.md#non-goals`](../SKILL.md#non-goals) #1), for_pr finalize는 workspace 전체를 커밋하므로 child가 만든 변경이 agent batch로 편입될 수 있다. 절차 상세와 감지 불가 범위는 [`./audit.md`](./audit.md)의 "사후 변조 감지" 절과 동일하다. codex exec 경로는 `--sandbox read-only`(차단 수행자는 codex sandbox — wrapper는 passthrough, #1086)가 workspace write를 차단하므로 생략한다. 생략의 전제와 복원 조건(명령 literal에서 `--sandbox read-only`가 빠지면 감지를 복원)은 같은 절이 정본이다.
- Codex 세션 경로: `VIOLATION` 처리 규칙은 [`../references/hardening-contract.md`](../references/hardening-contract.md)의 공통 처리 정의를 따른다. offending unit은 rerun 또는 `BLOCKED` 해소 전까지 `CLEAR` 계산에 포함하지 않는다.
- codex exec 경로: 선택된 review unit(FULL 기본 4개, LITE는 선택한 수, explicit exhaustive는 6개) 전부 실행(Claude Code는 병렬, headless는 serial) 완료 후, 각 `$DA_DIR/$UNIT-result.md` 패턴의 결과 파일을 파일 읽기 도구로 명시적으로 읽어 수집한다. 결과 파일이 없거나 빈 경우, 또는 exit code가 0이 아니면 실패로 판정한다.
- 수집한 각 finding의 ID가 [`../references/da-domains.md`](../references/da-domains.md)가 정의한 shell-safe 문법과 일치하고 결과 내에서 유일한지 검사한다 (문법과 prefix namespace는 그 문서가 정본이며 여기서 정규식을 복사하지 않는다). 목적은 reviewer 산출 ID가 비신뢰 입력인데 이후 `--expect-findings` 셸 인자로 전달되므로 안전한 문자 집합만 통과시키는 것이다. 위반 finding이 있으면 해당 unit을 recoverable violation으로 폐기하고 fresh 실행 단위로 1회 재실행하며, 검증 통과 ID만 manifest에 조립한다.
- 실패한 review unit만 재실행한다. codex exec 경로는 라운드마다 새 `DA_DIR`을 생성하여 이전 라운드 산출물과 분리한다.
- 재실행 전 실패 분류 (사용자 지정 실행 파라미터가 있는 호출): 실패한 unit의 실행 호출 출력과 `$DA_DIR/$UNIT-stderr.log`를 함께 읽어 값 거부(unsupported/invalid model·effort·tier, config override 거부)나 usage/quota 거부인지 확인한다. 두 채널을 모두 봐야 한다 — shell-safe guard 거부(`invalid ...` 메시지)는 codex 실행 전 로컬 검증이라 stderr 로그가 아닌 실행 호출의 stdout에 나타나므로, stderr 로그가 비어 있다는 이유로 일시 실패로 오인하지 않는다. 이런 결정적 거부는 재실행으로 해소되지 않으므로 재실행하지 않고, 거부 원문을 사용자에게 그대로 보고한 뒤 중단한다 (`run-da/SKILL.md` 값 유효성 계약 — 조용한 대체/하향 금지). 일시적 실행 실패만 재실행 대상이다.
- `fresh` 반복 세션에서 valid dismissal ledger가 있으면, reviewer finding별 dismissal key를 계산해 exact match 항목만 `dismissed_suppressed`로 분류한다. suppress된 항목은 Arbiter 입력, 신규 finding 계산, pending write queue에 포함하지 않는다. match하지 않는 항목은 평소처럼 Step 5 Arbiter로 보낸다.

## Step 4: ALL CLEAR 또는 Arbiter 진입

findings 0건이고 `VIOLATION`/`BLOCKED` review unit이 없으면 → ALL CLEAR, 종료 (`walkthrough_status=NOT_REQUIRED` — write phase가 없는 수렴 종료 특수형, [`../references/protocol.md`](../references/protocol.md) 수렴 판정 참조).

## Step 5: Arbiter 실행 (findings ≥ 1건 시)

- 5a. first-pass Arbiter: Arbiter 프롬프트를 조립한다 ([`../references/arbiter-prompt.md`](../references/arbiter-prompt.md)의 for_plan 조립 규칙 참조). for_plan에서는 반드시 계획 원문을 포함해야 하며, 상세 조립 형식은 arbiter-prompt.md의 "프롬프트 조립 > for_plan 모드" 참조.
  - Codex 세션 경로: fresh Arbiter subagent 1개를 실행하고 결과를 수집해([`../references/runtime-mapping.md`](../references/runtime-mapping.md#result-collection) binding) `/tmp/da-${_DA_SID}-arbiter-*` 네임스페이스의 scratch 파일(예: `first-pass-result.md`)로 저장해 공통 검증기 호출에 사용한다 (검증기는 파일 입력 전용 — N=3 파일 규약과 동일 네임스페이스·cleanup 규칙). 이후 다음 round/retry 전에 capability profile의 slot 회수 규칙을 적용한다 (legacy만 `close_agent` — [`../references/runtime-mapping.md`](../references/runtime-mapping.md#codex-native-lifecycle-capability-profile) SSOT).
  - codex exec 경로: foreground 실행 (단일 exec이므로 결과를 즉시 확인. [`../references/arbiter-scaling.md`](../references/arbiter-scaling.md) 실행 계약 참조).
- 5b. Selective consistency trigger 검사: first-pass 결과의 VERDICT_JSON 블록을 읽어 [`../references/stability-measurement.md`](../references/stability-measurement.md)의 trigger 조건에 매치되는 finding을 식별한다 (조건 정의는 해당 문서가 SSOT). VERDICT_JSON을 읽는 이 지점에서 공통 검증기(`"$HELPER_PATH" --validate-only --expect-findings <Arbiter에 전달한 finding ID 쉼표 목록> <result.md>`)로 schema 1.1 caller 검증과 finding manifest 대조를 수행하고, 메인이 보유한 reviewer 원본 finding의 심각도와 `reviewer_severity`를 대조한다 (N=3 수집은 집계 경로가 같은 검증을 내부 적용) — 검증 규칙과 fail-closed 전이는 [`../references/protocol.md`](../references/protocol.md) "수렴 판정"이 SSOT.
- 5c. N=3 재판정 (trigger 매치 finding에 한해): 동일 Arbiter 프롬프트로 독립 N=3을 실행한다. 실행 계약과 환경 격리는 [`../references/arbiter-scaling.md`](../references/arbiter-scaling.md)의 "N=3 실행 계약" 섹션 참조. selective consistency 서브런은 outer round 카운트에 포함되지 않는다.
- 5d. vote-shape 집계: `"$HELPER_PATH"` harness([`../references/protocol.md`](../references/protocol.md) "검증기 호출 계약"으로 결정한 절대경로)로 3개 결과 markdown의 VERDICT_JSON 블록을 파싱하여 finding별 `stability_status`(stable/split/fragmented) 및 `low_confidence_warning`을 `per_finding[]`에서, top-level `partial_failure`(및 `missing`/`manifest_violations`/`file_level_failures`/`per_file_malformed` 세부)를 얻는다. `partial_failure=true`이면 세부 원인별 caller 매핑([`../references/protocol.md`](../references/protocol.md) 상태 전이표 아래 정의 — `missing` finding만 finding별 BLOCKED, 파일 단위 위반은 수집 단위 전체 fail-closed 전이)을 적용한다.
- 5e. 상태 전이 적용 — 상세 전이표는 [`../references/protocol.md`](../references/protocol.md)의 "Selective consistency 상태 전이" 참조. trigger되지 않은 finding은 first-pass VERDICT_JSON entry를 그대로 사용하고, caller의 round 상태에만 `stability_status=N/A`를 기록한다 (entry 자체에 이 필드를 추가하면 검증 위반이다 — aggregate 전용 필드다).

결과를 수집하여 사용자에게 전건 보고한다 (vote-shape/low_confidence_warning이 있으면 함께 보고). 아래 심각도는 `accepted_severity`(Arbiter 조정 후 값 — [`../references/protocol.md`](../references/protocol.md) 수렴 판정 SSOT) 기준이다:

- CONFIRMED_ISSUE + CRITICAL + (N/A 또는 stable) + `low_confidence_warning=false`: 진행 차단. review phase 중 patch 금지 원칙을 유지하고, Arbiter 판정이 닫힌 뒤 write phase의 첫 batch 항목으로 계획에 반영한다. 해결 전에는 다음 outer round로 진행하지 않는다.
- CONFIRMED_ISSUE + HIGH/MEDIUM/LOW + (N/A 또는 stable) + `low_confidence_warning=false`: pending write queue에 추가하고, Step 6 write phase에서 계획에 일괄 수정한다.
- NOT_AN_ISSUE + (N/A 또는 stable) + `low_confidence_warning=false`: 보고만 (반영 불필요). eligible 항목은 사용자 전건 보고 후 local ignored dismissal ledger에 기록한다.
- NEEDS_MORE_INFO 또는 `stability_status=split`: 질문 도구로 사용자 판단을 요청한다 (vote-shape와 minority verdict도 함께 보고). 사용자가 수용한 항목만 pending write queue에 추가한다.
- 임의 verdict + (N/A 또는 stable) + `low_confidence_warning=true`: fail-closed 승격 — 질문 도구로 사용자 판단 요청 (unanimous/단일 Arbiter라도 LOW confidence 이력이 있으면 기존 LOW-confidence NOT_AN_ISSUE 자동 NEEDS_MORE_INFO 계약을 유지).
- `stability_status=fragmented` 또는 `partial_failure=true`: BLOCKED — 질문 도구 지원 런타임에서는 판단 요청, 미지원 런타임에서는 자동 승격 금지(중단 보고).

## Step 6: write phase — 통합 반영 루프 후 새 changeset 선언

Step 5 상태 전이와 사용자 판단이 끝나면, 먼저 round outcome 스냅샷(`round_write_set`, `round_max_accepted_severity`, `unresolved_count` — [`../references/protocol.md`](../references/protocol.md) 수렴 판정 SSOT)을 고정한다. pending write queue가 있으면 메인 에이전트가 single-writer로 아래 루프를 수행한다. 내부 단계는 번호가 아니라 이름으로 참조한다:

- 통합 설계: round_write_set 전체를 놓고 수정 대상(계획/관련 파일) 전체를 통독한다 → finding 간 상호작용과 기존 구조와의 모순을 점검한다 (A 지적의 수정이 B 지적이나 기존 계약을 깨는지) → 하나의 통합 변경 설계를 세운다. 여러 finding이 같은 구조적 원인을 공유하면 개별 패치 대신 구조 수정 1건으로 통합한다.
- batch 반영: 설계에 따라 일괄 수정한다. 수정 전 해당 위치(for_plan: 관련 파일 또는 계획 항목)를 직접 확인하고, CRITICAL은 batch 첫 순서로 처리하되 review phase 중 즉시 patch하는 예외는 두지 않는다. 수정 diff를 명시하고 각 finding이 해결됐는지 확인한다. formatter/generator가 필요하면 이 단계에서만 실행하고 generated output 변경 범위를 summary에 기록한다.
- walkthrough: 수정된 대상을 처음 읽는 사람처럼 순서대로 따라 실행한다 — 절차 문서·스킬 문서는 단계를 실제로 밟는 시뮬레이션("이 값을 어디서 가져오지?"가 걸리는지), 코드는 주요 실행 경로 추적, 계획은 실행 시뮬레이션(Step N을 끝내야 Step N+1이 가능한지). 정적 통독으로는 안 보이던 결함이 따라 실행에서 드러난다.
- 후속 수정 처리: walkthrough가 발견한 결함 중 즉시 수정할 수 있는 범위는 이번 batch가 도입한 회귀 또는 round_write_set 반영에 필수인 변경뿐이다 (confirmed-only write 계약 유지 — Arbiter 판정·사용자 수용 없는 무관 결함·기존 결함을 tracked change로 만들지 않는다). 범위 안 결함은 수정 사실과 범위를 기록하고(심각도 분류 없음 — Arbiter를 거치지 않은 수정에 심각도 산출 주체가 없다) 수정한 뒤 walkthrough를 재시작한다. 범위 밖 발견은 수정하지 않고 새 finding 후보로 기록해 다음 라운드 리뷰 대상으로 넘긴다. 후속 수정 또는 범위 밖 발견이 하나라도 있으면 protocol.md의 `walkthrough-forced` 조건이 성립해 `revalidation_required=true`가 된다. 건수를 round summary에 표기한다.
- finalize: 마지막 walkthrough pass가 추가 수정 없이 끝나면(`walkthrough_status=CLEAN`) 다음 outer round의 검토 대상이 되는 새 changeset을 선언한다 (for_pr은 이 시점에 commit — [`./for_pr.md`](./for_pr.md) delta 참조).

`revalidation_required`([`../references/protocol.md`](../references/protocol.md) 수렴 판정의 단일 파생값)가 true이면 새 reviewer 실행 단위로 재검증 라운드를 진행한다. review unit 선택은 발동 조건 조합에 따라 protocol.md 수렴 판정의 라우팅 표를 따른다 — 특히 `walkthrough-forced`인데 batch 재평가가 SKIP이면 재검증 unit이 없는 것이 아니라 `last_review_units`를 재사용한다 (walkthrough가 결함을 발견한 라운드에서 재검증이 조용히 생략되지 않게 한다).

- Codex 세션 경로: 이전 round thread의 slot 회수를 capability profile 규칙(legacy만 `close_agent`, current는 explicit close 없이 광고 slot 내 발사 계획 — [`../references/runtime-mapping.md`](../references/runtime-mapping.md#codex-native-lifecycle-capability-profile) SSOT)으로 처리한 뒤 새 subagent들을 띄운다.
- codex exec 경로: 새 `codex exec` 프로세스와 새 `DA_DIR`을 사용한다.

## Step 7: 수렴 predicate 충족까지 반복

각 라운드의 write phase가 끝나면 [`../references/protocol.md`](../references/protocol.md)의 "수렴 판정" 섹션(SSOT — 조건을 여기 재서술하지 않는다)의 수렴 predicate를 평가한다. 충족하면 CONVERGED(또는 ALL CLEAR 특수형)로 종료하고, 아니면 Step 2-6을 반복한다. 반복 규칙은 protocol.md의 "최대 라운드 수"(상한 + 한계효용 + 비수렴 조기중단)와 read/write 분리를 함께 적용한다. 각 반복에서 Step 2-5는 frozen changeset에 대한 read-only review phase이고, Step 6만 write phase다. 수렴 전에 상한, 한계효용 저하, 비수렴 조기중단 조건이 충족되면 사용자에게 보고하고 종료/계속을 결정하며, 이 경로의 종료는 `EARLY_STOP (unconverged)`로 기록한다(질문 도구 미지원 런타임은 [`../references/arbiter-scaling.md`](../references/arbiter-scaling.md)의 자동 전이를 따른다).
