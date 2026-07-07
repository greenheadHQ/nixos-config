# Mode: for_pr

구현 후 코드 DA 1회 — git diff 대상.

`for_pr`은 `for_plan`과 7-step 구조가 동일하다. 입력(diff vs 계획), 임시 디렉토리 prefix, write phase의 코드 수정+커밋 방식, Step 8 push만 다르다. 동일 절차는 [`./for_plan.md`](./for_plan.md)를 참조하고, 본 파일은 차이점만 step 번호별로 명시한다.

호출 단위 실행 프로파일은 [`../SKILL.md`](../SKILL.md)의 `agent=` 정의가 정본이다. 예: `run-da for_pr agent=codex-xhigh`.

## Step 번호별 delta (vs for_plan)

| Step | for_plan | for_pr (delta) |
|------|----------|----------------|
| Step 0 | 동일 | Review Intensity 입력은 `git diff --stat main...HEAD` (계획 요약 대신) |
| Step 1 | 계획 내용 수집 | diff preflight + 수집: 변경사항이 커밋되어 있는지 확인 (`git status --porcelain`이 빈 출력이면 clean) → `git diff main...HEAD`로 diff 수집. diff를 프롬프트에 직접 포함 (exec 우회 패턴). diff가 과도하게 크면 (`git diff main...HEAD \| wc -l`로 확인) 기계적 변경(flake.lock, hash 변경 등)을 필터링한 축약 diff 사용 (`git diff main...HEAD -- ':!flake.lock'`로 lock 파일 제외 가능) |
| Step 2 | reviewer prompt에 계획 원문 포함 | reviewer prompt에 diff를 `<git-diff>` 태그로 감싸서 포함 + "diff 외부의 관련 파일도 직접 읽어 탐색하라" 지시 |
| Step 2 (codex exec) | `DA_DIR=$(mktemp -d /tmp/da-${_DA_SID}-plan-XXXXXX)` | `DA_DIR=$(mktemp -d /tmp/da-${_DA_SID}-pr-XXXXXX)` (`-pr-` prefix). 후속 prompt/exec 호출은 for_plan Step 2와 동일하게 stdout `DA_DIR` 리터럴 재설정 + `[ -d "$DA_DIR" ]` / `[ -f "$DA_DIR/$UNIT.md" ]` guard를 적용 |
| Step 3 | 동일 | 동일 ([`./for_plan.md`](./for_plan.md#step-3-reviewer-결과-수신--종합-리포트)) |
| Step 4 | 동일 (ALL CLEAR) | 동일 |
| Step 5 (Arbiter) | for_plan 조립 (계획 원문 포함) | for_pr 조립 (diff 컨텍스트 포함) — [`../references/arbiter-prompt.md`](../references/arbiter-prompt.md)의 "프롬프트 조립 > for_pr 모드" 참조. for_pr에서는 계획 원문 대신 diff 또는 변경 컨텍스트를 포함 |
| Step 5 상태 전이 | CONFIRMED_ISSUE를 pending write queue에 추가, eligible NOT_AN_ISSUE/사용자 제외는 dismissal ledger에 기록 | 동일. review phase 중 patch 금지, formatter write 금지, generated output 변경 금지. 코드 수정/commit은 Step 6 write phase 전까지 금지. dismissal ledger 기록은 tracked diff가 아닌 local ignored review metadata로만 허용 |
| Step 6 write phase | 계획/관련 파일을 batch로 수정하고 새 changeset 선언 | 코드 변경을 batch로 반영하고 커밋한다. 메인 에이전트가 single-writer로 코드 수정 + commit ([`../references/hardening-contract.md`](../references/hardening-contract.md)의 single-writer 정의). 반영 후 새 changeset(diff/commit range)을 선언하고 변경 범위를 round summary에 기록 |
| Step 7 | CLEAR까지 반복 (protocol.md "최대 라운드 수" 적용: 상한 + 한계효용 + 비수렴 조기중단 + read/write 분리) | 동일 |
| Step 8 | (없음) | push — 최종 승인 후 push한다 (네트워크/auth 정책 의존 — [`../SKILL.md#non-goals`](../SKILL.md#non-goals) 참조) |

## 공통 절차 (for_plan과 동일)

다음은 `for_plan`과 100% 동일하다. 본문은 [`./for_plan.md`](./for_plan.md)를 SSOT로 한다:

- Step 0 본문: Review Intensity 판단 절차 ([`../references/intensity-procedure.md`](../references/intensity-procedure.md)).
- Step 1 본문 (의사결정 컨텍스트 팩 수집 + dismissal ledger load): 제거·단순화·되돌림·리팩터 또는 왕복 핫스팟이면 [`../references/decision-regression-audit.md`](../references/decision-regression-audit.md) Step A를 for_plan Step 1과 동일하게 수행한다 (입력만 계획 대신 `git diff main...HEAD`). 수집한 팩은 Step 2 reviewer·Step 5 Arbiter 프롬프트에 selective propagation으로 주입. `fresh` 반복 세션의 dismissal ledger load는 frozen `git diff main...HEAD` + workspace review surface hash와 exact match할 때만 유효하다.
- Step 2 본문 (Codex 세션 경로): `spawn_agent`/`wait_agent`/`close_agent` lifecycle, batch 규칙, conservative wait, fresh modifier, selective propagation.
- Step 2 본문 (codex exec 경로): 임시 디렉토리, stdout `DA_DIR` 리터럴 재설정, prompt 파일 guard, `cat | env CODEX_PROGRAMMATIC=1 codex-exec-supervised --sandbox read-only --ignore-user-config --ignore-rules --ephemeral ... -` stdin pipe (Layer 1, [`../references/arbiter-scaling.md`](../references/arbiter-scaling.md) role별 명령 표가 SSOT), `&+wait` 금지, Claude Code 병렬 / headless serial foreground 구분, [`../references/runtime-mapping.md`](../references/runtime-mapping.md) 공통 주의(셸 호출 간 변수 유실).
- Step 3 본문: VIOLATION 처리, 결과 파일 검증, 실패 unit 재실행, `fresh` dismissal ledger exact match suppression.
- Step 5 (5a~5e): Arbiter 호출, selective consistency trigger 검사, N=3 재판정, vote-shape 집계, 상태 전이 적용. 상태 전이 구조(N/A·stable·split·fragmented 분기, NEEDS_MORE_INFO 사용자 판단 요청, fragmented BLOCKED)는 for_plan과 동일하다. CONFIRMED_ISSUE는 review phase 중 수정하지 않고 pending write queue로만 이동한다.
- Step 6: write phase batch 반영, 새 reviewer 실행 단위, 새 `DA_DIR`. for_pr은 batch 코드 수정 후 commit까지 수행하고, 다음 라운드를 새 changeset으로 선언한다.
- Step 7: CLEAR 탈출 조건. CLEAR까지 반복은 상한/조기중단/read-write 분리 규칙을 함께 적용한다.

## Step 8 상세: push

Arbiter Round N에서 모든 review unit이 CLEAR를 반환하면 최종 승인 후 push한다. 네트워크 가능 환경 + GitHub auth 전제이며, `sandbox_mode=danger-full-access` 또는 GitHub 커넥터 경로에서만 자동 실행한다. 다른 샌드박스 모드에서는 명시적 사용자 승인 후 수행하거나, 메인 에이전트가 사용자에게 위임한다 ([`../SKILL.md#non-goals`](../SKILL.md#non-goals) 참조).
