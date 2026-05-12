# 답글 + resolve + 재확인 playbook

`review-pr-feedback` 스킬 Step 6/7의 정본.
review thread와 PR 일반 코멘트는 API 모델이 다르므로 플로우가 갈린다.

## 플로우 요약

| 대상 | 답글 mutation | resolve | 재확인 |
|------|---------------|--------|-------|
| Review thread | `addPullRequestReviewThreadReply` | `resolveReviewThread` | `reviewThreads { isResolved }` |
| PR 일반 코멘트 (issues/{pr}/comments) | `addComment` 또는 REST `POST /issues/{pr}/comments` | 없음 (resolve 개념 없음) | 불필요 |

`addPullRequestReviewThreadReply`와 `resolveReviewThread`는 review thread 전용이다.
PR 본문 아래 대화 탭의 일반 코멘트에는 resolve 상태가 없으며, 답글만 남기고 종료한다.

## Review thread 플로우

### Preflight: guard + requery

- `thread.id` null/empty: 해당 thread를 reply/resolve 대상에서 제외하고 사용자 보고 대상으로 분리한다. 수집이 부분적으로 비었을 때 Step 6/7 입력 오류를 방지한다.
- 선택적 실행 분기: reply 직전 `thread.id`로 최신 `isResolved`와 최신 `comments`를 다시 조회하고, 결과에 따라 reply / resolve를 독립적으로 분기한다. 중복 reply는 억제하되 resolve는 필요 시 계속 진행하여 이전 run의 reply-성공/resolve-실패 상태를 영구 unresolved로 잠그지 않는다.

| 재조회 결과 | reply | resolve | Step 7 재확인 |
|---|---|---|---|
| `isResolved=true` | skip | skip | skip (이미 완료) |
| `isResolved=false` + 이번 run의 답글 이미 존재 | skip | 수행 | 수행 |
| `isResolved=false` + 답글 없음 | 수행 | 수행 | 수행 |

"이번 run의 답글"은 현재 PR 처리 run에서 봇/도구가 남긴 답글(`author.login`과 본문 패턴으로 식별 가능한 것)을 의미한다. 서로 다른 run이 병렬로 같은 thread를 잡은 경우에도 이 분기로 중복 reply를 피하면서 resolve 완결성을 보장한다.

### 답글: addPullRequestReviewThreadReply

필요 입력: `thread.id` (Step 1에서 수집한 `reviewThreads.nodes[].id`), `body`.

```bash
# $TID는 reviewThreads.nodes[].id. $BODY_FILE은 mktemp 또는 이미 만들어둔 reply 초안.
BODY_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE"' EXIT
cat > "$BODY_FILE" <<'REPLY'
반영했습니다. (<commit-hash>)

검증 내용:
- confirmed <file>:<line>
- added <fix>
- re-ran <verification command>
REPLY

gh api graphql \
  -f tid="$TID" \
  -F body=@"$BODY_FILE" \
  -f query='
    mutation($tid: ID!, $body: String!) {
      addPullRequestReviewThreadReply(input: {
        pullRequestReviewThreadId: $tid,
        body: $body
      }) {
        comment { id url }
      }
    }'
```

`-F body=@"$BODY_FILE"`은 gh CLI가 파일 내용을 읽어 GraphQL String variable로 직접 전달한다.
본문이 프로세스 argv에 실리지 않아 같은 사용자의 `ps`/로깅에 노출되지 않는다.
multiline과 따옴표, 백슬래시, 이모지는 GraphQL String escape가 안전하게 처리한다.

### Resolve: resolveReviewThread

```bash
gh api graphql \
  -f tid="$TID" \
  -f query='
    mutation($tid: ID!) {
      resolveReviewThread(input: { threadId: $tid }) {
        thread { id isResolved }
      }
    }'
```

응답의 `thread.isResolved`가 `true`면 성공으로 확정하고 Step 7은 추가 호출 없이 통과한다.
`false`일 때만 재조회 + retry 정책을 적용한다.

### 재확인 (Step 7, conditional)

mutation 응답이 `isResolved=true`였다면 재조회는 생략한다 (불필요한 API 호출 방지).
`isResolved=false`이거나 응답 필드가 누락된 경우에만 `thread.id`로 현재 상태를 다시 조회한다.

```bash
gh api graphql \
  -f tid="$TID" \
  -f query='
    query($tid: ID!) {
      node(id: $tid) {
        ... on PullRequestReviewThread {
          isResolved
        }
      }
    }' | jq '.data.node.isResolved'
```

`true`이면 통과. `false`이면 아래 retry 정책을 따른다.

## PR 일반 코멘트 플로우 (top-level follow-up)

review thread가 아닌 PR 본문 아래 대화 탭 코멘트에는 thread/resolve 개념이 없고,
`addComment`/REST `/issues/{pr}/comments`는 개별 코멘트에 귀속된 "답글"이 아니라
PR에 새 top-level follow-up 코멘트를 추가한다.

그래서 원 코멘트에 사유를 되돌려 주려면 follow-up 본문에 원 코멘트 URL 인용과
`@<author>` 멘션으로 연결해 컨텍스트를 잃지 않게 한다.

### REST 경로 (간단)

```bash
BODY_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE"' EXIT
# BODY_FILE 작성 시 원 코멘트 URL 인용과 @<author> 멘션을 포함한다.
#   > @<author> <원 코멘트 URL>
#   > 요약 인용: ...
jq -Rs '{body: .}' < "$BODY_FILE" \
  | gh api --input - \
      --method POST \
      "/repos/$OWNER/$REPO/issues/$PR_NUMBER/comments"
```

