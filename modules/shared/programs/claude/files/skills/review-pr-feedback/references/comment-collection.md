# PR 코멘트 수집 플레이북

`review-pr-feedback` 스킬 Step 1의 정본. GraphQL `reviewThreads`를 primary로,
PR 일반 코멘트·리뷰 요약은 REST 보조로 수집한다.

## 수집 대상 매트릭스

| 코멘트 유형 | primary 소스 | resolve 개념 | 수집 목적 |
|-------------|--------------|-------------|----------|
| Review thread 코멘트 (diff 위 코멘트) | GraphQL `reviewThreads` | 있음 (`isResolved`) | 답글 + resolve + 재확인 |
| PR 일반 코멘트 (conversation 탭) | REST `/issues/{pr}/comments` | 없음 | 답글만 |
| Review 요약 (`state` + `body`) | REST `/pulls/{pr}/reviews` | 없음 | `CHANGES_REQUESTED`/`COMMENTED` + non-empty body는 길이 무관 actionable. `APPROVED` + non-empty body는 approval-only 판정 미해당일 때만 actionable. `DISMISSED`/`PENDING`과 body empty는 대상 아님 |

`isResolved` 필드는 REST `pulls/{pr}/comments` 응답에 없다. resolved 상태를 알려면 GraphQL이 필수다.
REST도 각 엔드포인트 조합으로 같은 수집이 가능하지만, 이 스킬은 단순성 때문에 위 분담을 기본으로 둔다.

## GraphQL reviewThreads 쿼리 (기본 템플릿)

```bash
# 환경 변수에 PR 정보를 넣어둔다. 값은 <owner>/<repo>/<pr_number>로 치환한다.
OWNER="<owner>"
REPO="<repo>"
PR_NUMBER=<pr_number>

# 첫 페이지: $cursor를 전달하지 않아 쿼리 기본값 null로 시작한다.
# GraphQL pagination은 `after: null`이 "처음부터"의 표준이고, 빈 문자열은 유효하지 않다.
gh api graphql \
  -f owner="$OWNER" -f repo="$REPO" -F pr="$PR_NUMBER" \
  -f query='
    query($owner: String!, $repo: String!, $pr: Int!, $cursor: String) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $pr) {
          reviewThreads(first: 50, after: $cursor) {
            pageInfo { hasNextPage endCursor }
            nodes {
              id
              isResolved
              isOutdated
              path
              line
              # root: thread의 opening comment(원 리뷰 요청). 21+ comment thread에서도 요구사항을 보존.
              root: comments(first: 1) {
                nodes {
                  id
                  author { login }
                  body
                  createdAt
                }
              }
              # latest: 최신 back-and-forth 맥락.
              latest: comments(last: 20) {
                pageInfo { hasPreviousPage startCursor }
                nodes {
                  id
                  author { login }
                  body
                  createdAt
                }
              }
            }
          }
        }
      }
    }'

# 후속 페이지: 앞 응답의 `endCursor`를 $cursor로 넘긴다.
gh api graphql \
  -f owner="$OWNER" -f repo="$REPO" -F pr="$PR_NUMBER" \
  -f cursor="$END_CURSOR" \
  -f query='...동일 쿼리...'
```

Thread pagination: 첫 호출은 `cursor`를 전달하지 않아 `null`로 시작하고,
응답의 `pageInfo.hasNextPage == true`인 동안 `endCursor`를 `-f cursor=...`로 넘겨 반복한다.
`-f cursor=""`는 빈 문자열로 직렬화되어 첫 페이지 요청을 깨뜨릴 수 있으므로 사용하지 않는다.

Thread 내부 comment는 기본 계약이 root 1개 (`first: 1`) + latest 20개 (`last: 20`)의 GraphQL alias 두 벌이다.
같은 thread에서 `comments`를 두 alias(`root`, `latest`)로 부르면 single round-trip으로 opening과 최신 맥락을 모두 받는다.
21개 이상 댓글이 달린 long back-and-forth thread에서도 opening comment(= 원 리뷰 요청, 실제 요구사항)가 누락되지 않는다.

완전한 thread 맥락(중간 구간까지)이 필요한 edge case에서만 `latest.pageInfo.hasPreviousPage == true`인 동안 별도 쿼리로 `comments(last: M, before: $startCursor)`를 반복하여 중간 페이지를 이어 붙인다.

## actionable set 정의

1. `isResolved == false` 인 thread를 actionable로 간주한다.
2. `isOutdated == true` 인 thread도 수집한다. `isOutdated`는 보조 신호일 뿐이며, actionable 여부는 Step 2/Step 3 검증으로 판단한다.
   - 지적이 여전히 유효(현재 코드에서도 문제) → `actionable`로 유지해 Step 4에서 반영하고 Step 6에서 답글 + resolve.
   - 이미 반영된 내용에 대한 지적 → `STALE_REVIEW`로 분류해 반영 참조 링크 답글 후 resolve. 자세한 분류 기준은 [rejection-taxonomy.md](rejection-taxonomy.md).
3. `isResolved == true` thread는 기본적으로 제외한다. 재확인이 필요하면 별도로 조회.

## PR 일반 코멘트 수집 (REST 보조)

