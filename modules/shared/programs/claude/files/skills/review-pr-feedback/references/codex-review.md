# Codex 리뷰 봇 처리

Codex GitHub 앱의 PR 리뷰를 기다리고, 지적에 반응·답글을 남기고, 머지 전에 확인하는 절차의 정본이다. review-pr-feedback과 finish-pr가 이 문서를 따른다.

## 봇 식별

- 봇 계정은 `chatgpt-codex-connector`다. 조회 경로에 따라 `chatgpt-codex-connector[bot]`으로도 나오며, databaseId는 어느 경로에서나 `199175422`다.
- 같은 이름의 Organization 계정이 따로 있으므로 이름만으로 판정하지 않는다. `codex-review-status`는 login과 databaseId를 함께 확인한다.
- 봇은 check run을 만들지 않는다. CI 상태(`statusCheckRollup`)로는 리뷰가 끝났는지 알 수 없다.

## 상태 조회

`codex-review-status <PR> -R OWNER/REPO --json`은 조회만 하는 명령이다. PR과 `-R`을 함께 생략하면 현재 브랜치의 PR을 본다. PR 본문 반응, 요약 코멘트, 리뷰 객체, 한도·오류 코멘트를 조합해 상태를 판정하고 다음 값을 함께 낸다. 필드명은 `--json` 출력 기준이다.

- `reviewed_commit`: 봇이 리뷰한 커밋. 짧은 SHA일 수 있다.
- `stale`: `reviewed_commit`과 현재 `head`가 다르다.
- `rereview_requests`: 재리뷰 요청 코멘트 수.
- `unhandled_threads`: 답글·반응·resolve 중 빠진 것이 있는 봇 스레드와 빠진 항목(`missing`). 이미 resolve된 스레드도 답글이나 반응이 빠졌으면 나온다. 반응에 쓸 REST id는 `comment_id`다.
- `settings_warning`: 봇이 리뷰했어야 할 PR에 흔적이 없을 때의 점검 안내.

트리거는 PR 생성, draft 해제, 재리뷰 요청 코멘트 중 가장 최근 것이다. 리뷰·👍·완료 표시·한도·오류 같은 결과 신호는 트리거 뒤의 것만 세고, 진행 중 표시(👀, Running)는 대기 한도까지 진행 중으로 본다.

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

- `pending`이면 `--wait 540`을 붙여 다시 조회한다. 540초는 `--help`에 나오는 `--wait` 상한이다. 그동안 반환하지 않을 수 있으므로 셸 명령 제한 시간을 600초로 늘리거나 백그라운드로 실행해 끝난 뒤 출력을 본다. 제한 시간에 걸려 중단됐다면 도구 실패가 아니므로 같은 명령을 다시 호출한다. 끝난 뒤에도 `pending`이면 다시 호출한다. 대기 한도가 지나면 도구가 `timeout`을 내므로 끝없이 기다리지 않는다.
- `settings_warning`이 있으면 그 문구를 사용자에게 그대로 보고한다.
- 명령이 실패하면(exit 1·2) 출력된 원인(인증, 네트워크, PR 지정)을 고쳐 다시 조회한다. 명령을 찾지 못하면 `nrs`가 아직 적용되지 않은 호스트다. nixos-config 작업 트리 안에서는 `python3 modules/shared/scripts/codex-review-status.py`로 같은 조회를 할 수 있다. 해결하지 못하면 finish-pr는 봇 상태를 모르는 채로 머지하지 않고 사용자에게 보고한다. review-pr-feedback은 봇 상태 없이 수집을 계속하고 그 사실을 보고한다.

## 지적 처리

- 봇의 지적은 인라인 리뷰 스레드로만 온다. 첫머리의 `P1`·`P2` 배지는 봇이 매긴 우선순위일 뿐이다. 둘 다 다른 리뷰어의 지적과 같은 기준으로 검증하고 반영 여부를 정한다.
- 봇이 작성한 일반 코멘트와 리뷰 객체 본문은 문구와 관계없이 피드백이 아니라 상태 신호다. actionable로 분류하지 않고 follow-up 코멘트도 남기지 않는다. 예:
  - 리뷰 객체 본문(`Codex Review` 제목과 리뷰 커밋 표시)
  - 요약 코멘트(`<!-- codex-pull-request-review-summary -->` 표식과 상태 표)
  - 재리뷰 요청에 답하는 지적 없음 코멘트(`Didn't find any major issues`)
  - 사용량 한도 안내, 계정 연결 안내, 오류 안내
- `unhandled_threads`의 스레드는 `isResolved`와 관계없이 처리 대상이다. 이미 resolve된 스레드는 `missing`에 남은 항목만 채운다. 반응만 빠졌으면 기존 답글의 판정으로 반응만 달고, 답글만 빠졌으면 답글만 단다. resolve를 풀지 않는다.
- 봇은 스레드 답글에 응답하지 않는다. 답글을 단 뒤 봇을 기다리지 않는다.

## 반응

봇의 인라인 지적에는 답글을 달기 전에 판정에 맞는 반응을 스레드 첫 코멘트에 단다. 반응은 Codex 리뷰 대시보드의 정확도 집계에 쓰인다. 반영하지 않은 지적은 [기각 분류](rejection-taxonomy.md) 하나를 정해 그 분류로 반응한다. 이미 내 👍나 👎가 있으면 새로 달거나 바꾸지 않는다 — `unhandled_threads[].missing`에 `reaction`이 있는 스레드만 대상이다.

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

PR·이슈 제목과 본문, 코멘트, 스레드 답글 어디에도 봇 멘션(`@codex`)을 쓰지 않는다. 백틱이나 인용 안에 있어도 봇이 작업 요청으로 읽어 클라우드 작업(새 PR 생성 등)을 시작한다. 봇 계정 이름(`@chatgpt-codex-connector`)으로도 멘션하지 않는다. 봇을 가리킬 때는 "Codex 봇"처럼 멘션 없이 쓰고, 봇 작성 코멘트에 연결할 때는 코멘트 URL을 쓴다. 예외는 아래 재리뷰 요청 한 가지다.

pinning-guard는 GitHub 게시 명령의 명령 문자열과, 경로가 그대로 적힌 본문 파일에서 봇 멘션을 막는다. 변수로 넘긴 본문 파일(`-F body=@"$BODY_FILE"`)과 stdin 본문은 읽지 못하므로, 그런 본문은 게시 전에 봇 멘션이 없는지 별도 명령으로 확인한다.

## 재리뷰 요청

`reviewed_commit` 뒤의 변경(`stale: true`)에 다음 중 하나가 있으면 재리뷰를 요청한다.

- 로직 변경
- 새 기능이나 새 파일
- 설계 변경

문서·주석·테스트만 바꾼 변경, 이름·오타 수정, 국소적인 P2 반영에는 요청하지 않는다. 요청은 PR당 한 번이다 — `rereview_requests`가 1 이상이면 다시 요청하지 않는다. 봇 리뷰 없이 끝난 상태(`limited`·`failed`·`timeout`·`absent`)에서는 요청하지 않고, 머지한 뒤의 사후 재리뷰도 요청하지 않는다.

```bash
gh pr comment <PR> -R OWNER/REPO --body '@codex review'
```

이 한 줄 그대로 보낸다. 문구를 덧붙이거나 본문 파일로 보내면 pinning-guard가 막는다. 요청 뒤에는 상태가 다시 `pending`이 된다. 기다림과 새 지적 처리는 finish-pr 게이트가 맡으므로, review-pr-feedback은 요청 뒤 기다리지 않고 남은 답글·반응·resolve를 이어서 마친다.
