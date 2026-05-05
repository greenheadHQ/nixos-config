# Resume State

작성 중·구현 중인 plan을 다음 세션에서 정확한 단계로 이어가기 위한 메커니즘. `Resume From` enum 카탈로그 + baseline drift 검증 알고리즘 + 불변조건.

## Resume From enum 카탈로그

`Resume From` 필드는 자유문이 아니라 enum 값을 사용한다. enum은 `<mode>.<step_id>` 형식으로 기계적 식별 가능해야 한다.

### for_action

| Resume From | 진입 조건 |
|-------------|----------|
| `for_action.step1_validity` | 이슈 유효성 판단 (시작) |
| `for_action.step2_exploration` | 코드베이스 탐색 + 로컬 재현 |
| `for_action.step3_questions` | 질문 수집 |
| `for_action.step3_5_consulting` | Step 3.5 외부 자문 시작 (background 발사) |
| `for_action.step3_5_awaiting` | Step 3.5 결과 대기 (background 진행 중) |
| `for_action.step4_user_questions` | 사용자에게 질문 제시 (자문 결과 통합) |
| `for_action.step4_awaiting_user` | 사용자 답변 대기 |
| `for_action.step5_da` | Step 4.5에서 만든 공식 plan 파일을 context로 `/run-da for_plan` 호출 |
| `for_action.step6_da_apply` | Step 4.5에서 만든 같은 plan 파일에 DA 결과 반영 |
| `for_action.step7_plan_mode_entry` | 계획 추적 도구 진입 + 기존 plan 파일 바인딩 |
| `for_action.step8_plan_writing` | 기존 plan 파일 review/refine |
| `for_action.step9_approval` | 승인 요청 도구 호출 |
| `for_action.step9_awaiting_approval` | 사용자 승인 대기 |

### for_action Step 4.5와 resume

Step 4.5는 별도 `Resume From` enum을 만들지 않는다. 이 단계는 공식 `.claude/plans/<slug>.md` 파일을 atomic하게 초기화하고 즉시 다음 blocking step인 `for_action.step5_da`를 `Resume From`에 기록한다.

초기 plan 파일은 다음 resume 관련 값을 반드시 포함한다:

- `Resume From`: `for_action.step5_da`
- `Last Completed Step`: `for_action.step4_user_questions`
- `Baseline`: Step 4.5 파일 생성 시점의 branch, 자연어 HEAD anchor, dirty 자연어 상태
- `DA State`: `PRE_DA`