```bash
# conversation 탭의 일반 코멘트
gh api --paginate "/repos/$OWNER/$REPO/issues/$PR_NUMBER/comments"

# review 요약 — state와 body 함께 수집 (actionable 분기 근거)
gh api --paginate "/repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews" \
  --jq '.[] | {id, state, body, user: .user.login, html_url}'
```

- Issue comment에는 `id`, `user.login`, `body`만 본다.
- Review summary는 `state`와 `body`를 함께 본다. body가 비어 있지 않으면 state를 primary로 분기한다.

  - `state == CHANGES_REQUESTED` 또는 `COMMENTED` + `body != empty` → actionable summary (길이 무관). `"Breaks CI."` / `"Revert this."` 같은 짧지만 명확한 reject/comment 사유도 length heuristic 없이 여기서 보존한다. Step 6 PR top-level follow-up으로 응답. `html_url`(또는 `pull/<n>#pullrequestreview-<id>` 형태)을 원 review 링크로 보관.
  - `state == APPROVED` + `body != empty`: 아래 approval-only 판정을 적용해 drop 여부를 결정한다. 판정 미해당 body(예: `LGTM, but consider X` / `approved — nit: ...`)는 actionable summary로 유지.
  - `state == DISMISSED` 또는 `PENDING` → 답글 대상 아님.

  approval-only 판정(`APPROVED` 전용 drop 규칙, exact-match only): `CHANGES_REQUESTED`/`COMMENTED`에는 적용하지 않는다. body를 다음 순서로 정규화한다.
  1. `trim()`으로 양끝 공백 제거.
  2. 소문자 변환.
  3. 양끝의 `.`, `!`, `?`, `~`, 공백을 반복 제거.

  정규화 결과가 아래 승인 구절 목록과 정확히 일치할 때만 drop한다. 목록 밖의 non-empty body는 길이에 관계없이 actionable로 유지한다.

  ```
  lgtm
  looks good
  looks good to me
  approved
  approve
  ok
  okay
  fine
  ship it
  👍
  👌
  ```

  length heuristic은 사용하지 않는다. `"fix the typo"`, `"rename foo()"` 같은 짧은 actionable `APPROVED` body가 false-positive로 drop되지 않도록 한다.
  summary에 actionable 내용이 있어도 동일 지적이 review thread나 일반 코멘트로 남아 있다면 그쪽 경로를 우선 사용한다.
  경계 케이스(`LGTM!` 뒤 추가 문장이 붙은 mixed body 등)는 정규화 결과가 승인 구절과 정확히 일치하지 않으므로 자동으로 actionable로 분류된다.

## 결과 정리 의무

수집한 후 다음 축으로 정렬해 Step 2로 넘긴다.

| 축 | 이유 |
|----|------|
| 파일별 | 관련 코드 근처 코멘트를 한 번에 검토 |
| 리뷰어별 | CodeRabbit / 인간 / 다른 AI 리뷰어의 패턴을 파악 |
| `thread.id` 보관 | Step 6의 `addPullRequestReviewThreadReply` / `resolveReviewThread` mutation 입력 |
| `comment.id` 보관 | 개별 코멘트 단위로 reply하려는 경우 REST 엔드포인트에 필요 |

## 자주 묻는 구분

- Issue ≠ Pull Request 코멘트가 별개인가? 아니다. GitHub 내부적으로 모든 PR은 Issue이기도 하므로 `/issues/{pr}/comments`가 PR 본문 아래 일반 코멘트를 돌려준다. 다만 review thread 코멘트는 `/pulls/{pr}/comments`로 들어오며, 둘은 서로 다른 스레드이다.
- 왜 GraphQL-first인가? `isResolved` 같은 review thread state를 REST는 주지 않는다. GraphQL 한 쿼리로 id·resolved·outdated·path·line·comments를 모두 받으므로 수집 단계에서 불필요한 왕복을 줄인다.
- REST로도 다 되나? 같은 데이터를 REST로도 구할 수 있지만, 여러 엔드포인트를 조합해야 하고 `isResolved`가 없다. 이 스킬은 단순성 때문에 REST 보조를 유지한다.

## Step 2로 넘기기 전 체크리스트

- [ ] `pageInfo.hasNextPage`가 false가 될 때까지 모든 thread 페이지 수집.
- [ ] 각 thread의 `id`, `isResolved`, `isOutdated`, `path`, `line` 보관.
- [ ] 각 thread의 root comment (opening, `first: 1`)와 latest comment 세트 (`last: 20`) 모두 보관. root는 원 리뷰 요청이므로 long thread에서도 요구사항 판별에 필수.
- [ ] PR 일반 코멘트 본문 보관 (답글 대상).
- [ ] Review summary는 `state`와 `body`를 함께 보관. 답글 대상 결정은 state가 primary:
  - `CHANGES_REQUESTED`/`COMMENTED` + non-empty body → actionable (길이 무관, 짧은 reject 사유도 보존).
  - `APPROVED` + non-empty body → 정규화 후 승인 구절 목록과 exact-match일 때만 drop, 그 외(길이 무관)는 actionable.
  - `DISMISSED`/`PENDING` 또는 body empty → 답글 대상 아님.
- [ ] resolved thread 제외 (또는 별도 버킷으로 분리).
