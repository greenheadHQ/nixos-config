---
name: review-pr-feedback
description: |
  Evaluate and address feedback on a pull request, including CodeRabbit reviews, replies, and thread resolution.
  Use for PR feedback handling; PR body editing uses create-pr, and new reviews use the runtime’s built-in review.
---

# PR 리뷰 피드백 처리

PR에 달린 모든 리뷰 코멘트를 수집하고, 각 피드백을 다각도로 검증하여
유효한 것만 코드에 반영한 뒤, 모든 피드백에 답글·resolve·재확인까지 끝낸다.

## 빠른 참조

| 항목 | 설명 |
|------|------|
| 입력 | 현재 브랜치의 PR 또는 PR 번호/URL |
| 출력 | 유효 피드백 반영 커밋 + 전체 피드백 답글 + resolve 재확인 |
| 대상 | CodeRabbit, AI 리뷰어, 인간 팀원의 모든 코멘트 |
| 핵심 도구 | gh CLI, GraphQL reviewThreads, 코드베이스 검색 |

| 참고 레퍼런스 | 위치 |
|---------------|------|
| 수집 쿼리/pagination/REST 보조 정본 | [references/comment-collection.md](references/comment-collection.md) |
| 기각 7개 분류 + 오분류 방지 사례 | [references/rejection-taxonomy.md](references/rejection-taxonomy.md) |
| 답글/resolve mutation + multiline 전송 + retry 정책 | [references/reply-and-resolve.md](references/reply-and-resolve.md) |

## 용어 정책

이 스킬은 Claude Code와 Codex에서 현재 세션의 질문·파일 읽기·검색 도구를 사용한다.

| 용어 유형 | 처리 |
|----------|------|
| 사용자 질문 실행 지시 | "질문 도구" |
| 파일 읽기 지시 | "파일 읽기 도구" |
| 검색 지시 | 명시적 셸 명령 (`rg -n`, `git diff`) |

## 절차

### Step 1: PR 코멘트 수집 (GraphQL-first)

현재 브랜치의 PR을 찾고, review thread와 PR 일반 코멘트를 모두 수집한다.

```bash
# 현재 브랜치의 PR 번호 확인
gh pr view --json number -q .number
```

- Review thread는 GraphQL `reviewThreads` 쿼리로 한 번에 수집한다.
  각 thread의 `id` / `isResolved` / `isOutdated` / `path` / `line` / 내부 comments를 받는다.
- PR 일반 코멘트(대화 탭)는 REST `/issues/{pr}/comments`로 보조 수집한다.
- Review 요약(`/pulls/{pr}/reviews`)은 `state`와 `body`를 함께 수집한다. 상태별 분기와 APPROVED 전용 approval-only exact-match 규칙은 [comment-collection.md](references/comment-collection.md)를 따른다. 길이로 실제 피드백을 버리지 않으며 mixed 승인 body는 유지한다. 같은 지적은 thread/일반 코멘트 경로를 우선하고 summary-only에만 follow-up을 남긴다.
- `isResolved == false`인 thread를 actionable로 간주한다. `isOutdated == true`는 수집하되 Step 2에서 `STALE_REVIEW` 후보로 분류한다.
- `thread.id`는 Step 6 review thread mutation 입력에 반드시 필요하므로 보관한다.
  `comment.id`는 개별 코멘트 단위로 REST reply 엔드포인트를 쓰는 선택 경로에서만 쓴다.

상세 쿼리 템플릿, pagination, 수집 매트릭스는 [references/comment-collection.md](references/comment-collection.md)가 정본이다.

### Step 2: 코멘트 분류

Step 1 수집 결과가 모두 비어 있을 때만 no-op로 종료한다 (Step 3-7 건너뛰기).
"모두 비어 있음"은 다음 세 조건을 동시에 만족하는 상태다.

- `unresolved review thread == 0`
- PR 일반 코멘트 (`/issues/{pr}/comments`) 중 actionable == 0
- actionable review summary == 0 (= Step 1 분기를 통과해 actionable 후보로 남은 summary 개수. `DISMISSED`/`PENDING`과 body empty, `APPROVED` + approval-only 판정 해당 건은 제외)

