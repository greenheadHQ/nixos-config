# Mode: for_pr

구현 후 코드 DA 1회 — git diff 대상.

`for_pr`은 `for_plan`과 step 구조가 동일하다. 입력(diff vs 계획), 임시 디렉토리 prefix, write phase의 코드 수정+커밋 방식, Step 8 push만 다르다. 동일 절차는 [`./for_plan.md`](./for_plan.md)를 참조하고, 본 파일은 차이점만 step 번호별로 명시한다.

호출 단위 실행 프로파일과 사용자 지정 실행 파라미터(model/effort/tier)는 [`../SKILL.md`](../SKILL.md)의 정의가 정본이다. 예: `run-da for_pr agent=codex-xhigh`.

## Step 번호별 delta (vs for_plan)

| Step | for_plan | for_pr (delta) |
|------|----------|----------------|
| Step 0 | 동일 | Review Intensity 입력은 `git diff --stat main...HEAD` (계획 요약 대신) |
| Step 1 | 계획 내용 수집 | diff preflight + 수집: ①리뷰 대상 구현이 커밋되어 있는지 확인한다 — branch diff(`git diff main...HEAD`)의 공백 여부와 무관하게, baseline의 staged/unstaged/untracked 변경 중 이번 리뷰 대상 구현에 속하는 것이 하나라도 있으면 진행하지 않고 커밋을 요청한다 (미커밋 구현 전체 또는 커밋된 구현 위의 미커밋 후속 수정이 리뷰 diff·push에서 조용히 빠지는 것을 차단. 리뷰 대상과 무관한 사용자 변경만 baseline으로 허용) ②workspace baseline을 기록한다 — `git status --porcelain=v1 -z --untracked-files=all`로 파일 단위 경로를 수집하고(untracked 디렉터리 축약 방지), tracked dirty 경로의 diff 내용과 untracked 파일 hash를 repo 밖 scratch에 저장한다 (finalize 내용 대조 기준) → `git diff main...HEAD`로 diff 수집. diff를 프롬프트에 직접 포함 (exec 우회 패턴). diff가 과도하게 크면 (`git diff main...HEAD \| wc -l`로 확인) 기계적 변경(flake.lock, hash 변경 등)을 필터링한 축약 diff 사용 (`git diff main...HEAD -- ':!flake.lock'`로 lock 파일 제외 가능) |
| Step 2 | reviewer prompt에 계획 원문 포함 | reviewer prompt에 diff를 `<git-diff>` 태그로 감싸서 포함 + "diff 외부의 관련 파일도 직접 읽어 탐색하라" 지시 |
| Step 2 (codex exec) | `DA_DIR=$(mktemp -d /tmp/da-${_DA_SID}-plan-XXXXXX)` | `DA_DIR=$(mktemp -d /tmp/da-${_DA_SID}-pr-XXXXXX)` (`-pr-` prefix). 후속 prompt/exec 호출은 for_plan Step 2와 동일하게 stdout `DA_DIR` 리터럴 재설정 + `[ -d "$DA_DIR" ]` / `[ -f "$DA_DIR/$UNIT.md" ]` guard를 적용 |
| Step 3 | 동일 | 동일 ([`./for_plan.md`](./for_plan.md#step-3-reviewer-결과-수신--종합-리포트)) |
| Step 4 | 동일 (ALL CLEAR) | 동일 |
| Step 5 (Arbiter) | for_plan 조립 (계획 원문 포함) | for_pr 조립 (diff 컨텍스트 포함) — [`../references/arbiter-prompt.md`](../references/arbiter-prompt.md)의 "프롬프트 조립 > for_pr 모드" 참조. for_pr에서는 계획 원문 대신 diff 또는 변경 컨텍스트를 포함 |
| Step 5 상태 전이 | CONFIRMED_ISSUE를 pending write queue에 추가, eligible NOT_AN_ISSUE/사용자 제외는 dismissal ledger에 기록 | 동일. review phase 중 patch 금지, formatter write 금지, generated output 변경 금지. 코드 수정/commit은 Step 6 write phase 전까지 금지. dismissal ledger 기록은 tracked diff가 아닌 local ignored review metadata로만 허용 |
| Step 6 write phase | 통합 반영 루프(통합 설계→batch 반영→walkthrough→후속 수정 처리→finalize) 후 계획 확정·새 changeset 선언 | 동일 루프를 코드에 적용하되 commit·dirty 겹침 게이트·baseline 검증이 추가된다 — 순서와 조건은 아래 "Step 6 상세: for_pr write phase" 절 참조 |
| Step 7 | 수렴 predicate 충족까지 반복 (protocol.md "수렴 판정" SSOT + "최대 라운드 수" 적용: 상한 + 한계효용 + 비수렴 조기중단 + read/write 분리) | 동일 |
| Step 8 | (없음) | push — 수렴 종료 후 최종 승인을 받아 push한다. push 전 walkthrough delta가 마지막 commit에 포함됐는지 확인한다 (네트워크/auth 정책 의존 — [`../SKILL.md#non-goals`](../SKILL.md#non-goals) 참조) |

## 공통 절차 (for_plan과 동일)

다음은 `for_plan`과 100% 동일하다. 본문은 [`./for_plan.md`](./for_plan.md)를 SSOT로 한다:

- Step 0 본문: Review Intensity 판단 절차 ([`../references/intensity-procedure.md`](../references/intensity-procedure.md)).
- Step 1 본문 (의사결정 컨텍스트 팩 수집 + dismissal ledger load): 제거·단순화·되돌림·리팩터 또는 왕복 핫스팟이면 [`../references/decision-regression-audit.md`](../references/decision-regression-audit.md) Step A를 for_plan Step 1과 동일하게 수행한다 (입력만 계획 대신 `git diff main...HEAD`). 수집한 팩은 Step 2 reviewer·Step 5 Arbiter 프롬프트에 selective propagation으로 주입. `fresh` 반복 세션의 dismissal ledger load는 frozen `git diff main...HEAD` + workspace review surface hash와 exact match할 때만 유효하다.
- Step 2 본문 (Codex 세션 경로): capability profile에 따른 `spawn_agent`/`wait_agent`(+legacy 한정 `close_agent`) lifecycle과 batch 규칙 ([`../references/runtime-mapping.md`](../references/runtime-mapping.md#codex-native-lifecycle-capability-profile) SSOT), conservative wait, fresh modifier, selective propagation.
- Step 2 본문 (codex exec 경로): 임시 디렉토리, stdout `DA_DIR` 리터럴 재설정, prompt 파일 guard, `cat | env CODEX_PROGRAMMATIC=1 codex-exec-supervised --sandbox read-only --ignore-user-config --ignore-rules --ephemeral ... -` stdin pipe (Layer 1, [`../references/arbiter-scaling.md`](../references/arbiter-scaling.md) role별 명령 표가 SSOT), `&+wait` 금지, Claude Code 병렬 / headless serial foreground 구분, [`../references/runtime-mapping.md`](../references/runtime-mapping.md) 공통 주의(셸 호출 간 변수 유실).
- Step 3 본문: VIOLATION 처리, 결과 파일 검증, 실패 unit 재실행, `fresh` dismissal ledger exact match suppression.
- Step 5 (5a~5e): Arbiter 호출, selective consistency trigger 검사, N=3 재판정, vote-shape 집계, 상태 전이 적용. 상태 전이 구조(N/A·stable·split·fragmented 분기, NEEDS_MORE_INFO 사용자 판단 요청, fragmented BLOCKED)는 for_plan과 동일하다. CONFIRMED_ISSUE는 review phase 중 수정하지 않고 pending write queue로만 이동한다.
- Step 6: write phase 통합 반영 루프(통합 설계→batch 반영→walkthrough→후속 수정 처리→finalize), 새 reviewer 실행 단위, 새 `DA_DIR`. for_pr은 finalize에서 walkthrough CLEAN 후 commit까지 수행하고, 다음 라운드를 새 changeset으로 선언한다 (위 "Step 6 상세: for_pr write phase" 절 참조).
- Step 7: 수렴 predicate 탈출 조건 ([`../references/protocol.md`](../references/protocol.md) 수렴 판정 SSOT). 수렴까지 반복은 상한/조기중단/read-write 분리 규칙을 함께 적용한다.

## Step 6 상세: for_pr write phase

for_plan의 통합 반영 루프에 다음 for_pr 전용 체크포인트를 더한다:

1. write phase 시작: `git rev-parse HEAD`를 `pre_write_sha`로 기록한다 (protocol.md revalidation `batch-delta-intensity` 조건의 batch delta 입력 기준).
2. dirty 겹침 게이트 (통합 설계 시점): round_write_set의 수정 대상 경로와 Step 1 workspace baseline의 dirty/untracked 경로의 교집합을 검사한다. 겹치면 batch 반영을 시작하지 않고 질문 도구로 사용자 판단을 받는다 — 사용자가 해당 파일을 커밋/stash 후 재개하거나, 사용자 hunk가 agent commit에 섞일 위험을 고지받고 명시 승인. 겹침이 없어야 아래 baseline 비교가 건전하다 (agent 수정 경로는 전부 commit되어 상태 변화로 드러난다).
3. 게이트 재적용 (후속 write 전): walkthrough 후속 수정·formatter/generator가 batch 반영 시점에 없던 새 경로를 쓰기 전에, 그 경로를 baseline dirty/untracked 목록과 다시 대조한다 — 초기 게이트만으로는 후속 write가 보호되지 않는다.
4. finalize (walkthrough CLEAN 후): 최종 diff 확인 → 메인 에이전트가 single-writer로 `git commit --only -- <batch 경로>`로 커밋한다 ([`../references/hardening-contract.md`](../references/hardening-contract.md)의 single-writer 정의. 경로 한정 커밋은 기존 index의 무관한 staged 사용자 항목을 포함하지도, 건드리지도 않는다 — 전역 index equality를 요구하면 무관한 staged 변경이 finalize를 영구 차단한다) → 생성된 commit의 경로 집합(`git show --name-only`)이 batch 경로 집합과 일치하고 baseline의 기존 staged 상태가 그대로인지 확인한다 → `git status --porcelain=v1 -z --untracked-files=all`을 Step 1 baseline과 비교해 write phase가 만든 새 미커밋 delta가 없는지 확인하고, baseline의 기존 dirty/untracked 경로는 저장해둔 diff 내용·hash와 대조해 내용이 변하지 않았는지 확인한다 (porcelain 상태 문자열은 내용 변화를 못 본다). 사용자의 기존 dirty/untracked 파일 자체는 차단 사유가 아니다 — 전역 clean을 요구하면 기존 파일이 finalize를 영구 차단하고, 이를 치우는 것은 hardening 계약 위반이다.
5. 새 changeset(diff/commit range) 선언 + 변경 범위를 round summary에 기록. walkthrough 후속 수정이 uncommitted로 남아 push에서 누락되거나 다음 라운드 preflight를 깨는 것을 구조적으로 방지한다.

## Step 8 상세: push

수렴 종료(ALL CLEAR 또는 CONVERGED — [`../references/protocol.md`](../references/protocol.md) 수렴 판정 SSOT)에 도달하면 최종 승인 후 push한다. push 전 walkthrough delta가 마지막 commit에 포함됐는지 확인한다. 네트워크 가능 환경 + GitHub auth 전제이며, `sandbox_mode=danger-full-access` 또는 GitHub 커넥터 경로에서만 자동 실행한다. 다른 샌드박스 모드에서는 명시적 사용자 승인 후 수행하거나, 메인 에이전트가 사용자에게 위임한다 ([`../SKILL.md#non-goals`](../SKILL.md#non-goals) 참조).
