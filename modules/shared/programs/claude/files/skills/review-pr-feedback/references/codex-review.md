# Codex 리뷰 봇 처리

Codex GitHub 앱의 PR 리뷰를 기다리고, 지적에 반응·답글을 남기고, 머지 전에 확인하는 절차의 정본이다. review-pr-feedback과 finish-pr가 이 문서를 따른다.

## 봇 식별

- 봇 계정은 `chatgpt-codex-connector`다. 조회 경로에 따라 `chatgpt-codex-connector[bot]`으로도 나오며, databaseId는 어느 경로에서나 `199175422`다.
- 같은 이름의 Organization 계정이 따로 있으므로 이름만으로 판정하지 않는다. `codex-review-status`는 login과 databaseId를 함께 확인한다.
- 봇은 check run을 만들지 않는다. CI 상태(`statusCheckRollup`)로는 리뷰가 끝났는지 알 수 없다.

## 상태 조회

`codex-review-status [<PR>] [-R OWNER/REPO] [--wait SECONDS] [--json]`는 조회만 하는 명령이다. PR 본문 반응, 요약 코멘트, 리뷰 객체, 한도·오류 코멘트를 조합해 상태를 판정하고 다음 값을 함께 낸다.

- `stale`: 봇이 리뷰한 커밋과 현재 head가 다르다.
- `rereview_requests`: 재리뷰 요청 코멘트 수.
- `unhandled_threads`: 답글·반응·resolve 중 빠진 것이 있는 봇 스레드와 빠진 항목(`missing`). 반응에 쓸 REST id는 `comment_id`다.
- `settings_warning`: 봇이 리뷰했어야 할 PR에 흔적이 없을 때의 설정 점검 안내.

트리거는 PR 생성, draft 해제, 재리뷰 요청 코멘트 중 가장 최근 것이고, 판정은 그 뒤의 신호만 센다.

| 상태 | 뜻 |
|------|----|
| `draft` | draft PR이라 봇이 리뷰하지 않는다. ready로 바꾸면 리뷰가 시작된다 |
| `pending` | 리뷰가 진행 중이거나 트리거 뒤 첫 신호를 기다리는 중이다 |
| `reviewed` | 봇이 인라인 지적을 남겼다 |
| `lgtm` | 봇이 지적 없이 리뷰를 마쳤다 |
| `limited` | Codex 사용량 한도로 리뷰하지 않았다 |
| `failed` | 봇이 오류, 계정 연결 안내, 알 수 없는 상태를 남겼다 |
| `timeout` | 트리거 뒤 대기 한도(`pending_timeout_seconds`, 현재 15분)가 지나도 진행 중이다 |
| `absent` | 트리거 뒤 `absent_after_seconds`(현재 2분)가 지나도 봇 흔적이 없다 |

- `pending`이면 `codex-review-status <PR> -R OWNER/REPO --wait 540`으로 기다린다. 한 번 호출로는 540초까지만 기다리므로 여전히 `pending`이면 다시 호출한다. 대기 한도가 지나면 도구가 `timeout`을 내므로 끝없이 기다리지 않는다.
- `settings_warning`이 있으면 사용자에게 Codex 코드 리뷰 설정(자동 리뷰, 트리거) 점검이 필요하다고 보고한다.
- 명령이 실패하면(exit 1) 출력된 원인(인증, 네트워크, PR 지정)을 고쳐 다시 조회한다. 해결하지 못하면 봇 상태를 모르는 채로 머지하지 않고 사용자에게 보고한다.

## 지적 처리

- 봇의 지적은 인라인 리뷰 스레드로 온다. 첫머리의 `P1`·`P2` 배지는 봇이 매긴 우선순위일 뿐이다. 둘 다 다른 리뷰어의 지적과 같은 기준으로 검증하고 반영 여부를 정한다.
- 봇이 남기는 고정 문구는 피드백이 아니라 상태 신호다. 다음은 actionable로 분류하지 않고 follow-up 코멘트도 남기지 않는다.
  - 리뷰 객체 본문(`Codex Review` 제목과 리뷰 커밋 표시)
  - 요약 코멘트(`<!-- codex-pull-request-review-summary -->` 표식과 상태 표)
  - 사용량 한도 안내, 계정 연결 안내, 오류 안내, 예전 형식의 지적 없음 코멘트
- 봇은 스레드 답글에 응답하지 않는다. 답글을 단 뒤 봇을 기다리지 않는다.

## 반응

봇의 인라인 지적에는 답글을 달기 전에 판정에 맞는 반응을 스레드 첫 코멘트에 단다. 반응은 Codex 리뷰 대시보드의 정확도 집계에 쓰인다. 이미 내 👍나 👎가 있으면 새로 달거나 바꾸지 않는다 — `unhandled_threads[].missing`에 `reaction`이 있는 스레드만 대상이다.

| 판정 | 반응 |
|------|------|
| 반영, 부분 반영 | 👍 |
| `SCOPE_DEFERRAL`, `STALE_REVIEW`, `DESIGN_TRADEOFF` | 👍 (지적 자체는 타당했다) |
| `HALLUCINATION`, `WRONG_REFERENCE`, `VERIFIED_FALSE_POSITIVE`, `TECHNICAL_DISAGREEMENT` | 👎 |

```bash
# COMMENT_ID는 unhandled_threads[].comment_id. 👎는 content=-1.
gh api -X POST "repos/$OWNER/$REPO/pulls/comments/$COMMENT_ID/reactions" -f content=+1
```

반응 뒤의 답글과 resolve는 다른 리뷰 스레드와 같다([reply-and-resolve.md](reply-and-resolve.md)).

## 봇 멘션 금지

PR·이슈 제목과 본문, 코멘트, 스레드 답글 어디에도 봇 멘션(`@codex`)을 쓰지 않는다. 백틱이나 인용 안에 있어도 봇이 작업 요청으로 읽어 클라우드 작업(새 PR 생성 등)을 시작한다. 봇을 가리킬 때는 "Codex 봇"처럼 멘션 없이 쓰고, 봇 작성 코멘트에 연결할 때도 작성자 멘션 대신 코멘트 URL을 쓴다. 예외는 아래 재리뷰 요청 한 가지이며, pinning-guard가 GitHub 게시 명령에서 이 규칙을 강제한다.

## 재리뷰 요청

봇이 리뷰한 커밋 뒤의 변경(`stale: true`)에 다음 중 하나가 있으면 재리뷰를 요청한다.

- 로직 변경
- 새 기능이나 새 파일
- 설계 변경

문서·주석·테스트만 바꾼 변경, 이름·오타 수정, 국소적인 P2 반영에는 요청하지 않는다. 요청은 PR당 한 번이다 — `rereview_requests`가 1 이상이면 다시 요청하지 않는다.

```bash
gh pr comment <PR> -R OWNER/REPO --body '@codex review'
```

이 한 줄 그대로 보낸다. 문구를 덧붙이거나 본문 파일로 보내면 pinning-guard가 막는다. 요청 뒤에는 상태가 다시 `pending`이 되므로 상태 조회 절차대로 기다린다.