`jq -Rs '{body: .}'`는 파일 내용을 stdin으로 읽어 JSON으로 감싸므로 본문이 argv에 실리지 않는다.
`gh api --input -`가 그 stdin을 그대로 request body로 전송한다. newline/따옴표/이모지 모두 안전하게 JSON encode된다.

### GraphQL 경로

```bash
# $SUBJECT_ID는 PR의 Node ID. gh pr view --json id -q .id로 얻을 수 있다.
SUBJECT_ID="$(gh pr view "$PR_NUMBER" --json id -q .id)"

gh api graphql \
  -f sid="$SUBJECT_ID" \
  -F body=@"$BODY_FILE" \
  -f query='
    mutation($sid: ID!, $body: String!) {
      addComment(input: { subjectId: $sid, body: $body }) {
        commentEdge { node { id url } }
      }
    }'
```

`addComment`는 subject(PR)에 새 코멘트를 추가한다. 개별 코멘트에 귀속된 reply가 아니므로
follow-up 본문에서 원 코멘트 URL과 `@<author>` 멘션으로 연결한다.

## Multiline body 전송: 안전한 기본 경로와 반례

### 권장 default

본문을 shell 확장으로 argv에 싣지 말고, 파일/stdin으로 전달한다.

1. GraphQL file variable: `gh api graphql -F body=@"$BODY_FILE"` — gh가 파일 내용을 읽어 GraphQL String variable로 직렬화. 본문이 argv에 노출되지 않는다.
2. REST JSON via stdin: `jq -Rs '{body:.}' < "$BODY_FILE" | gh api --input -` — stdin으로만 body가 흐른다. argv 노출 없음.
3. 파일은 `mktemp` + `trap` 정리: 고정 경로(`/tmp/reply.md` 등)를 쓰지 말 것. `/tmp`는 world-writable sticky 디렉토리라 다른 프로세스의 파일을 재사용하거나 읽을 위험이 있다.

### 반례: REST `-f body="..."` 직접 전달 (PR #399 mishap)

```bash
# ❌ 이렇게 하지 말 것
gh api "/repos/$OWNER/$REPO/pulls/$PR_NUMBER/comments/$CID/replies" \
  -f body="line1
line2"
```

`gh api -f body="..."`는 shell에서 이미 확장된 멀티라인 리터럴을 그대로 넘긴다.
`gh help api`는 `-f/--raw-field`를 "request payload에 static string parameter 추가"로 설명하지만,
쉘/터미널 문맥에 따라 멀티라인 escaping이 의도와 다르게 처리되거나 엔드포인트별
기대 payload shape와 어긋날 수 있다. PR #399에서 multiline 답글 한 줄이 리터럴
이스케이프 상태로 전송된 이슈가 이 패턴이었다.
multiline/escaping을 명시적으로 통제하려면 본문을 파일/stdin으로만 전달하는
`jq -Rs '{body:.}' < "$BODY_FILE" | gh api --input -` 또는 `gh api graphql -F body=@"$BODY_FILE"`를
기본값으로 선호한다. 본문을 shell 확장(`"$BODY"` 같은 변수)으로 argv에 싣지 않는다.

수정된 기본값:

```bash
# ✅ 안전한 대체 — stdin JSON (body가 argv에 실리지 않음)
jq -Rs '{body: .}' < "$BODY_FILE" \
  | gh api --input - \
      --method POST \
      "/repos/$OWNER/$REPO/pulls/$PR_NUMBER/comments/$CID/replies"
```

## Retry policy

Step 7의 `isResolved=true` 재확인이 `false`를 돌려주는 경우의 정본 정책.
SKILL.md·다른 reference·Step 7 설명은 모두 이 앵커를 링크로 참조한다.

1. 1회 재시도: `resolveReviewThread`는 idempotent하므로 다시 호출해도 안전하다.
   API 일시 지연이나 eventual consistency 지연은 대부분 1회 재조회로 수렴한다.
2. 재시도 후에도 false: 즉시 사용자에게 보고. 자동 재시도를 반복하지 않는다.
   가능한 원인 — 권한 부족 (`viewerCanResolve=false`), bot 사용자 제한, 조직 정책.
3. 수동 확인 요청: 사용자에게 thread URL을 공유하고, 브라우저에서 직접 resolve 또는
   권한 재설정을 진행하도록 안내.

절대 무한 retry 루프를 돌리지 않는다. API 호출 비용과 rate limit 문제를 유발한다.

## 에지 케이스

| 상황 | 대응 |
|------|------|
| `viewerCanReply == false` | 답글 권한 없음. 수집 단계에서 미리 필드를 체크하거나, mutation 실패 시 NOTICE 답글을 대신 issue comment로 남긴다. |
| `viewerCanResolve == false` | resolve 권한 없음. 답글만 남기고 사용자에게 수동 resolve 요청. |
| thread가 outdated (`isOutdated=true`)인데 unresolved | 답글 + resolve는 그대로 가능. Step 2에서 `STALE_REVIEW`로 분류했다면 그 사유를 답글에 남긴다. |
| 동일 thread에 답글을 여러 개 달아야 함 | 모두 `addPullRequestReviewThreadReply`로 순차 호출 후 최종 resolve. |

## 체크리스트

- [ ] `thread.id`를 Step 1에서 정확히 수집했는가 (Step 6 mutation 입력).
- [ ] 답글 본문을 `mktemp` 기반 임시 파일에 작성했는가 (`/tmp/reply.md` 같은 고정 경로 미사용).
- [ ] `addPullRequestReviewThreadReply` 응답의 `comment.id`를 기록했는가 (추적 용도).
- [ ] `resolveReviewThread` 응답의 `thread.isResolved=true`를 1차 확인했는가.
- [ ] Step 7 재조회에서 동일하게 `isResolved=true`를 확인했는가.
- [ ] retry 1회 후에도 false이면 사용자 보고로 종료했는가.