위 셋 중 하나라도 있으면 분류를 진행한다. 특히 리뷰어가 inline thread 없이
summary body에만 reject/nit/follow-up 사유를 남기는 패턴은 thread/issue-comment
카운트만으로는 보이지 않으므로 summary `state` + `body`를 반드시 함께 본다.
`CHANGES_REQUESTED`/`COMMENTED`의 짧은 body("Breaks CI.", "Revert this.")도
length heuristic 없이 actionable로 포함된다. `APPROVED`의 순수 승인 메시지
("LGTM", "👍")만 exact-match 판정으로 걸러지며, `APPROVED` + `"fix the typo"`
같은 짧은 실제 피드백은 승인 구절 목록과 정확히 일치하지 않으므로 그대로
actionable로 유지된다 — approval이 걸렸다는 이유로 유효한 피드백을 버리지 않는다.
actionable summary-only 리뷰의 응답 경로는 Step 6의 PR top-level follow-up이다.

비어 있지 않으면 각 코멘트/summary를 다음 3개 카테고리로 분류한다.

| 카테고리 | 설명 | 기본 처리 |
|----------|------|----------|
| actionable | 코드 변경이 필요한 실질적 피드백 | Step 3 검증 후 반영 |
| outside-diff | 이번 PR diff 범위 밖의 지적 | 별도 이슈로 분리하거나 `SCOPE_DEFERRAL` 기각 |
| nitpick | 스타일/취향 수준의 사소한 지적 | 합리적이면 반영, 아니면 기각 |

분류가 애매한 코멘트는 actionable로 분류하여 Step 3에서 면밀히 검증한다.
기각 사유를 구분할 때는 [references/rejection-taxonomy.md](references/rejection-taxonomy.md)를 참고한다.

### Step 3: 다각도 검증

현재 head의 관련 코드와 호출부를 읽어 실제 문제인지 확인한다. 재현·테스트·설정 조회 중 지적을 검증하는 데 필요한 방법을 사용한다. 제안한 수정이 기존 동작·유효한 설계 제약을 깨뜨리는지, 비용과 범위가 적절한지 판단한다.

이전 diff에만 해당하는 지적과 현재 코드에서 검증한 오탐을 구분한다. [기각 분류](references/rejection-taxonomy.md)는 설명에 도움이 될 때 사용한다.

### Step 4: 유효 피드백 반영

검증 기준을 통과한 피드백만 코드에 반영한다.

- 각 피드백별로 필요한 코드 변경을 수행한다.
- 변경 후 기존 기능에 회귀가 없는지 확인한다.
- 관련된 피드백들은 가능하면 하나의 논리적 단위로 묶어 변경한다.
- 최종 동작이나 중요한 결정이 달라졌으면 PR 본문도 현재 구현과 근거에 맞게 갱신한다.

### Step 5: 커밋 및 푸시

반영한 변경 사항을 커밋하고 원격에 푸시한다.

- 커밋 메시지에 어떤 피드백을 반영했는지 명시한다.
- conventional commit 형식을 따른다 (예: `fix(module): address PR feedback`).
- 반영할 피드백이 여러 영역에 걸쳐 있으면 논리적으로 분리하여 복수 커밋으로 나눈다.

### Step 6: 답글 + resolve

모든 피드백(반영 여부 무관)에 대해 사유를 담은 답글/follow-up을 남기고 review thread는 resolve한다.
분기 요약만 여기 둔다. 구체 mutation, multiline body 전송 규칙, `mktemp` 처리,
반례는 [references/reply-and-resolve.md](references/reply-and-resolve.md)가 정본이다.

각 thread 처리 전에 다음 가드를 적용한다.
- thread.id가 null/empty → Step 6/7을 건너뛰고 사용자 보고 대상으로 분리.
- preflight requery: reply 직전 `thread.id`로 최신 `isResolved`와 최신 comments를 다시 조회하고, 결과에 따라 reply / resolve를 독립적으로 분기한다.
  - `isResolved=true` → 전체 no-op (이미 완료).
  - `isResolved=false` + 이번 run이 남긴 답글 존재 → reply는 skip, resolve는 반드시 수행 (이전 run이 reply 성공 + resolve 실패로 중단된 케이스 복구).
  - `isResolved=false` + 답글 없음 → reply + resolve 순차 수행.

