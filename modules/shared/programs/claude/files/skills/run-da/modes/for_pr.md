# Mode: for_pr

구현 후 코드 DA 1회 — git diff 대상.

`for_pr`은 `for_plan`과 step 구조가 동일하다. 입력(diff vs 계획), 임시 디렉토리 prefix, write phase의 코드 수정+커밋 방식, Step 8 push만 다르다. 동일 절차는 [`./for_plan.md`](./for_plan.md)를 참조하고, 본 파일은 차이점만 step 번호별로 명시한다.

호출 단위 실행 프로파일과 사용자 지정 실행 파라미터(model/effort/tier)는 [`../SKILL.md`](../SKILL.md)의 정의가 정본이다. 예: `run-da for_pr agent=codex-xhigh`.

## Step 번호별 delta (vs for_plan)

| Step | for_plan | for_pr (delta) |
|------|----------|----------------|
| Step 0 | 동일 | Review Intensity 입력은 `git diff --stat main...HEAD` (계획 요약 대신) |
| Step 1 | 계획 내용 수집 | diff preflight + workspace baseline 기록 + diff 수집 — 체크포인트별 절차는 아래 "Step 1 상세: diff preflight + workspace baseline" 절 참조 |
| Step 2 | reviewer prompt에 계획 원문 포함 | reviewer prompt에 diff를 `<git-diff>` 태그로 감싸서 포함 + "diff 외부의 관련 파일도 직접 읽어 탐색하라" 지시 |
| Step 2 (codex exec) | `DA_DIR=$(mktemp -d /tmp/da-${_DA_SID}-plan-XXXXXX)` | `DA_DIR=$(mktemp -d /tmp/da-${_DA_SID}-pr-XXXXXX)` (`-pr-` prefix). 후속 prompt/exec 호출은 for_plan Step 2와 동일하게 stdout `DA_DIR` 리터럴 재설정 + `[ -d "$DA_DIR" ]` / `[ -f "$DA_DIR/$UNIT.md" ]` guard를 적용 |
| Step 3 | 동일 | 동일 ([`./for_plan.md`](./for_plan.md#step-3-reviewer-결과-수신--종합-리포트)) |
| Step 4 | 동일 (ALL CLEAR) | 동일 |
| Step 5 (Arbiter) | for_plan 조립 (계획 원문 포함) | for_pr 조립 (diff 컨텍스트 포함) — [`../references/arbiter-prompt.md`](../references/arbiter-prompt.md)의 "프롬프트 조립 > for_pr 모드" 참조. for_pr에서는 계획 원문 대신 diff 또는 변경 컨텍스트를 포함 |
| Step 5 상태 전이 | CONFIRMED_ISSUE를 pending write queue에 추가, eligible NOT_AN_ISSUE/사용자 제외는 dismissal ledger에 기록 | 동일. review phase 중 patch 금지, formatter write 금지, generated output 변경 금지. 코드 수정/commit은 Step 6 write phase 전까지 금지. dismissal ledger 기록은 tracked diff가 아닌 local ignored review metadata로만 허용 |
| Step 6 write phase | 통합 반영 루프(통합 설계→batch 반영→walkthrough→후속 수정 처리→finalize) 후 계획 확정·새 changeset 선언 | 동일 루프를 코드에 적용하되 commit·dirty 겹침 게이트·baseline 검증이 추가된다 — 순서와 조건은 아래 "Step 6 상세: for_pr write phase" 절 참조 |
| Step 7 | 수렴 predicate 충족까지 반복 (protocol.md "수렴 판정" SSOT + "최대 라운드 수" 적용: 상한 + 한계효용 + 비수렴 조기중단 + read/write 분리) | 동일 |
| Step 8 | (없음) | push — 수렴 종료 후 최종 승인을 받아 push한다. push 전 walkthrough delta가 마지막 commit에 포함됐는지 확인한다 (네트워크/auth 정책 의존 — [`../SKILL.md#non-goals`](../SKILL.md#non-goals) 참조) |

## Step 1 상세: diff preflight + workspace baseline

체크포인트는 이름으로 참조한다. 순서대로 수행한다:

- 미커밋 구현 차단: branch diff(`git diff main...HEAD`)의 공백 여부와 무관하게, workspace의 staged/unstaged/untracked 변경 중 이번 리뷰 대상 구현에 속하는 것이 하나라도 있으면 진행하지 않고 커밋을 요청한다 — 미커밋 구현 전체 또는 커밋된 구현 위의 미커밋 후속 수정이 리뷰 diff·push에서 조용히 빠지는 것을 차단한다. 리뷰 대상과 무관한 사용자 변경만 baseline으로 허용한다.
- baseline 기록: `git status --porcelain=v1 -z --untracked-files=all`로 파일 단위 경로를 수집하고(untracked 디렉터리 축약 방지), tracked dirty 경로의 diff 내용과 untracked 파일 hash를 repo 밖 scratch에 저장한다 (finalize의 내용 대조 기준).
- diff 수집: `git diff main...HEAD`로 수집해 프롬프트에 직접 포함한다 (exec 우회 패턴). diff가 과도하게 크면 (`git diff main...HEAD | wc -l`로 확인) 기계적 변경(flake.lock, hash 변경 등)을 필터링한 축약 diff를 사용한다 (`git diff main...HEAD -- ':!flake.lock'`로 lock 파일 제외 가능).
- baseline 재수집 규칙: 이후 단계에서 사용자가 workspace 상태를 바꾸는 선택(커밋/stash 후 재개 등)을 하면, 위 미커밋 구현 차단·baseline 기록을 다시 수행해 baseline을 갱신한다 — 이후 모든 대조는 갱신된 baseline 기준이다 (낡은 baseline과의 비교는 정당한 재개 경로를 위반으로 오인한다).

## 공통 절차 (for_plan SSOT)

위 delta 표에 적힌 차이를 제외한 모든 단계의 본문은 [`./for_plan.md`](./for_plan.md)가 SSOT다 — 여기서 재요약하지 않는다. for_pr 전용 차이는 delta 표와 위·아래 상세 절 세 곳(Step 1 / Step 6 / Step 8)에서만 소유한다.

for_pr에서 입력만 달라지는 공통 단계는 다음 둘뿐이다 (절차 자체는 for_plan과 같다):

- Step 1의 의사결정 컨텍스트 팩 수집: [`../references/decision-regression-audit.md`](../references/decision-regression-audit.md) Step A의 입력이 계획 원문 대신 `git diff main...HEAD`다. `fresh` 반복 세션의 dismissal ledger load도 frozen `git diff main...HEAD` + workspace review surface hash와 exact match할 때만 유효하다.
- Step 0의 Review Intensity 입력: delta 표 참조.

## Step 6 상세: for_pr write phase

for_plan의 통합 반영 루프에 다음 for_pr 전용 체크포인트를 더한다. 체크포인트는 이름으로 참조한다:

- pre-write 기록: write phase 시작 시 `git rev-parse HEAD`를 `pre_write_sha`로 기록한다 (protocol.md revalidation `batch-delta-intensity` 조건의 batch delta 입력 기준).
- 경로 상태 정의: write phase는 세 경로 집합을 구분해서 다룬다. 하나로 합치면 "건드려도 되는 곳"과 "실제로 바뀐 곳"이 섞여, 계획했다가 결국 수정하지 않은 경로가 finalize 대조를 실패시키거나 승인 경로만 예외 처리할 수 없게 된다.
  - `authorized_paths`: 이 write phase가 수정해도 되는 경로. 초기값은 통합 설계가 정한 round_write_set의 수정 대상이며, ①walkthrough 후속 수정이 만든 새 경로 ②formatter/generator가 만든 generated output 경로 ③겹침 게이트에서 승인된 혼입 경로를 그때마다 추가한다. ①②는 아래 게이트 재적용을 통과한 뒤에 추가한다 — 게이트를 통과하지 못한 경로는 애초에 쓰지 않는다.
  - `approved_mixed_paths`: 겹침 게이트에서 사용자가 혼입을 승인한 경로 (`authorized_paths`의 부분집합). finalize의 workspace 불변 대조에서 이 집합만 제외한다.
  - `actual_commit_paths`: finalize 직전에 산출하는 실제 변경 경로. 두 소스를 합친다 — tracked 변경은 `git diff --name-only --no-renames -z <pre_write_sha> --`(범위 표기 `..` 없이 — `<sha>..`는 `<sha>..HEAD`로 해석되어 작업트리를 보지 않으므로 write phase의 미커밋 변경이 전부 빠진다), untracked 신규는 `git status --porcelain=v1 -z --untracked-files=all`의 `??` 항목 중 `authorized_paths`에 속한 것(`git diff`는 untracked를 보지 않는다). 여기서 baseline의 기존 dirty/untracked 경로는 `approved_mixed_paths`를 빼고 제외한다. stage·commit·사후 대조의 기준은 계획이 아니라 이 집합이다 — walkthrough가 앞선 수정을 되돌려 최종 delta가 0인 경로는 여기서 자연히 빠진다. rename은 `--no-renames`로 source와 destination 두 경로로 펼쳐지므로 사후 대조와 표현이 일치한다.
  - 경로 정규화 (세 집합 공통): 모든 원소는 repo-relative canonical leaf 파일 경로여야 한다. `./foo`와 `foo` 같은 별칭, 절대경로, `..`가 든 경로는 정규화하고, 디렉터리 경로는 받지 않는다 (leaf 파일로 펼친다). 정규화 없이 문자열 집합만 비교하면 별칭이 겹침 검사를 통과한 뒤 Git pathspec으로는 같은 파일을 선택하고, 디렉터리 pathspec은 그 아래 사용자 파일까지 stage·commit한다.
- dirty 겹침 게이트 (통합 설계 시점): `authorized_paths`와 Step 1 baseline의 dirty/untracked 경로의 겹침을 검사한다 (정규화된 경로 기준 — 같은 파일이거나 한쪽이 다른 쪽의 상위 디렉터리면 겹침이다). 겹침이 없어야 finalize의 baseline 대조가 건전하다 (agent 수정 경로는 전부 commit되어 상태 변화로 드러난다). 겹치면 batch 반영을 시작하지 않고 질문 도구로 사용자 판단을 받는다. 선택지는 겹친 경로가 baseline에서 staged였는지로 갈린다:
  - stash 후 재개 (모든 겹침에서 가능): `HEAD`가 그대로이므로 이번 라운드의 frozen changeset이 유지된다. "Step 1 상세"의 baseline 재수집 규칙만 적용하고 라운드를 계속한다.
  - 커밋 후 재개: `HEAD`가 바뀌므로 이번 라운드가 리뷰한 frozen changeset과 실제 브랜치 상태가 달라진다. baseline만 갱신하고 계속하면 미검토 사용자 commit이 최종 push에 실려 나가고 `pre_write_sha..HEAD` batch delta도 그 commit을 포함하게 된다. 따라서 이 선택지는 현재 라운드를 폐기하고 Step 0부터 다시 시작하는 전이다 — 새 `HEAD` 기준으로 Intensity·diff·컨텍스트 팩·ledger를 다시 freeze하고 review phase부터 수행한 뒤, 새 write phase에서 `pre_write_sha`를 새로 기록한다. 이번 라운드의 pending write queue는 재검토 대상이 되므로 그대로 반영하지 않는다. 폐기된 라운드도 review phase를 이미 소비했으므로 protocol.md "최대 라운드 수"의 라운드 카운트에 포함하고, 폐기 사유를 round summary에 남긴다.
  - 혼입 명시 승인 (unstaged·untracked 겹침에서만 가능): 사용자 hunk가 agent commit에 섞일 위험을 고지하고 승인받은 뒤 그 경로를 `approved_mixed_paths`에 기록하고 `authorized_paths`에도 합류시킨다. finalize의 workspace 불변 대조에서 이 경로들은 제외하며(내용 변화가 승인된 결과다), 사용자 hunk가 commit에 포함된 사실을 round summary에 기록한다. staged 겹침에는 이 선택지를 제공하지 않는다 — 승인된 staged hunk는 commit으로 index에서 소비되어 finalize의 staged 보존 확인을 통과할 수 없으므로, staged 겹침은 stash 또는 라운드 재시작으로만 해소한다.
- 게이트 재적용 (후속 write 전): walkthrough 후속 수정·formatter/generator가 batch 반영 시점에 없던 새 경로를 쓰기 전에, 그 경로를 baseline dirty/untracked 목록과 다시 대조한다 — 초기 게이트만으로는 후속 write가 보호되지 않는다. 겹치면 위 게이트의 선택지별 전이를 동일하게 적용한다.
- finalize (walkthrough CLEAN 후) — 아래 체크를 순서대로 수행한다:
  1. 최종 diff 확인.
  2. 실제 변경 경로 산출 + 승인 범위 검사: 위 정의대로 `actual_commit_paths`를 산출하고, 이것이 `authorized_paths`의 부분집합인지 확인한다. 초과 경로가 있으면 승인 밖 변경이므로 commit하지 않고 중단·보고한다 (이 검사만이 commit 생성 전에 동작하는 경계다).
  - 빈 집합 분기: `actual_commit_paths`가 비면 아래 stage·commit·commit 경로 대조를 생략한다 (`git commit --only`는 경로 없이 호출할 수 없다 — 실측 `fatal: No paths with --include/--only does not make sense.`). 이 상태는 walkthrough가 batch 수정을 전부 되돌렸다는 뜻이므로 round_write_set이 해결됐다고 보지 않는다: 되돌린 이유를 walkthrough 후속 발견으로 기록하고, 해당 finding 수를 [`../references/protocol.md`](../references/protocol.md)의 `write_reverted_count`로 확정한다 (그 값이 0이 아니면 수렴 predicate가 막힌다). 새 changeset 선언도 하지 않는다.
  3. 신규 경로 stage: `actual_commit_paths` 중 Git이 아직 추적하지 않는 신규 파일·rename destination만 `git --literal-pathspecs add -- <해당 경로>`로 제한적으로 stage한다. path-limited commit은 Git이 이미 아는 경로만 커밋할 수 있으므로, 이 선행 없이는 신규 파일을 만드는 batch(테스트·fixture·generated output)의 commit이 pathspec 오류로 실패한다. 무관한 기존 staged 항목은 건드리지 않는다.
  4. commit: 메인 에이전트가 single-writer로 `git --literal-pathspecs commit --only -- <actual_commit_paths>` ([`../references/hardening-contract.md`](../references/hardening-contract.md)의 single-writer 정의. 경로 한정 커밋은 기존 index의 무관한 staged 사용자 항목을 포함하지도, 건드리지도 않는다 — 전역 index equality를 요구하면 무관한 staged 변경이 finalize를 영구 차단한다).
  5. commit 경로 대조: 생성된 commit의 경로 집합이 `actual_commit_paths`와 일치하는지 확인한다. 경로 목록은 `git diff-tree --no-commit-id --name-only --no-renames -r -z HEAD`로 얻어 NUL 단위로 비교한다 — rename detection이 켜진 출력(`git show --name-only`)은 rename을 destination 하나로 접어 source 경로를 숨기므로, batch가 rename을 포함하면 정상 commit도 집합 불일치로 오판된다. `--no-renames`는 rename을 delete+add 두 경로로 펼쳐 `actual_commit_paths`와 같은 표현을 만들고, `-z`는 newline이 든 경로가 두 원소로 쪼개지는 것을 막는다.

  6. staged 보존 확인: baseline의 기존 staged 상태가 그대로인지 확인한다 (겹침 게이트가 staged 경로의 혼입 승인을 제공하지 않으므로 예외가 없다).
  7. workspace 불변 대조: `git status --porcelain=v1 -z --untracked-files=all`을 현행 baseline과 비교해 write phase가 만든 새 미커밋 delta가 없는지 확인하고, baseline의 기존 dirty/untracked 경로(`approved_mixed_paths` 제외)는 저장해둔 diff 내용·hash와 대조해 내용이 변하지 않았는지 확인한다 (porcelain 상태 문자열은 내용 변화를 못 본다). 사용자의 기존 dirty/untracked 파일 자체는 차단 사유가 아니다 — 전역 clean을 요구하면 기존 파일이 finalize를 영구 차단하고, 이를 치우는 것은 hardening 계약 위반이다.

  `--literal-pathspecs`가 stage·commit에 붙는 이유: `--` 뒤의 인자도 여전히 pathspec으로 해석되므로 glob과 `:(exclude)` 같은 magic이 살아 있다. 그런 이름의 파일이 저장소에 실재하고 batch 대상이 되면, exclusion-only pathspec은 "pathspec 없이 호출한 전체 집합에서 제외"로 해석되어 baseline의 무관한 사용자 변경까지 stage·commit된다. 사후 경로 대조는 이미 만들어진 commit을 되돌리지 못하므로 명령 자체에서 리터럴 해석을 강제한다. 각 경로는 개별 argv로 전달한다 (경로 수가 많으면 `--pathspec-from-file`+`--pathspec-file-nul`).

- changeset 선언: 새 changeset(diff/commit range)을 선언하고 변경 범위를 round summary에 기록한다. walkthrough 후속 수정이 uncommitted로 남아 push에서 누락되거나 다음 라운드 preflight를 깨는 것을 구조적으로 방지한다.

## Step 8 상세: push

수렴 종료(ALL CLEAR 또는 CONVERGED — [`../references/protocol.md`](../references/protocol.md) 수렴 판정 SSOT)에 도달하면 최종 승인 후 push한다. push 전 walkthrough delta가 마지막 commit에 포함됐는지 확인한다. 네트워크 가능 환경 + GitHub auth 전제이며, `sandbox_mode=danger-full-access` 또는 GitHub 커넥터 경로에서만 자동 실행한다. 다른 샌드박스 모드에서는 명시적 사용자 승인 후 수행하거나, 메인 에이전트가 사용자에게 위임한다 ([`../SKILL.md#non-goals`](../SKILL.md#non-goals) 참조).
