# DA dismissal ledger

`fresh` 모드의 anti-anchoring을 유지하면서 세션을 넘는 동일 false positive 재제기를 막기 위한 local ledger 규칙을 정의한다.

이 문서는 ledger의 저장 위치, key, schema, 기록 시점, `fresh` 모드 suppression, invalidation 규칙의 SSOT다. DA reviewer/Arbiter prompt 본문, Arbiter 판정 기준, pending write queue 규칙은 각각 [`da-domains.md`](da-domains.md), [`arbiter-prompt.md`](arbiter-prompt.md), [`protocol.md`](protocol.md)가 정본이다.

## 저장소 위치 결정

| 후보 | 장점 | 단점 | 판정 |
|------|------|------|------|
| repo tracked 파일 | 세션/머신 간 공유 가능, 리뷰어가 근거를 볼 수 있음 | PR 노이즈와 merge conflict가 잦고, false positive 근거가 장기 박제되며, 변경셋별 stale 판단 비용이 큼 | 기본값 아님 |
| ignored local ledger | 같은 worktree의 반복 `fresh` 세션에서 재사용 가능, PR diff를 더럽히지 않음, 네트워크/auth 불필요 | 다른 clone/runner에는 전파되지 않음, 로컬 cleanup 정책이 필요함 | 기본값 |
| PR comment ledger | PR 타임라인에 이력이 남고 clone 간 공유 가능 | GitHub auth/network 의존, PR comment update 권한 필요, 외부 서비스 장애와 정보 노출 위험, 로컬 plan DA에는 부적합 | 기본값 아님 |

기본 저장 위치는 repo-local ignored ledger다:

```text
.claude/da-ledger/<changeset-key>/<dismissal-key>.local.md
```

현재 repo root `.gitignore`는 `*.local.md`를 ignore하므로 위 파일명 suffix를 유지하면 ledger 파일은 tracked diff에 들어가지 않는다. 해당 ignore가 없는 clone에서는 ledger를 쓰기 전에 `.git/info/exclude` 같은 local-only ignore에 `.claude/da-ledger/` 또는 `*.local.md`를 추가한다. tracked 파일로 생성될 상황이면 ledger write를 생략하고 round summary의 NOTES에 남긴다.

## 기록 대상

ledger에 저장할 수 있는 항목은 아래뿐이다.

- Arbiter가 `NOT_AN_ISSUE`로 판정했고, `confidence`가 `HIGH` 또는 `MEDIUM`이며, `stability_status`가 `N/A` 또는 `stable`이고, 기술적 반증 근거가 있는 항목.
- 3회 반복 규칙 또는 사용자 판단 경로에서 사용자가 명시적으로 `제외 + 근거 기록`을 선택했고, 적용 범위와 기술적 근거가 있는 항목.

Plausibility FAIL 기각([`arbiter-prompt.md`](arbiter-prompt.md) 판정 우선순위)의 추가 조건: VERDICT_JSON의 `evidence_scope`가 `FROZEN_SURFACE`일 때만 영속 eligible이다 — 기각 근거가 frozen changeset surface의 불변 계약(코드 구조, 문서·설정 계약)에만 의존한다는 뜻이다. `ENVIRONMENT_WORKLOAD`(입력 규모, 배포 환경, 사용 경로 같은 환경·워크로드 가정 의존)이면 비영속 — 현재 루프 한정 suppress만 허용하고 ledger에 기록하지 않는다. 운영 조건이 바뀌면 과거에 비현실적이던 문제가 현실화될 수 있는데, ledger key에는 그 가정이 없어 조용히 계속 억제되는 것을 방지하기 위함이다. 이 분기는 구조화된 필드 하나로 판정한다 — 사람용 rationale을 재해석하지 않는다 (필드 정의·검증 규칙은 [`arbiter-prompt.md`](arbiter-prompt.md) 필드 의미와 [`protocol.md`](protocol.md) caller 검증).