Step 5/6 진행 중에는 [`plan-file-template.md`](./plan-file-template.md#da-state-값)의 `DA State`를 함께 사용한다:

- `PRE_DA` + `Resume From=for_action.step5_da`: DA를 아직 시작하지 않았으므로 Step 5로 진입한다.
- `RUNNING`: 외부 검토가 시작된 상태다. `Change Log`에서 외부 검토 시작 상태를 확인한다. 같은 active session에서 원 run이 아직 진행 중임을 runtime-only 상관관계로 확인할 수 있으면 기다리고, 세션 재개 후 active 여부를 확인할 수 없거나 durable verdict가 없으면 같은 plan 파일을 입력해 재실행한다. 나중에 도착한 이전 verdict는 stale result로 기록하고 적용하지 않는다.
- `APPLYING` + `Resume From=for_action.step6_da_apply`: verdict를 수신했으므로 `Change Log`의 durable verdict summary 또는 stable artifact name을 읽고 Step 6 반영 상태를 점검한다. 기록이 없거나 runtime-only 상관관계 부재로 현재 verdict임을 확인할 수 없으면 같은 plan 파일을 입력으로 재실행하고 Change Log에 재실행 사유를 기록한 뒤 반영한다.
- `CONFIRMED`/`SKIPPED`: Step 6 이후의 첫 미완료 blocking step으로 이동한다.
- `BLOCKED`/`NEEDS_USER`: 질문 도구로 사용자 판단을 요청하거나 하위 스킬 BLOCKED 계약을 따른다.

따라서 세션이 Step 5 직전이나 Step 6 반영 중 끊겨도 메인 LLM은 기존 plan 파일을 읽고 baseline drift 검증 후 `for_action.step5_da` 또는 `for_action.step6_da_apply`로 복귀한다.

### for_issue

`for_issue`는 산출물이 이슈(plan 파일 없음)라 본 enum은 적용되지 않는다. 진행 상태는 issue body 또는 `/write-handoff` 산출물에 기록된다. for_action 전환 시점부터는 `for_action.*` enum이 사용된다.

### for_prd

`for_prd`는 plan-with-questions가 Step 1-4와 Step 5-6을 거친 뒤 PRD 규약을 따라 `.claude/prds/prd-<feature>.md`에 직접 작성한다. `for_action` Step 4.5 plan 파일 초기화는 적용하지 않는다. PRD 작성 이후의 phase 진행 상태는 PRD master 파일의 Document Status가 정본이며 본 enum은 사용되지 않는다. plan-with-questions가 추적하는 enum은 PRD 작성 직전까지 한정:

| Resume From | 진입 조건 |
|-------------|----------|
| `for_prd.candidate_detected` | task-size-routing 후보 감지 + 사용자 알림 대기 |
| `for_prd.step5_da` | PRD draft/context 기준 `/run-da for_plan` 호출 |
| `for_prd.step6_da_apply` | PRD draft/context와 candidate phase structure에 DA 결과 반영 |
| `for_prd.user_confirmed` | 사용자 동의 후 PRD 작성 직전 |

PRD 작성 후의 진행은 PRD master Document Status에서 `Current Phase` / `Active Phase File` / `Status` 필드로 추적한다.

PRD 파일 작성 전의 `for_prd.step5_da` / `for_prd.step6_da_apply`는 durable file artifact를 전제하지 않는다. 세션이 끊긴 뒤 재개하면 transient draft/context와 DA verdict를 신뢰하지 않고 이슈 ref + Step 1-4 evidence를 다시 확인한 뒤 Step 5 DA부터 재실행한다. PRD 파일을 작성한 뒤에는 재실행 사유와 최종 verdict 요약을 master `Change Log`에 기록한다.

### Post-Implementation

| Resume From | 진입 조건 |
|-------------|----------|
| `post_impl.implementation` | 변경 구현 (1번) |
| `post_impl.implementation_commit` | 구현 커밋 (2번) |
| `post_impl.run_da_for_pr` | `/run-da for_pr` (3번) |
| `post_impl.parallel_audit` | `/parallel-audit` (4번) |
| `post_impl.final_10pass` | Final Multi-Pass Review (5번) |
| `post_impl.review_commit` | 10-pass 반영 커밋 (6번, 수정 발생 시) |
| `post_impl.create_pr` | `/create-pr` (7번) |

## Baseline drift 검증 알고리즘

재개 시점에 plan 파일의 `Baseline` 필드와 현재 git 상태를 비교하여 drift를 감지한다. `for_action` plan의 최초 baseline은 Step 4.5 공식 plan 파일 초기화 시점에 기록한다.

### Baseline 필드 형식

```
branch=<branch_name>, HEAD=<자연어 anchor>, dirty=<clean 또는 자연어 요약>
```

- `branch_name`: 작업 branch 이름.
- `자연어 anchor`: 사람이 git log와 작업 맥락으로 다시 해석할 수 있는 표현.
  - 예: `PR #123 머지 직후`
  - 예: `작업 시작 직전 main`
  - 예: `issue/659 작업 branch 생성 직후`
- `clean 또는 자연어 요약`: working tree가 clean이면 `clean`. dirty이면 어떤 종류의 미커밋 작업인지 자연어로 요약한다. diff digest나 짧은 commit 식별자를 쓰지 않는다.
- `branch_name`, `HEAD`, `dirty` 값은 한 줄로 작성하고 comma(`,`)와 newline을 포함하지 않는다. branch 이름에 comma가 있으면 plan 작성 전에 사용자 확인을 받고 branch를 바꾸거나 Baseline을 `NEEDS_USER`로 둔다. 자연어 값에 comma가 필요하면 semicolon이나 짧은 문장으로 바꿔 delimiter parsing을 깨지 않게 한다.

작성 시 명령:

```bash
BRANCH=$(git rev-parse --abbrev-ref HEAD)
git log -5 --pretty=format:%s
git status --short
# HEAD_ANCHOR와 DIRTY는 위 출력과 작업 맥락을 읽고 사람이 직접 작성한다.
# DIRTY는 clean 또는 자연어 요약이어야 하며, diff digest를 쓰지 않는다.
HEAD_ANCHOR="<예: 작업 시작 직전 main>"
DIRTY="<예: clean 또는 'uncommitted: PRD draft only'>"
echo "branch=$BRANCH, HEAD=$HEAD_ANCHOR, dirty=$DIRTY"
```

### 재개 시 비교 절차

1. plan 파일의 `Baseline` 파싱.
   - Baseline이 위 새 형식이 아니거나 안전하게 파싱되지 않으면 Step 1-2를 재실행하거나 사용자 확인을 받는다.
2. 현재 git 상태를 확인: branch 이름, 최근 commit subject, `git status --short`.
3. 비교:
   - **branch 동일 + anchor 의미가 현재 상태와 명확히 일치 + dirty 상태가 안전하게 비교됨**: `Resume From` enum 값으로 정확한 단계 점프.
   - **branch 다름**: 사용자에게 경고 + 작업 의도 확인 (다른 브랜치에서 작업 재개 의도일 수 있음).
   - **anchor 의미 불명확 또는 현재 상태와 불일치**: drift 발생 가능. Step 1-2 재실행 또는 사용자 확인이 필요하다. 확인 없이 `Resume From`으로 점프하지 않는다. plan에 `DL` 추가:

     ```markdown
     ### DL-N: Baseline drift detected on resume

     - Status: accepted
     - Context: 재개 시점에 baseline anchor가 현재 git 상태와 안전하게 일치하지 않음.
       - was anchor: <plan에 적힌 자연어 anchor>
       - now context: <git log/status로 확인한 현재 상태 자연어 요약>
       - drift 판단 근거: <메인 LLM 또는 사용자 판단 1-2문장>
     - Decision: Step 1-2 재실행 후 plan 본문 갱신.
     - Consequences: Resume From이 `for_action.step1_validity`로 reset됨.
     ```
   - **dirty 상태 불명확**: baseline 또는 현재 상태가 dirty이고 같은 미커밋 작업인지 안전하게 비교할 수 없으면 drift 발생 가능으로 처리한다. Step 1-2를 재실행하거나 사용자에게 추가 변경의 plan 통합 의도를 확인한다.

## 동일 세션 progressive commit vs 재개 drift 구분

`Status=Implementing`인 plan을 같은 세션에서 phase별 commit으로 진행하는 경우, branch + HEAD 변경은 정상이다 (Phase 1 commit → Phase 2 commit → ... 자연 진행). 이때는 Baseline drift 처리 불필요 — 그냥 plan의 `Baseline`/`Last Updated`/`Last Completed Step`/`Resume From`/`Phase Progress`를 갱신한다.

**drift 알고리즘 적용 조건**:
- 재개 시점 = 메인 LLM 세션 컨텍스트가 단절된 상태에서 plan 파일을 다시 열 때.
- 신호: `Last Updated`가 오늘이 아니거나, `Status=Implementing`인데 메인 LLM이 진행 history를 메모리에 보유하지 않음.

**진행 중 commit 신호** (drift 처리 skip):
- 동일 세션에서 phase 단위 commit 후 다음 phase 진입.
- 메인 LLM이 직전 commit subject와 진행 맥락을 컨텍스트에 보유.
- plan의 `Change Log` 마지막 entry가 직전 commit subject 또는 진행 요약과 일치.

## 불변조건

- **첫 미완료 blocking step**: `Resume From`은 항상 첫 번째 미완료 blocking step만 가리킨다 (이미 끝난 단계나 skip된 단계를 가리키지 않는다).
- **체크박스 evidence**: 완료 체크박스(`- [x]`)는 evidence 또는 validation note 없이 전환 금지. plan에 "Step 5 DA 완료"라 적으려면 외부 검토 verdict 요약, stable artifact name, 또는 validation note가 함께 있어야 한다. ephemeral scratch reference를 durable evidence로 쓰지 않는다.
- **Last Updated 동기화**: `Last Updated`가 바뀌면 `Change Log`도 같은 날짜로 갱신된 entry가 있어야 한다.
- **Mode 전환은 DL**: `Mode` 필드가 바뀌면(`for_action` → `for_prd`) 반드시 Decision Log에 기록한다.
- **Baseline drift 처리 의무**: Baseline drift 또는 dirty 상태 ambiguity 감지 시 Step 1-2 재실행 또는 사용자 확인이 필요하다. 메인 LLM 자체 판단으로 "drift는 무시해도 되겠다"며 `Resume From`으로 점프하지 않는다.

## 재개 호출 패턴 (사용자 입장)

다음 세션에서 사용자가 다음 중 하나로 시작하면 재개:

- 명시적: `"`.claude/plans/<path>.md` Resume From부터 이어가자"` 
- plan 파일 path만: `".claude/plans/<path>.md"` (메인 LLM이 Status / Resume From 읽고 판단)
- plan-with-questions 직접 재호출 + 같은 이슈 ref: 동일 ref면 기존 plan 발견 후 재개 모드

메인 LLM은 plan 파일 상단 `Document Status` 표를 먼저 읽고, Baseline drift 검증 → Resume From 점프 순으로 진행한다.

## Follow-up

- baseline drift 보조 스크립트 (`scripts/check-plan-baseline.sh`) — 현재는 메인 에이전트가 수동 비교. 자동화 채택 여부는 사용자 follow-up 우선순위에 따른다.
