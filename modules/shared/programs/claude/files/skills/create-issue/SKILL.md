---
name: create-issue
argument-hint: "[issue title or description (optional)] [--parent <NUM|URL>]"
description: |
  Create a structured GitHub issue with auto-enriched labels.
  Trigger: '이슈 등록', '이슈 만들어', 'todo 등록', '버그 등록', '이슈 추가'.
  NOT for PR 본문 (use create-pr).
---

# 이슈 등록

스킬 호출 인자로 이슈 제목, 설명, 또는 작업 내용을 수신한다.
텍스트가 제공되면 이슈 제목/설명으로 사용하고,
비어있으면 대화 컨텍스트에서 이슈 내용을 추출한다.

## 필요한 문서 선택

| 항목 | 설명 |
|------|------|
| 입력 | 이슈 제목 또는 설명 (선택). 비어있으면 대화 컨텍스트에서 추출 |
| 출력 | 구조적 이슈 등록 + URL 반환 |
| 핵심 도구 | 코드베이스 검색, `gh` CLI |
| 범위 | 등록 전용. 조회/감사/라이프사이클은 `gh` CLI를 직접 사용 |

## 런타임 도구 매핑

이 스킬은 Claude Code 세션과 direct Codex 세션 모두에서 동작한다.
사용자에게 질문하는 행동은 런타임에 해당하는 도구로 수행한다.

| 행동 | Claude Code 세션 | Codex 세션 |
|------|------------------|------------|
| 사용자에게 질문 | `AskUserQuestion` 도구 | `request_user_input` |

본문에서 "질문 도구"는 위 표의 런타임별 실제 도구를 가리킨다.

## 입력 분기

첫 standalone `--` 앞에 `--parent`, `--parent=...`, `—parent`, `—parent=...` 형태가 있으면 [parent-linking.md](references/parent-linking.md)를 읽어 파싱·오타 거부·parent pre-check를 이슈 생성 전에 끝낸다. standalone `--` 뒤는 자유 텍스트로 보존한다. 단일 이슈 경로에서는 parent 문서를 로드할 필요가 없다.

### Step 1 — 코드베이스 탐색

이슈 내용을 기반으로 관련 컨텍스트를 수집한다 (TL;DR A1/Context A2 작성에 필요). LLM 친화성 체크리스트 A 섹션 참조 ([../write-handoff/references/llm-friendly-checklist.md](../write-handoff/references/llm-friendly-checklist.md)).

- (a) 관련 파일 탐색: 이슈에 언급된 경로는 파일 읽기 도구로, 모듈/키워드는 검색 도구로 탐색.
  예 (셸 명령): `rg -n "<키워드>" modules/`, `find . -name "*.nix" -path "*<모듈>*"`, 또는 그에 상당하는 도구.
- (b) 관련 이슈 검색: `gh issue list --search "<키워드>" --state all --limit 20`으로 중복/관련 이슈 확인. 검색 결과는 LLM의 중복 판단/라벨 결정 보조에 활용한다. 검색 결과의 이슈 번호를 새 이슈 본문 References 섹션에 자동 첨부하지 않는다 — 이슈 close/rename 시 stale 위험. 출처 입증에 불가결한 경우에만 명시 인용.
- (c) 관련 커밋 확인: `git log --oneline -20 -- <관련 경로>` 또는 `git log --grep="<키워드>"`.

### Step 2 — 템플릿 작성

[references/issue-template.md](references/issue-template.md)를 참조하여 이슈 본문을 작성한다.