저장하지 않는 항목:

- `NEEDS_MORE_INFO` 자체. 사용자 판단이 필요한 상태를 자동 기각으로 저장하지 않는다.
- LOW confidence `NOT_AN_ISSUE`가 fail-closed로 `NEEDS_MORE_INFO` 경로에 들어간 항목.
- `split`, `fragmented`, `partial_failure`, `unknown` 상태.
- "사용자 지시"만 있고 기술적 근거가 없는 제외.

## Changeset key

`changeset-key`는 frozen changeset이 바뀌면 달라져야 한다. 기본 구성:

| 필드 | 내용 |
|------|------|
| `mode` | `for_plan` 또는 `for_pr` |
| `base_commit` | `for_pr`: target branch와 `HEAD`의 merge-base. `for_plan`: 계획이 특정 diff/branch에 묶인 경우 그 base commit, 아니면 현재 `HEAD` |
| `surface_hash` | frozen changeset 전체의 hash. `for_pr`는 `git diff main...HEAD`와 review surface에 포함된 dirty/untracked content의 canonical hash. `for_plan`은 계획 원문과 Step 1에서 수집한 관련 context pack의 canonical hash |
| `target` | PR 번호/branch/계획 파일 경로처럼 사람이 scope를 식별할 수 있는 값 |

`surface_hash`는 ledger match의 핵심이다. hash를 계산할 수 없으면 ledger suppression을 사용하지 않는다.

## Dismissal key

`dismissal-key`는 같은 changeset 안에서도 같은 지적만 suppress하도록 좁게 잡는다. 아래 필드가 모두 일치해야 match다.

| 필드 | 내용 |
|------|------|
| `changeset_key` | 위 changeset key |
| `review_unit` | `Correctness`/`Design`/`Regression`/`Maintainability` 또는 `MAX` 세부 도메인 |
| `perspective` | `HALLUCINATION`, `SECURITY`, `YAGNI`, `SIDE_EFFECT`, `CONSISTENCY`, `READABILITY`, `NGMI`, `CLEAN_CODE` 등 |
| `location_identity` | `path:line` 또는 `plan item` 기준 위치. 가능하면 symbol/heading anchor와 해당 위치의 content hash를 함께 기록하되, line이 불명확하게 이동하면 stale로 본다 |
| `finding_fingerprint` | finding 요약을 정규화한 한 줄 요약의 hash. 같은 관점+위치라도 다른 failure mode면 match하지 않는다 |
| `scope` | 기본 `same_changeset`. 사용자가 명시한 경우에만 `current_loop` 같은 좁은 확장 scope 허용 |

동일성은 "같은 관점 + 같은 위치 + 같은 요약 fingerprint + 같은 changeset"이다. 관점과 위치만 같아도 요약 fingerprint가 다르면 새 finding으로 Arbiter에 보낸다.

## Ledger schema

ledger 파일은 사람이 읽을 수 있는 markdown에 아래 필드를 빠짐없이 기록한다. JSON/YAML front matter를 써도 되지만 실행 코드는 전제하지 않는다.

```yaml
schema_version: 1
created_at: "2026-07-06T00:00:00Z"
mode: for_pr
round: R1
changeset:
  base_commit: "<sha>"
  surface_hash: "<hash>"
  target: "PR #123 or branch"
review:
  review_unit: Regression
  perspective: SIDE_EFFECT
finding:
  location_identity: "modules/foo.nix:42"
  location_anchor: "option homeserver.foo.enable"
  finding_summary: "Changing the default enable path was claimed to break existing disabled installs."
  finding_fingerprint: "<hash>"
dismissal:
  verdict: NOT_AN_ISSUE
  source: arbiter
  confidence: HIGH
  stability_status: N/A
  rationale: "The option default remains false and the changed branch is only reached when explicitly enabled."
scope: same_changeset
```

