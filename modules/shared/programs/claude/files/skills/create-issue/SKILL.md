---
name: create-issue
argument-hint: "[issue title or description (optional)] [--parent <NUM|URL>]"
description: |
  Create a GitHub issue grounded in the current task and repository conventions.
  Trigger: '이슈 등록', '이슈 만들어', 'todo 등록', '버그 등록', '이슈 추가'.
  NOT for PR 본문 (use create-pr).
---

# 이슈 등록

인자의 제목·설명을 사용하고, 비어 있으면 대화에서 작업 내용을 추출한다. 대상 저장소의 이슈 템플릿과 관례가 우선한다. 사용자 언어 지정이 없으면 한국어 대화의 본문은 한국어로 작성한다.

## 입력 분기

첫 standalone `--` 앞에 `--parent`, `--parent=...`, `—parent`, `—parent=...`가 있으면 [parent-linking.md](references/parent-linking.md)의 파싱·오타 거부·parent pre-check를 생성 전에 수행한다. `--` 뒤는 자유 텍스트로 보존한다. parent 미지정 경로에는 이 문서가 필요하지 않다.

## Step 1 — 근거 수집

대상 저장소와 관련 파일을 확인하고, 이슈·커밋에서 중복 작업과 유효한 제약을 찾는다. 현재 작업에서 이미 확인한 사실은 재사용한다. 조사 결과 중 문제나 선택을 설명하는 근거만 본문에 연결한다.

## Step 2 — 본문 작성

문제 또는 목표, 필요한 변경과 완료 판단에 필요한 정보를 작성한다. 버그라면 재현 조건·기대 동작·실제 동작을, 중요한 선택이라면 대안과 결정 근거를 포함한다. 미결정 구현은 확정한 설계처럼 쓰지 않는다.

[본문 예시](references/issue-template.md)를 참고하되 고정 섹션 수, TL;DR 중복, N/A 채우기를 요구하지 않는다. 이미지·영상이 제공되면 [첨부 절차](../attaching-github-media/SKILL.md)에 따라 본문 참조와 `--attach` 인자를 준비한다.

## Step 3 — 게시 전 확인

[근거 확인 기준](../write-handoff/references/llm-friendly-checklist.md)에 따라 확인된 사실과 추론·미확인을 구분한다. 출처 부재·충돌·상태 변경 가능성이 있는 주장만 추가 확인한다. [공개 정보 처리 기준](../write-handoff/references/sanitization-checklist.md)을 최종 본문에 적용하며, 재현에 필요한 repo-relative 경로·검증 명령·실패 증상은 보존한다.

## Step 4 — 제목과 라벨

저장소의 기존 라벨을 조회하고 [label-taxonomy.md](references/label-taxonomy.md)를 참고해 적합한 area·priority·유형을 선택한다. 없는 area를 자동 생성하지 않는다. 외부 저장소의 라벨 관례가 다르면 그 관례를 따른다. 별도 제목 관례가 없으면 `feat:`, `fix:`, `docs:` 등 변경 목적에 맞는 접두사를 사용한다.

## 게시와 후속 처리

게시 전에 [publishing.md](references/publishing.md)를 읽는다. 정확한 대상 지정, 최종 본문의 민감정보 검사, private 본문 파일과 `--body-file`, URL 검증 및 실패 시 보존 규칙을 적용한다. 이슈 생성이나 원격 URL 확인이 실패하면 parent 연결과 handoff를 진행하지 않는다.

`--parent` 경로는 게시 성공 후 [parent-linking.md](references/parent-linking.md)의 연결 절차를 수행하고 `SUBISSUE_STATUS`를 최종 응답에 포함한다. parent 미지정 시 이 토큰을 만들지 않는다. 이슈 URL과 첨부·연결의 실제 결과를 보고한다.

이 스킬은 단일 이슈 등록용이다. handoff 등 후속 게시가 기존 요청에 포함되어 있지 않으면 자동 실행하지 않는다. 필요한 질문은 현재 세션의 질문 도구로 한 번에 한 결정씩 묻는다.