필수 섹션 (항상 작성):
- TL;DR — 쉬운 말로: 본문 최상단에 평이한 말로 풀어쓴 핵심 요약 (recommended 4 sub-section: 문제/해결/결과물/검증 — 변형/추가/생략 자유, 체크리스트 A1). 자세한 가이드와 sub-section 변형 예시는 [references/issue-template.md](references/issue-template.md) `## 템플릿` 블록의 TL;DR section + `## 작성 예시` 참조.
- Context: 현 상태 → 문제점 → 필요성 순으로 서술 (체크리스트 A2)
- References: 비자명 주장의 출처 링크 최소 1개 이상 (체크리스트 B1/B4). 공식 docs URL, repo 내부 파일 경로(`path/to/file.nix:LINE`), 또는 머지된 commit SHA. 관련 이슈/PR 번호 인용은 출처 입증에 불가결한 경우에만 사용 (Step 1-b 검색 결과 자동 첨부 금지 — close/rename 시 stale). 근거 부재 시 `[UNVERIFIED]` 라벨로 대체.
- Proposed Changes: 체크박스(`- [ ]`) 형태의 구체적 변경 계획

선택 섹션 (판단 기준에 따라 포함):
- PoC / Reproduction: 재현이 중요한 주장(버그 리포트 등)에 6필드 포함 — `환경 / 입력 / 절차 / 기대 결과 / 실제 결과 / 성공 기준` (체크리스트 C1)
- Related Commits: 수신한 인자 또는 대화 컨텍스트에 커밋 해시가 언급되었거나, Step 1(c)에서 직접 관련 커밋을 발견한 경우
- Affected Files: 변경 대상 파일이 여러 개인 경우 (테이블 형식)
- Notes: 추가 참고사항(제약사항, 관련 이슈 번호, YAGNI 판단 근거 등)이 있는 경우

명시적 이미지·영상이 있으면 PoC 섹션 포함 여부와 무관하게 `시각적 실제 결과` 슬롯을 준비한다. [공식 첨부 절차](../attaching-github-media/SKILL.md)에 따라 로컬 파일 참조와 `--attach` 인자를 준비하고, Step 5-A의 게시 명령에 함께 전달한다.

작성 언어와 공개 안전성 (섹션 선택과 독립): 사용자가 본문 언어를 명시적으로 지정했으면 그 지정이 우선하고, 지정이 없으면 한국어로 요청했거나 대화가 한국어일 때 이슈 본문도 한국어로 유지한다 (sanitization checklist S4). 작성 중에도 [공개용 sanitization checklist](../write-handoff/references/sanitization-checklist.md)의 금지 항목(S1)을 넣지 않고 보존 항목(S2)을 지우지 않는다 — 최종 강제는 Step 3에서 수행.

### Step 3 — 게시 전 자체 검증 (anti-hallucination + sanitization)

작성된 이슈 본문에 체크리스트 E1/E2와 공개 sanitization scan을 적용한다 (E1/E2 규칙 상세 정의와 출처는 [`../write-handoff/references/llm-friendly-checklist.md`](../write-handoff/references/llm-friendly-checklist.md) Normative E1/E2 참조).

