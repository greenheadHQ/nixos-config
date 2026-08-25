# Mode: for_pr

구현 후 코드 DA 1회 — git diff 대상.

`for_pr`은 `for_plan`과 step 구조가 동일하다. 입력(diff vs 계획), 임시 디렉토리 prefix, write phase의 코드 수정+커밋 방식, Step 8 push만 다르다. 동일 절차는 [`./for_plan.md`](./for_plan.md)를 참조하고, 본 파일은 차이점만 step 번호별로 명시한다.

호출 단위 실행 경로·파라미터 지정(자연어 채널)은 [`../SKILL.md`](../SKILL.md)의 정의가 정본이다. 예: "run-da for_pr, 전부 codex xhigh로".

## Step 번호별 delta (vs for_plan)

| Step | for_plan | for_pr (delta) |
|------|----------|----------------|
| Step 0 | 동일 (검토 강도 확정 — 기본 FULL, 하향은 사용자 명시 지시만) | 동일 |
| Step 1 | 계획 내용 수집 | diff preflight (clean workspace 요구) + diff 수집 — 체크포인트별 절차는 아래 "Step 1 상세: diff preflight" 절 참조 |
| Step 2 | reviewer prompt에 계획 원문 포함 | reviewer prompt에 diff를 `<git-diff>` 태그로 감싸서 포함 + "diff 외부의 관련 파일도 직접 읽어 탐색하라" 지시 |
| Step 2 (codex exec) | `DA_DIR=$(mktemp -d /tmp/da-${_DA_SID}-plan-XXXXXX)` | `DA_DIR=$(mktemp -d /tmp/da-${_DA_SID}-pr-XXXXXX)` (`-pr-` prefix). 후속 prompt/exec 호출은 for_plan Step 2와 동일하게 stdout `DA_DIR` 리터럴 재설정 + `[ -d "$DA_DIR" ]` / `[ -f "$DA_DIR/$UNIT.md" ]` guard를 적용 |
| Step 3 | 동일 | 동일 ([`./for_plan.md`](./for_plan.md#step-3-reviewer-결과-수신--종합-리포트)) |
| Step 4 | 동일 (finding 0건 → `termination_type=CONVERGED` 기록 후 종료 — all clear 특수형) | 동일 (종료 라벨 기록 후 Step 8 push로 이어진다) |
| Step 5 (Arbiter) | for_plan 조립 (계획 원문 포함) | for_pr 조립 (diff 컨텍스트 포함) — [`../references/arbiter-prompt.md`](../references/arbiter-prompt.md)의 "프롬프트 조립 > for_pr 모드" 참조. for_pr에서는 계획 원문 대신 diff 또는 변경 컨텍스트를 포함 |
| Step 5 상태 전이 | for_plan Step 5c의 전이 판정 순서(semantic malformed → LOW confidence 승격 → `remediation_scope` 분기) 적용 — FIX_NOW만 pending write queue, REPLAN_REQUIRED는 이슈 배출(DEFERRED), UNCLEAR는 사용자 판단 (protocol.md "remediation scope" 전이표). NOT_AN_ISSUE/사용자 제외는 세션 내 기각 이력에 기록 ([`../SKILL.md`](../SKILL.md) 정본) | 동일. review phase 중 patch 금지, formatter write 금지, generated output 변경 금지. 코드 수정/commit은 Step 6 write phase 전까지 금지 |
| Step 6 write phase | 통합 반영 루프(통합 설계→batch 반영→walkthrough→후속 수정 처리→finalize) 후 계획 확정·새 changeset 선언 | 동일 루프를 코드에 적용하되 finalize에서 commit한다 — 아래 "Step 6 상세: for_pr write phase" 절 참조 |
| Step 7 | 수렴 predicate 충족까지 반복 (protocol.md "수렴 판정" SSOT + "최대 라운드 수" 적용: 상한 + 한계효용 + read/write 분리) | 동일 |
| Step 8 | (없음) | push — predicate 충족 종료(`termination_type=CONVERGED` 또는 `DEFERRED_EXIT`) 후 최종 승인을 받아 push한다. `ROUND_LIMIT`·`USER_STOP` 종료는 자동 push하지 않고 미해결 상태와 함께 사용자에게 위임한다. push 전 walkthrough delta가 마지막 commit에 포함됐는지 확인한다 (네트워크/auth 정책 의존 — [`../SKILL.md#non-goals`](../SKILL.md#non-goals) 참조) |

## Step 1 상세: diff preflight

체크포인트는 이름으로 참조한다. 순서대로 수행한다:

- clean workspace 요구: `git status --porcelain=v1 --untracked-files=all`이 비어 있어야 한다. staged·unstaged·untracked 변경이 하나라도 있으면 진행하지 않고, 사용자에게 커밋·stash·정리를 요청한 뒤 중단한다. 리뷰 대상 구현이 미커밋이면 리뷰 diff와 push에서 조용히 빠지고, 무관한 사용자 변경이 남아 있으면 write phase의 agent 변경과 구분할 방법이 없다 — 두 경우 모두 clean 요구 하나로 막는다.
- DA 실행 중 workspace 불변: DA가 도는 동안 사용자·백그라운드 프로세스가 workspace를 수정하지 않는 것이 전제다. write phase가 만든 변경과 외부 변경을 구분하는 장치를 두지 않으므로, 외부 수정이 있으면 그것도 agent commit에 포함된다 ([`../SKILL.md#non-goals`](../SKILL.md#non-goals) 참조).
- diff 수집: `git diff main...HEAD`로 수집해 프롬프트에 직접 포함한다 (exec 우회 패턴). diff가 과도하게 크면 (`git diff main...HEAD | wc -l`로 확인) 기계적 변경(flake.lock, hash 변경 등)을 필터링한 축약 diff를 사용한다 (`git diff main...HEAD -- ':!flake.lock'`로 lock 파일 제외 가능).

## 공통 절차 (for_plan SSOT)

위 delta 표에 적힌 차이를 제외한 모든 단계의 본문은 [`./for_plan.md`](./for_plan.md)가 SSOT다 — 여기서 재요약하지 않는다. for_pr 전용 차이는 delta 표와 상세 절 세 곳(Step 1 / Step 6 / Step 8)에서만 소유한다.

for_pr에서 입력만 달라지는 공통 단계는 다음 둘뿐이다 (절차 자체는 for_plan과 같다):

- Step 1의 의사결정 컨텍스트 팩 수집: [`../references/decision-regression-audit.md`](../references/decision-regression-audit.md) Step A의 입력이 계획 원문 대신 `git diff main...HEAD`다. `fresh` 반복 라운드의 세션 내 기각 이력도 frozen `git diff main...HEAD` 기준 changeset과 일치할 때만 유효하다.

## Step 6 상세: for_pr write phase

for_plan의 통합 반영 루프에 다음 for_pr 전용 체크포인트를 더한다. Step 1이 clean workspace를 보장하므로 write phase가 만든 변경 = workspace의 모든 변경이며, 별도의 경로 승인·baseline 대조 장치를 두지 않는다.

- pre-write 기록: write phase 시작 시 `git rev-parse HEAD`를 `pre_write_sha`로 기록한다 (protocol.md revalidation `post-write-surface-gate` 조건의 batch delta 입력 기준).
- finalize (walkthrough CLEAN 후):
  1. `git status --porcelain=v1 --untracked-files=all`로 write phase delta를 확인한다.
  2. 비어 있으면 commit하지 않는다. walkthrough가 batch 수정을 전부 되돌렸다는 뜻이므로 round_write_set이 해결됐다고 보지 않는다 — 되돌린 이유를 walkthrough 후속 발견으로 기록하고, 해당 finding 수를 [`../references/protocol.md`](../references/protocol.md)의 `write_reverted_count`로 확정한다 (그 값이 0이 아니면 수렴 predicate가 막힌다). 새 changeset 선언도 하지 않는다.
  3. 비어 있지 않으면 메인 에이전트가 single-writer로 `git add -A && git commit`한다 ([`../references/hardening-contract.md`](../references/hardening-contract.md)의 single-writer 정의). clean에서 시작했으므로 전체 stage가 곧 batch 반영분이다.
  4. commit 후 `git status --porcelain=v1 --untracked-files=all`가 다시 비어 있는지 확인한다 (반영분이 전부 커밋되어 push에서 누락되지 않음을 보장).
- changeset 선언: 새 changeset(diff/commit range)을 선언하고 변경 범위를 round summary에 기록한다.

## Step 8 상세: push

predicate 충족 종료(`termination_type=CONVERGED` — all clear 특수형 포함 — 또는 `DEFERRED_EXIT`)에 도달하면 최종 승인 후 push한다. `ROUND_LIMIT`·`USER_STOP` 종료는 자동 push 대상이 아니다 — 미해결 상태를 보고하고 사용자에게 위임한다. push 전 walkthrough delta가 마지막 commit에 포함됐는지 확인한다. 네트워크 가능 환경 + GitHub auth 전제이며, `sandbox_mode=danger-full-access` 또는 GitHub 커넥터 경로에서만 자동 실행한다. 다른 샌드박스 모드에서는 명시적 사용자 승인 후 수행하거나, 메인 에이전트가 사용자에게 위임한다 ([`../SKILL.md#non-goals`](../SKILL.md#non-goals) 참조).
