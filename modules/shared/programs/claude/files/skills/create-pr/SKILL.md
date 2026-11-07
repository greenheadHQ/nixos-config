---
name: create-pr
argument-hint: "[update] [no-wait]"
description: |
  Create or update a pull request describing the final change and its validation. After creating a new PR, wait for the Codex bot review and handle bot feedback until the review settles.
  Use for PR creation or body updates; review comments on an existing PR use review-pr-feedback, and merging uses finish-pr.
---

# PR 작성

`update` 인자는 기존 PR 본문을 갱신한다. 그 외에는 새 PR을 생성한다. `no-wait` 인자는 새 PR을 만든 뒤 리뷰를 기다리지 않는다. 대상 저장소의 PR 템플릿·언어·제목 관례가 우선한다.

## 본문 작성

- 문제와 변경 후 동작을 먼저 설명한다. 실제로 실행한 검증과 남은 제약을 적는다. 작은 변경은 이 내용만으로 충분하다.
- 중요한 선택은 CIR(변경 이유)·ADR(대안과 선택 근거)을 남긴다. 기존 동작이나 방어 로직을 제거·되돌린다면 도입 및 후속 결정의 근거를 확인하고 무엇을 왜 바꾸는지 설명한다.
- 필요한 항목만 작성한다. 빈 섹션, N/A 채우기, 파일 목록과 diff의 반복 설명은 만들지 않는다. [본문 예시](references/pr-template.md)는 선택 가능한 예시다.
- 최종 구현을 기준으로 제목과 본문을 갱신한다. 대화의 진행 순서, 검토 라운드·finding ID, Claude 세션 URL, 임시 절대경로와 squash 전 hash chain은 넣지 않는다. 관련 이슈·PR 번호나 머지된 SHA로 근거를 연결한다.
- 제목과 본문에 Codex 봇 멘션(`@codex`)을 쓰지 않는다. 백틱 안이어도 봇이 작업 요청으로 읽어 클라우드 작업을 시작한다. 봇은 "Codex 봇"처럼 멘션 없이 부른다.
- 관련 노트와 대화는 근거로 활용하되, 작성 자료를 자동으로 삭제하거나 별도 원장·marker를 요구하지 않는다.

## 게시 절차

