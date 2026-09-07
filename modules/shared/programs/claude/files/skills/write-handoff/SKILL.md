---
name: write-handoff
argument-hint: "[local] [issue-number or URL] [topic/context]"
description: |
  Write a handoff for the next work session as a GitHub issue comment, or a cwd kickoff file with `local`.
  Use for work-session handoffs and continuation prompts; excludes generic prompt writing, issue creation, and PR bodies.
---

# LLM 이행 가이드 작성

스킬 호출 인자로 이슈 번호/URL 또는 주제·맥락을 수신한다. standalone `local` 토큰이 있으면 cwd 파일을 작성하고, 없으면 지정 이슈의 코멘트로 게시한다.

## 런타임 도구 매핑

이 스킬은 Claude Code 세션과 direct Codex 세션 모두에서 동작한다.
아래 행동은 런타임에 해당하는 도구로 수행한다.

| 행동 | Claude Code 세션 | Codex 세션 |
|------|------------------|------------|
| 사용자에게 질문 | `AskUserQuestion` 도구 | `request_user_input` |

본문의 "질문 도구"는 위 표의 런타임별 질문 도구를 가리킨다.

## 모드와 인자 해석

- 기본 모드: `local` 토큰이 없으면 기존 동작을 유지한다. 이슈 번호/URL을 읽고 이슈 코멘트로 게시한다.
- 로컬 모드: 공백/문장부호 경계의 standalone `local` 토큰이 있으면 활성화한다. `local` 토큰 자체는 주제/맥락 힌트에서 제거하고, 남은 인자는 이슈 번호/URL과 자유 텍스트로 해석한다.
- `local`과 이슈 번호/URL이 함께 오면 그 이슈를 읽어서 이행 가이드를 작성하되, 게시하지 않고 로컬 파일로만 저장한다.
- `local`만 오거나 이슈가 없으면 이슈 읽기 단계를 건너뛰고 대화 컨텍스트에서 목표/현재 상태/제약을 수집한다. 새 이슈 생성을 요구하지 않는다. 필수 맥락이 부족할 때만 질문 도구로 1-3개를 묻는다.
- 로컬 산출물은 항상 현재 작업 디렉토리(cwd)에 `HANDOFF-<주제-슬러그>.local.md`로 만든다. `<주제-슬러그>`는 이슈 제목, 자유 텍스트 힌트, 대화에서 확인한 목표 순으로 고르고 파일명 안전한 kebab-case로 정규화한다. `*.local.md`는 루트 `.gitignore`의 규칙으로 무시되므로 repo 추적 오염을 만들지 않는다.

기본 모드에 이슈 참조가 없을 때만 이슈 번호/URL을 요청한다. bare 번호의 대상 repo가 모호하면 URL을 확인한다. 이슈 참조가 있는 로컬 모드에서도 조회한 대상을 명확히 유지한다.

## 필요한 문서 선택

| 작업 | 읽을 문서 |
|------|-----------|
| 로컬 킥오프 파일 작성 | [local-workflow.md](references/local-workflow.md) |
| 이슈 조회와 코멘트 게시 | [issue-workflow.md](references/issue-workflow.md) |
| 산출물 구조 선택·작성 예시 | [guide-template.md](references/guide-template.md) |
| 두 모드 공통 근거·작성 품질 | [llm-friendly-checklist.md](references/llm-friendly-checklist.md) |
| 저장·게시 전 민감정보 검사 | [sanitization-checklist.md](references/sanitization-checklist.md) — 공개 모드 전체, 로컬 모드는 시크릿 금지 범위 |

## 작성 기준

- 상단에 목표·현재 상태·다음 행동·blocker를 요약한다. 완료한 일, 남은 일, 실행 제약과 이미 결정한 설계·대안의 근거를 이어서 적는다.
- 관련 파일과 참조를 탐색해 변경 대상·의존 관계·검증 기준을 제시한다. 파일 수로 단계 수나 세션 시간·수를 고정하지 않는다. 분할이 필요하면 선후 관계와 독립적으로 이어갈 수 있는 경계를 기준으로 한다.
- 실행 시점에 달라질 수 있는 값은 CLI·파일시스템에서 확인하도록 안내한다. 이슈·대화의 과거 값보다 실행 시점의 직접 근거를 우선한다.
- BEFORE/AFTER는 구체적인 치환이 확정되었을 때 사용한다. 미결정 구현은 목표·제약·수용 기준으로 기술하고, 선택한 대안과 그 이유를 보존한다.
- 비자명 주장에는 출처를 붙인다. 이번 작업에서 확보한 직접 근거를 재사용하고, 출처 부재·충돌·상태 변경 가능성이 있는 주장만 추가 확인한다. 확인 불가 시 `[UNVERIFIED]` 또는 해당 라벨을 적용하거나 삭제한다 (공통 체크리스트 E1/E2).
- 공개 모드는 최종 본문에 S1-S4 sanitization을 적용하되 repo-relative 경로·검증 결과·실패 증상을 일괄 삭제하지 않는다. 로컬에는 필요한 절대경로·dirty-state를 적을 수 있지만 시크릿·토큰·키·복호화 값은 금지한다.
- 커밋·push·PR·후속 게시가 승인된 범위일 때만 후속 행동으로 넣는다. 커밋 메시지는 최종 diff에 맞춰 conventional commit 규칙으로 작성하며, 실제로 해결하는 명시적 이슈에만 `Closes #N`을 쓴다. 완성 메시지를 미리 고정하지 않는다.
- 구현 후 리뷰·PR이 작업 범위이면 확립된 DA/리뷰 스킬 체인을 보존한다. handoff 작성만으로 후속 실행이나 외부 게시가 승인된 것으로 만들지 않는다.
- 환경별 분기와 독립 작업의 병렬 가능 여부는 실제로 다음 실행에 필요할 때 설명한다.