사용자 제외 항목은 `dismissal.verdict: USER_EXCLUDED`, `dismissal.source: user`, `dismissal.user_decision: exclude_with_rationale`를 사용한다. `rationale`는 사용자가 승인한 기술적 근거를 적는다.

## 기록 시점과 phase 정합

ledger write는 active changeset을 수정하는 write phase 산출물이 아니다. local ignored review metadata다.

1. Step 1 changeset freeze 직후 current changeset key를 계산하고, 같은 key의 valid ledger entry만 load한다.
2. Step 2-5 review phase 중 reviewer/Arbiter는 active changeset을 바꾸지 않는다. ledger는 reviewer/Arbiter가 직접 쓰지 않는다.
3. Step 5e 상태 전이와 사용자 전건 보고가 끝난 직후, `NOT_AN_ISSUE` 또는 사용자가 명시 제외한 eligible 항목을 메인 에이전트가 ledger에 기록한다.
4. 이 기록은 pending write queue에 들어가지 않으며, Step 6 write phase batch 수정 범위나 generated output 범위에 포함하지 않는다.
5. ledger write가 tracked diff를 만들거나 local-only ignore를 보장할 수 없으면 기록하지 않고 NOTES에 "ledger write skipped"를 남긴다.

## `fresh` suppression 절차

`fresh` 모드는 이전 round/session transcript를 DA reviewer에게 전달하지 않는다. ledger 사용 시에도 finding 본문, Arbiter reasoning, 이전 round 요약은 reviewer prompt에 넣지 않는다.

절차:

1. Step 1에서 valid ledger entries를 읽는다. `fresh`가 아니어도 읽을 수 있지만, suppression은 `fresh` 반복 세션에서만 사용한다.
2. Step 2 reviewer prompt는 기존 `fresh` 규칙을 유지한다. 이전 발견, 수용/기각 내역, 이전 라운드를 암시하는 문구를 넣지 않는다.
3. Step 3 reviewer 결과 수집 후 Arbiter 진입 전에 메인 에이전트가 각 finding의 dismissal key를 계산한다.
4. valid ledger entry와 exact match하면 해당 finding을 `dismissed_suppressed`로 분류하고 Arbiter 입력 및 "new finding" 계산에서 제외한다.
5. match하지 않으면 평소처럼 Arbiter로 보낸다. 같은 위치라도 fingerprint, perspective, review unit, changeset 중 하나라도 다르면 suppress하지 않는다.
6. 사용자 보고와 round summary에는 `dismissed_suppressed` count와 key만 남긴다. finding 본문과 이전 reasoning은 재서술하지 않는다.

프롬프트에 ledger 정보를 넣어야 하는 예외적 런타임에서는 key, scope, `dismissed: NOT_AN_ISSUE|USER_EXCLUDED` 결론만 넣는다. finding 본문, 원 Arbiter reasoning, 이전 round transcript는 넣지 않는다.

## Invalidation

아래 조건 중 하나라도 맞으면 ledger entry는 stale로 보고 무시한다. 자동 삭제는 필요하지 않다.

- `base_commit` 또는 `surface_hash`가 current changeset과 다름.
- 대상 파일/계획 항목의 `location_identity`가 사라졌거나 line/anchor가 현재 content와 단일하게 대응되지 않음.
- `finding_fingerprint`가 현재 finding과 다름.
- `review_unit` 또는 `perspective`가 다름.
- `scope`가 현재 실행 범위를 포함하지 않음.
- schema 필수 필드, 기술적 `rationale`, Arbiter confidence/stability 정보가 누락됨.
- ledger 파일이 tracked 상태거나 tracked diff에 잡힘.
- verdict가 `NEEDS_MORE_INFO`, `split`, `fragmented`, `partial_failure`, `unknown` 중 하나임.

stale entry를 무시하면 기존 `fresh` 동작으로 돌아간다. ledger 디렉토리를 제거해도 suppression 없이 기존 `fresh` 리뷰가 실행되어야 한다.