| 대상 | 액션 |
|------|------|
| Review thread | `addPullRequestReviewThreadReply` → `resolveReviewThread` |
| PR 일반 코멘트 | `addComment` 또는 REST `/issues/{pr}/comments`로 PR에 top-level follow-up 코멘트 추가. resolve 없음. 원 코멘트 URL/`@<author>` 멘션으로 연결 |
| Actionable review summary (inline thread 없음, body != empty; `CHANGES_REQUESTED`/`COMMENTED`는 길이 무관, `APPROVED`는 승인 구절 목록과 exact-match 아닌 경우) | `addComment` 또는 REST `/issues/{pr}/comments`로 PR에 top-level follow-up 코멘트 추가. 원 review URL(`pull/<n>#pullrequestreview-<id>`)과 `@<reviewer>` 멘션으로 연결. resolve 없음. `"Breaks CI."` 같은 짧은 reject 사유, `"LGTM, but ..."` mixed 승인 body, `APPROVED` + `"fix the typo"` 같은 짧은 실제 피드백 모두 대상 |

처리 결과별 답글 내용:

| 처리 결과 | 답글 내용 |
|----------|----------|
| 반영 | 어떻게 반영했는지 간략 설명 + 커밋 해시 참조 + 검증 내역 |
| 기각 | 판단 이유와 확인한 기술적 근거. 불확실한 범위가 있으면 명시 |
| 별도 이슈 분리 | 생성한 이슈 번호 링크 + `SCOPE_DEFERRAL` 분류 |

### Step 7: resolve 재확인

`resolveReviewThread` mutation 응답의 `thread.isResolved`를 먼저 확인한다.
`true`면 통과, `false`이거나 필드가 누락됐을 때만 동일 `thread.id`로 재조회하여 확정한다.
쿼리 스니펫과 retry/실패 정책은 [references/reply-and-resolve.md](references/reply-and-resolve.md)의 "Retry policy"가 정본이다.
`thread.id`가 null/empty인 thread는 이 단계를 건너뛰고 사용자 보고 대상으로 남긴다.
PR 일반 코멘트는 resolve가 없으므로 이 단계를 건너뛴다.

## 검증 의무

- 리뷰어 각 지적을 수용하기 전에 해당 파일:줄을 직접 파일 읽기 도구로 읽어 사실성을 확인한다.
- 가능하면 로컬에서 재현을 시도한다 (빌드, 명령 실행, 설정 확인 등).
- "리뷰어가 지적했으니 맞겠지"라는 가정으로 검증 없이 수용하지 않는다.
- 사용자 판단이 필요한 경우 확인한 맥락과 추천을 설명하고 질문 도구로 한 번에 한 결정씩 묻는다.

## 주의사항

- 모든 피드백에 답글 필수: 반영하든 기각하든 사유를 명시한 답글을 남긴다. 무응답 금지.
- resolve 완료는 mutation 응답의 `thread.isResolved=true`로 확인한다. false 또는 필드 누락일 때만 Step 7 재조회·필요한 1회 retry를 적용한다.
- AI 리뷰어 맹신 금지: CodeRabbit 등 AI 리뷰어 피드백도 동일한 검증 기준을 적용한다.
  stale diff 기반 지적을 `HALLUCINATION`으로 오분류하지 말고 `STALE_REVIEW`를 쓴다.
- outside-diff 처리: PR 범위 밖 지적은 유효해도 이번 PR에서 처리하지 않는다.
  남은 문제와 이관 이유를 답글로 남기고, 별도 이슈 게시가 승인된 경우에만 생성한다.
- 반영 전 회귀 확인: 피드백 반영 시 변경이 다른 기능을 깨뜨리지 않는지 확인한다.
  특히 플랫폼 간(macOS/NixOS) 호환성에 주의.
- 기각 사유는 구체적으로: "불필요합니다"가 아니라 왜 불필요한지 근거 제시.
  고정 양식보다 판단을 뒷받침하는 코드·검증 근거를 제시한다.
- multiline body는 파일/stdin 경유: 본문을 shell 확장으로 argv에 싣지 않는다 (같은 사용자 `ps`/로깅 노출 방지).
  [references/reply-and-resolve.md](references/reply-and-resolve.md)의 권장 패턴(`gh api graphql -F body=@"$BODY_FILE"`, 또는 `jq -Rs '{body:.}' < "$BODY_FILE" | gh api --input -`)을 사용한다.