1. 대상 `OWNER/REPO`를 확정한다. 사용자 지정이 없으면 `gh repo view --json nameWithOwner -q .nameWithOwner`로 조회한다. 실패하거나 비어 있으면 게시하지 않는다. 이후 조회·생성·수정은 같은 `-R OWNER/REPO`를 사용한다.
2. 실제 base와 head, 커밋·diff, 기존 PR 유무를 확인한다. 미커밋 변경은 게시할 PR diff와 구분한다. 연관 이슈는 실제로 해결하는 경우에만 `Closes #N`으로 연결한다.
3. `update`이면 현재 제목·본문·첨부를 읽고 최종 변경을 반영한다. 유효한 근거와 기존 첨부 URL은 보존한다.
4. 본문은 private 임시 디렉터리(0700)의 일반 파일(0600)에 작성한다. [공개 정보 처리 기준](../write-handoff/references/sanitization-checklist.md)을 최종 본문에 적용한다. 제공된 이미지·영상은 [첨부 절차](../attaching-github-media/SKILL.md)에 따라 본문 참조와 `--attach` 인자를 준비한다.
5. 생성은 `gh pr create -R OWNER/REPO --title "<제목>" --body-file <파일>`, 갱신은 `gh pr edit <number> -R OWNER/REPO --body-file <파일>`을 사용한다. 첨부 인자는 같은 명령에 추가한다. 별도 관례가 없으면 제목은 70자 미만의 conventional commit 형식으로 쓴다.
6. 반환된 PR URL과 원격 본문을 확인한다. 실패·부분 성공이면 파일을 보존하고 원격 게시 여부부터 확인하여 중복 생성을 피한다. 첨부 복구는 [재시도 규칙](../attaching-github-media/SKILL.md#실패와-재시도)을 따른다. 성공을 확인한 뒤에만 이 작업이 만든 임시 본문을 정리한다.
7. 새 PR을 만들었으면 [리뷰 대기와 자동 처리](#리뷰-대기와-자동-처리)로 이어 간다. `update` 모드, draft PR, `no-wait` 인자나 기다리지 말라는 요청이면 기다리지 않는다. 이때는 사용자 보고에 PR URL과 함께, Codex 리뷰 봇이 PR을 열거나 draft를 ready로 바꾸거나 push한 뒤 보통 3~8분 안에 리뷰를 남기고 머지 전 확인은 finish-pr가 한다고 적는다.

## 리뷰 대기와 자동 처리

새 PR의 Codex 봇 리뷰를 기다려 봇 지적을 처리하고, 반영 push로 생긴 새 리뷰도 같은 방식으로 이어 간다. 바퀴 수에 상한은 없다. 코드 push가 없는 바퀴에서는 새 리뷰가 생기지 않아 멈추기 때문이다. 사용자가 중단하면 실행 중인 대기 명령도 끝내고 [마지막 보고](#마지막-보고)로 넘어간다.

1. 기다린다. PR URL을 사용자에게 알리고, `codex-review-status <PR> -R OWNER/REPO --json --wait 540`을 [상태 조회](../review-pr-feedback/references/codex-review.md#상태-조회)의 런타임별 방식으로 실행한다. 조회 실패를 해결하지 못하면 멈춘다.
2. 결과를 본다. 이 결과가 이번 바퀴의 상태다. 뒤의 처리에서 다시 조회한 값으로 바꾸지 않는다. 아래를 순서대로 확인한다.
   - `pr_state`가 `OPEN`이 아니거나 상태가 `draft`면 멈춘다.
   - 상태가 `pending`이면 1로 돌아간다.
   - `rereview_suggested`가 `true`면 [재리뷰 요청](../review-pr-feedback/references/codex-review.md#재리뷰-요청)대로 그 head에 한 번 요청하고 1로 돌아간다. 요청을 게시하지 못하면 멈춘다.
3. 처리한다. 상태와 관계없이 [review-pr-feedback](../review-pr-feedback/SKILL.md) 절차를 [봇 전용 범위](../review-pr-feedback/SKILL.md#처리-범위)로 실행한다. Codex 봇뿐 아니라 그 시점에 달린 CodeRabbit 같은 다른 봇의 지적도 함께 처리한다. 처리할 것이 없으면 그 절차의 no-op 규칙대로 끝난다. 처리 중 `update`로 본문을 갱신해도 따로 보고하지 않고 이 바퀴를 이어 간다.
4. 이어 갈지 정한다. `gh pr view <PR> -R OWNER/REPO --json headRefOid`로 현재 head를 본다. 이번 바퀴의 상태가 `reviewed`나 `lgtm`이고 현재 head가 대기 결과의 `head`와 다르면 새 head의 리뷰를 기다리러 1로 돌아간다. 이번 바퀴의 반영 push뿐 아니라 다른 사람의 push도 여기에 든다. 그 밖에는 멈춘다.
   - head가 그대로다. head 리뷰가 지적 없음으로 끝났거나 지적을 모두 기각해 코드 push가 없는 경우다.
   - 상태가 `limited`·`failed`·`timeout`·`absent`다. head가 바뀌었어도 멈춘다.

### 마지막 보고

멈추면 PR URL과 함께 다음을 보고하고, 머지 전 확인은 finish-pr가 한다고 적는다.

- 멈춘 이유와 마지막 바퀴의 Codex 봇 상태. `limited`·`failed`·`timeout`·`absent`이면 그 결과의 `reason`도 적고, 그 뒤에 push한 head는 봇 리뷰를 기다리지 않았다고 밝힌다.
- `settings_warning`이 있으면 그 원문.
- 봇별 상태와 지적 수·링크. 다른 봇의 상태는 현재 head의 commit status(`gh api repos/OWNER/REPO/commits/<head>/status`)에 `description`이 있으면 판정 없이 그대로 옮긴다. 지적마다 한 줄로 요약하되, 봇이 말한 내용은 "봇 주장"으로 표시해 검증한 판정(반영한 커밋이나 기각 사유)과 구분한다.
- 자동 처리하지 않은 사람 코멘트의 목록과 링크.
- Codex 봇만 기다렸다는 점. 대기가 끝난 뒤 도착한 CodeRabbit 같은 다른 봇의 리뷰와, 한도에 걸려 리뷰되지 않은 커밋은 처리되지 않았을 수 있다.