- E1: 근거 없거나 확신 낮은 주장은 `[UNVERIFIED]` 라벨 또는 삭제 (라벨 체계 상세는 [체크리스트 라벨 체계](../write-handoff/references/llm-friendly-checklist.md#라벨-체계-anti-hallucination) 참조).
- E2: 이번 작업의 직접 근거를 재사용한다. 출처 부재·충돌·상태 변경 가능성이 있는 주장만 추가 확인하고, 확인 불가 시 라벨 또는 삭제한다.
- S1-S3: 공개 sanitization post-render scan — [공개용 sanitization checklist](../write-handoff/references/sanitization-checklist.md)의 금지(S1)/보존(S2) 기준과 S3 scan 절차를 초안에 적용한다. blanket redaction 금지 — S2 항목(repo-relative path, 검증 명령/결과, 실패 증상)은 지우지 않는다.

### Step 4 — 라벨 자동 결정

[references/label-taxonomy.md](references/label-taxonomy.md)를 참조하여 라벨을 결정한다.

1. `gh label list`로 기존 area 라벨 목록을 조회한다.
2. 이슈 내용에서 적합한 area를 자동 매칭한다 (기존 area에서만 선택).
3. 매칭되는 area가 없으면 area 없이 등록하고 사용자에게 알린다 (자동 생성 금지).
4. priority는 이슈 내용의 긴급도/영향도를 기반으로 자동 판단한다 (high/medium/low).
5. GitHub 기본 라벨(enhancement/bug/documentation 등)을 이슈 유형에 맞게 선택한다.

### 게시와 후속 처리

게시 전에 [publishing.md](references/publishing.md)를 읽는다. 제목·라벨 확인, 첨부 처리 후 최종 본문 sanitization, private 본문 파일 수명주기, URL 검증과 후속 handoff 동의 경계를 적용한다. 이슈 생성 또는 URL 검증 실패 시 parent 연결과 handoff를 진행하지 않는다.

`--parent` 경로는 게시 성공 후 [parent-linking.md](references/parent-linking.md)의 연결 절차를 수행하고 `SUBISSUE_STATUS`를 최종 응답에 포함한다. parent 미지정 시 이 토큰을 만들지 않는다. 첨부 결과는 자연어로 짧게 보고한다.

## Title Conventions

| Prefix | Use |
|--------|-----|
| `feat:` | 새 기능, 개선 |
| `fix:` | 버그 수정 |
| `refactor:` | 구조 변경 (동작 불변) |
| `test:` | 테스트 추가/수정 |
| `docs:` | 문서 |
| `chore:` | 기타 유지보수 |

Epic/umbrella 관계가 필요하면 [parent-linking.md](references/parent-linking.md)를 참조한다. 이 스킬은 단일 이슈만 등록한다.

## 주의사항

- 이슈 본문에 시크릿/credential/API 키를 포함하지 않는다. `.age` 복호화 값, `.env` 내용은 파일 경로만 참조한다. 개인/회사 식별자, 절대 로컬 경로 등 나머지 금지/보존 기준은 [공개용 sanitization checklist](../write-handoff/references/sanitization-checklist.md)가 단일 진실 원천이다 (Step 3에서 강제).
- 조회(`gh issue list`), 감사(audit), 라이프사이클(close/reopen/edit), 라벨 관리(CRUD)는 이 스킬의 범위 밖이다. `gh` CLI를 직접 사용한다.
- `gh issue create` 실행 시 본문은 `--body-file`로 전달한다. HEREDOC(`$(cat <<'EOF' ... EOF)`) 방식은 본문 내부에 PoC/Reproduction 섹션의 nested `cat <<'EOF'` 예시나 독립 `EOF` 라인이 포함될 때 outer heredoc가 조기 종료되어 등록이 실패하거나 본문이 잘린다. `PoC / Reproduction` 섹션(issue-template)의 shell 재현 스니펫이 기본 기능이므로 HEREDOC 전달은 금지.
## 참조 자료

- [references/issue-template.md](references/issue-template.md) -- 이슈 템플릿 (필수 섹션: TL;DR/Context/References/Proposed Changes + 선택 섹션: PoC/Related Commits/Affected Files/Notes) + 섹션별 작성 가이드 + 작성 예시
- [references/label-taxonomy.md](references/label-taxonomy.md) -- 라벨 체계 상세 (색상 코드, 판단 기준, 설계 근거)
- [LLM 친화성 체크리스트](../write-handoff/references/llm-friendly-checklist.md) -- `create-issue`/`write-handoff` 공유. Normative(스킬 강제) + Informational(권장) 분리. 라벨 체계(`[UNVERIFIED]`/`[INFERRED]`/`[CONFLICTING]`). 공식 docs/학술 출처 링크 포함
- [공개용 sanitization checklist](../write-handoff/references/sanitization-checklist.md) -- `create-issue`/`write-handoff` 공유 단일 진실 원천. 공개 게시물 금지/보존 항목(S1/S2), post-render scan 절차(S3), 언어 유지 규칙(S4)
