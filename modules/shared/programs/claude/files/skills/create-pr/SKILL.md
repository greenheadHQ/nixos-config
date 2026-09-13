---
name: create-pr
argument-hint: "[update]"
description: |
  Create or update a pull request describing the final change and its validation.
  Use for PR creation or body updates; review comments use review-pr-feedback, and merging uses finish-pr.
---

# PR 작성

`update` 인자는 기존 PR 본문을 갱신한다. 그 외에는 새 PR을 생성한다. 대상 저장소의 PR 템플릿·언어·제목 관례가 우선한다.

## 본문 작성

- 문제와 변경 후 동작을 먼저 설명한다. 실제로 실행한 검증과 남은 제약을 적는다. 작은 변경은 이 내용만으로 충분하다.
- 중요한 선택은 CIR(변경 이유)·ADR(대안과 선택 근거)을 남긴다. 기존 동작이나 방어 로직을 제거·되돌린다면 도입 및 후속 결정의 근거를 확인하고 무엇을 왜 바꾸는지 설명한다.
- 필요한 항목만 작성한다. 빈 섹션, N/A 채우기, 파일 목록과 diff의 반복 설명은 만들지 않는다. [본문 예시](references/pr-template.md)는 선택 가능한 예시다.
- 최종 구현을 기준으로 제목과 본문을 갱신한다. 대화의 진행 순서, 검토 라운드·finding ID, 임시 절대경로와 squash 전 hash chain은 넣지 않는다. 관련 이슈·PR 번호나 머지된 SHA로 근거를 연결한다.
- 관련 노트와 대화는 근거로 활용하되, 작성 자료를 자동으로 삭제하거나 별도 원장·marker를 요구하지 않는다.

## 게시 절차

1. 대상 `OWNER/REPO`를 확정한다. 사용자 지정이 없으면 `gh repo view --json nameWithOwner -q .nameWithOwner`로 조회한다. 실패하거나 비어 있으면 게시하지 않는다. 이후 조회·생성·수정은 같은 `-R OWNER/REPO`를 사용한다.
2. 실제 base와 head, 커밋·diff, 기존 PR 유무를 확인한다. 미커밋 변경은 게시할 PR diff와 구분한다. 연관 이슈는 실제로 해결하는 경우에만 `Closes #N`으로 연결한다.
3. `update`이면 현재 제목·본문·첨부를 읽고 최종 변경을 반영한다. 유효한 근거와 기존 첨부 URL은 보존한다.
4. 본문은 private 임시 디렉터리(0700)의 일반 파일(0600)에 작성한다. [공개 정보 처리 기준](../write-handoff/references/sanitization-checklist.md)을 최종 본문에 적용한다. 제공된 이미지·영상은 [첨부 절차](../attaching-github-media/SKILL.md)에 따라 본문 참조와 `--attach` 인자를 준비한다.
5. 생성은 `gh pr create -R OWNER/REPO --title "<제목>" --body-file <파일>`, 갱신은 `gh pr edit <number> -R OWNER/REPO --body-file <파일>`을 사용한다. 첨부 인자는 같은 명령에 추가한다. 별도 관례가 없으면 제목은 70자 미만의 conventional commit 형식으로 쓴다.
6. 반환된 PR URL과 원격 본문을 확인한다. 실패·부분 성공이면 파일을 보존하고 원격 게시 여부부터 확인하여 중복 생성을 피한다. 첨부 복구는 [재시도 규칙](../attaching-github-media/SKILL.md#실패와-재시도)을 따른다. 성공을 확인한 뒤에만 이 작업이 만든 임시 본문을 정리한다.
