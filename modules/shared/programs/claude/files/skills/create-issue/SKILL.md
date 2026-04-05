---
name: create-issue
argument-hint: "[issue title or description (optional)]"
description: |
  Create a structured GitHub issue with auto-enriched labels.
  Trigger: '이슈 등록', '이슈 만들어', 'todo 등록', '버그 등록', '이슈 추가'.
  NOT for CIR/ADR (use documenting-intent). NOT for PR 본문 (use create-pr).
---

# 이슈 등록

`$ARGUMENTS`를 이슈 제목, 설명, 또는 작업 내용으로 수신한다.
텍스트가 제공되면 이슈 제목/설명으로 사용하고,
비어있으면 대화 컨텍스트에서 이슈 내용을 추출한다.

## 빠른 참조

| 항목 | 설명 |
|------|------|
| 입력 | 이슈 제목 또는 설명 (선택). 비어있으면 대화 컨텍스트에서 추출 |
| 출력 | 구조적 이슈 등록 + URL 반환 |
| 핵심 도구 | 코드베이스 검색, `gh` CLI |
| 범위 | 등록 전용. 조회/감사/라이프사이클은 `gh` CLI를 직접 사용 |

## 절차

### Step 1 — 코드베이스 탐색

이슈 내용을 기반으로 관련 컨텍스트를 수집한다.

- (a) 이슈 내용에서 언급된 파일 경로/모듈명을 기준으로 관련 파일 내용 읽기
- (b) `gh issue list --search`로 중복/관련 이슈 검색
- (c) 최근 관련 커밋 확인

### Step 2 — 템플릿 작성

`references/issue-template.md`를 참조하여 이슈 본문을 작성한다.

**필수 3섹션** (항상 작성):
- **Summary**: 1-2 문장으로 what + why 요약
- **Context**: 현 상태 → 문제점 → 필요성 순으로 서술
- **Proposed Changes**: 체크박스(`- [ ]`) 형태의 구체적 변경 계획

**선택 3섹션** (판단 기준에 따라 포함):
- **Related Commits**: `$ARGUMENTS` 또는 대화 컨텍스트에 커밋 해시가 언급되었거나, Step 1(c)에서 직접 관련 커밋을 발견한 경우
- **Affected Files**: 변경 대상 파일이 3개 이상인 경우
- **Notes**: 추가 참고사항(제약사항, 관련 이슈 번호, YAGNI 판단 근거 등)이 있는 경우

### Step 3 — 라벨 자동 결정

`references/label-taxonomy.md`를 참조하여 라벨을 결정한다.

1. `gh label list`로 기존 area 라벨 목록을 조회한다.
2. 이슈 내용에서 적합한 area를 자동 매칭한다 (기존 area에서만 선택).
3. 매칭되는 area가 없으면 **area 없이 등록하고 사용자에게 알린다** (자동 생성 금지).
4. priority는 이슈 내용의 긴급도/영향도를 기반으로 자동 판단한다 (high/medium/low).
5. GitHub 기본 라벨(enhancement/bug/documentation 등)을 이슈 유형에 맞게 선택한다.

### Step 4 — 등록 및 확인

1. 등록 전 **제목, 라벨 조합을 사용자에게 보여주고 확인**을 받는다.
2. 확인 후 `gh issue create`를 실행한다.
3. 생성된 이슈 URL을 반환한다.

### Step 5 — LLM 이행 가이드 연계

**호출 맥락 확인**: plan-with-questions에서 호출된 경우(Step I-5), 이 단계를 건너뛴다.
(plan-with-questions Step I-6에서 통합 선택지로 제안하므로 중복 방지.)

이슈 생성이 완료되면, AskUserQuestion으로 사용자에게 묻는다:

"LLM 이행 가이드를 작성할까요?"

- 사용자가 승인 → `/write-handoff <생성된 이슈 번호>` 스킬을 실행한다.
- 사용자가 거부 → 이슈 URL 반환 후 종료한다.

## Title Conventions

| Prefix | Use |
|--------|-----|
| `feat:` | 새 기능, 개선 |
| `fix:` | 버그 수정 |
| `refactor:` | 구조 변경 (동작 불변) |
| `test:` | 테스트 추가/수정 |
| `docs:` | 문서 |
| `chore:` | 기타 유지보수 |

## 주의사항

- 이슈 본문에 시크릿/credential/API 키를 포함하지 않는다. `.age` 복호화 값, `.env` 내용은 파일 경로만 참조한다.
- 조회(`gh issue list`), 감사(audit), 라이프사이클(close/reopen/edit), 라벨 관리(CRUD)는 이 스킬의 범위 밖이다. `gh` CLI를 직접 사용한다.
- `gh issue create` 실행 시 본문은 HEREDOC(`<<'EOF'`)으로 전달하여 셸 해석을 방지한다.

## 참조 자료

- **[references/issue-template.md](references/issue-template.md)** -- 이슈 템플릿 (필수3+선택3 섹션) + 섹션별 작성 가이드 + 작성 예시
- **[references/label-taxonomy.md](references/label-taxonomy.md)** -- 라벨 체계 상세 (색상 코드, 판단 기준, 설계 근거)
