---
name: grill-me
description: |
  결정 트리의 모든 분기를 해소할 때까지 한 번에 하나씩 질문하며 인터뷰한다.
  최종 산출물 없음 — 공유된 이해 자체가 목적이다.
  Trigger: '그릴해줘', '심층 인터뷰', '결정 트리 검증', '분기 해소 인터뷰',
  '놓친 분기 인터뷰', '결정 트리 인터뷰'.
  NOT for 이슈 산출 (use create-issue). NOT for 코드/계획 DA 리뷰 (use run-da).
---

# grill-me

사용자의 계획·디자인을 받아, 결정 트리의 모든 분기가 해소될 때까지 한 번에 하나씩 질문한다.
원본은 [mattpocock/skills/grill-me](https://github.com/mattpocock/skills/tree/main/grill-me). 산출물은 공유된 이해 자체이며, 계획 파일·이슈·PR은 만들지 않는다.

- 미결정 분기를 질문 도구로 하나씩 묻는다 (요구사항·설계 결정·트레이드오프·사이드이펙트·XY problem 포함). Codex 세션에서는 `request_user_input`을 명시적으로 호출한다 (default mode는 자동 호출하지 않음). 각 질문에 본인의 추천 답변과 근거를 함께 낸다 — 떠넘기기 금지.
- 코드베이스·문서로 직접 확인 가능한 사실은 묻지 말고 grep/Read/git log로 자체 검증한다 (블랙박스 제로 원칙).
- 답변에서 새 분기가 파생되면 결정 트리에 추가하고 계속 묻는다.
- 모든 분기가 해소될 때까지 멈추지 않는다. 사용자가 "충분하다"고 명시하면 종료한다.
