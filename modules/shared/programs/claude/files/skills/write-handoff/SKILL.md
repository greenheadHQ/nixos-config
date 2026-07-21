---
name: write-handoff
argument-hint: "[local] [issue-number or URL] [topic/context]"
description: |
  Write LLM migration guide comment on GitHub issue; with `local`, write a cwd kickoff prompt file instead.
  Trigger: 'LLM 이행', '이행 가이드', '인수인계', '세션 인수인계', '킥오프 프롬프트', '복붙용 프롬프트', '로컬 인수인계', 'write-handoff', 'handoff'.
  NOT for PR 본문 (use create-pr). NOT for 이슈 생성 (use create-issue).
---

# LLM 이행 가이드 작성

스킬 호출 인자로 이슈 번호(예: `#123`, `123`) 또는 이슈 URL을 수신한다.
`local` 토큰이 있으면 로컬 모드로 전환하고, 나머지 인자는 주제/맥락 힌트로 사용한다.
기본 모드는 해당 이슈를 분석하여 LLM이 자율적으로 처음부터 끝까지 작업을 수행할 수 있는
Phase 기반 이행 가이드를 작성하고, 이슈 코멘트로 게시한다.
로컬 모드는 이슈 코멘트 게시 대신 cwd에 `HANDOFF-<주제-슬러그>.local.md`를 작성한다.

## 빠른 참조

| 항목 | 위치 |
|------|------|
| 이행 가이드 마크다운 템플릿 | [references/guide-template.md](references/guide-template.md) |
| 로컬 산출 파일 | cwd의 `HANDOFF-<주제-슬러그>.local.md` (루트 `.gitignore`의 `*.local.md` 규칙으로 repo 추적 제외) |

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

## 이슈 이행 가이드 구조

이행 가이드는 다음 섹션으로 구성한다.

| # | 섹션 | 역할 |
|---|------|------|
| 0 | TL;DR 블록 | 상황/현재 상태/다음 액션/Blockers — 새 세션 LLM이 가이드 상단에서 전체 맥락 파악 (primacy bias) |
| 1 | 헤더 블록 | 대상/목표/예상소요/난이도 — 한눈에 파악 가능한 메타 정보 |
| 2 | 핵심 원칙 | 행동 제약 1-3개 — 작업 전체에 적용되는 불변 규칙 |
| 3 | Phase 1: 사전 확인 | CLI/파일시스템에서 현재 값 확인 (병렬 가능 힌트 포함) |
| 4 | Phase 2: 실행 | BEFORE/AFTER 치환 또는 상세 변경 지시 |
| 5 | Phase 3: 검증 + 커밋 | 빌드 확인 + git add/commit 템플릿 |
| 6 | 주의사항 | 환경 분기, 대체 행동, 예외 처리 |

복잡도에 따라 Phase 수가 3-6개로 조정된다. 상세 템플릿은 [references/guide-template.md](references/guide-template.md) 참조.

템플릿 상단의 TL;DR 블록 (상황/현재 상태/다음 액션/Blockers)은 `references/guide-template.md`에서 정의한다. primacy bias를 활용하여 새 세션 LLM의 맥락 파악 속도를 높인다 (출처: [Lost in the Middle (TACL 2024)](https://direct.mit.edu/tacl/article/doi/10.1162/tacl_a_00638/119630/Lost-in-the-Middle-How-Language-Models-Use-Long)).

## 로컬 킥오프 프롬프트 구조

로컬 모드의 산출물은 새 세션의 첫 프롬프트로 즉시 붙여넣어 사용할 수 있는 단일 문서여야 한다.
이슈 기반 로컬 모드에서는 위 Phase 구조를 포함할 수 있지만, 첫 화면에서 실행 맥락이 잡히도록 아래 요소를 반드시 포함한다.

- 목표/맥락 요약: 무엇을 이어서 해야 하는지, 왜 필요한지.
- 현재 상황: 완료된 일, 미완료 항목, 알려진 블로커.
- 환경 주의사항: repo, 머신, cwd, 도구, 권한, 금지 명령 같은 실행 제약.
- 작업 방식 지시: 대화에서 확립된 워크플로, 스킬 체인, 모델/에이전트 지정이 있으면 그대로 명시.
- 첫 행동 지시: 새 세션이 바로 실행할 첫 검색/파일 읽기/검증 명령 또는 확인 단계.

대화에서 확립되지 않은 후속 연계나 외부 게시 절차는 새로 만들지 않는다.
로컬 파일은 공개 게시물이 아니므로 필요한 로컬 작업 경로와 dirty-state 맥락을 적을 수 있다. 그래도 시크릿, 토큰, 복호화 값은 쓰지 않는다 ([references/sanitization-checklist.md](references/sanitization-checklist.md) 적용 범위 참조).

## 절차

### Step 0: 인자 해석 + 모드 결정

수신한 인자에서 standalone `local` 토큰을 먼저 찾는다. 있으면 `LOCAL_MODE=true`로 설정하고 해당 토큰을 제거한다.
남은 텍스트에서 이슈 번호 또는 URL을 파싱하고, 이슈 참조로 해석되지 않은 나머지는 자유 주제/맥락 힌트로 보존한다.

파싱 결과:

- `LOCAL_MODE=false` + 이슈 번호/URL 있음: 기존 이슈 코멘트 모드.
- `LOCAL_MODE=false` + 이슈 번호/URL 없음: 질문 도구로 이슈 번호 또는 URL을 요청한다.
- `LOCAL_MODE=true` + 이슈 번호/URL 있음: 이슈를 읽되 Step 9에서 로컬 파일만 작성한다.
- `LOCAL_MODE=true` + 이슈 번호/URL 없음: 이슈 읽기를 건너뛰고 대화 컨텍스트와 자유 텍스트 힌트에서 로컬 킥오프 프롬프트를 작성한다.

### Step 1: 이슈 내용 읽기 + 컨텍스트 확보

`LOCAL_MODE=true`이고 이슈 번호/URL이 없으면 이 단계를 건너뛴다. 대화 컨텍스트, 자유 텍스트 힌트, cwd의 파일 상태에서 목표/현재 상황/제약을 수집한다. 새 이슈 생성을 요구하지 않는다.

그 외의 경우 이슈 번호 또는 URL을 파싱한다. 기본 모드에서 수신한 인자가 비어있으면 런타임 도구 매핑 표의 질문 도구로 이슈 번호 또는 URL을 요청한다.

```bash
# 이슈 번호인 경우
gh issue view <number> --json title,body,labels,assignees,comments

# URL인 경우
gh issue view <url> --json title,body,labels,assignees,comments
```

bare 번호 입력 시 cwd 확인 필수: 전달된 값이 `123`, `#123` 같은 bare 번호이고 `gh repo view --json nameWithOwner -q .nameWithOwner`로 확인한 cwd repo가 handoff 대상 repo와 다를 가능성이 있으면, 질문 도구로 사용자에게 이슈 URL(`https://github.com/owner/repo/issues/N` 형태)을 재확인받은 뒤 그 URL로 `gh issue view`를 재실행한다. 확인 없이 진행하면 cwd repo의 동일 번호 이슈에 잘못 코멘트가 게시될 수 있다.

이슈 본문, 라벨, 기존 코멘트를 분석하여 작업 범위를 파악한다.

### Step 2: 복잡도 판단

이슈의 변경 규모와 범위를 판단하여 Phase 깊이를 결정한다.
이슈가 없는 로컬 모드에서는 대화 컨텍스트, 자유 텍스트 힌트, cwd에서 관측한 변경 규모와 불확실성을 기준으로 판단한다.

| 복잡도 | Phase 수 | 세션 전략 | 판단 기준 | 예시 |
|--------|---------|----------|----------|------|
| 단순 | 3 | 단일 세션 ~10분 | 파일 1-2개, 값 치환 수준 | 버전 업데이트, 경로 변경, 상수 교체 |
| 중간 | 4 | 단일 세션 ~15분 | 파일 3-5개, 로직 수정 포함 | 옵션 추가, 조건분기 변경, 설정 구조 변경 |
| 복잡 | 6 | 다중 세션, Phase별 독립 프롬프트 | 파일 6개 이상, 아키텍처 수준 변경 | 대규모 리팩토링, 새 모듈 도입, 서비스 마이그레이션 |

복잡도 판단이 애매하면 한 단계 높게 잡는다 (과소 추정보다 과대 추정이 안전).

### Step 3: 변경 대상 추출

이슈 또는 대화 컨텍스트에서 다음 정보를 추출한다:

- 변경 대상 파일: 이슈/대화에 명시된 파일 경로 + 코드베이스 탐색으로 발견한 관련 파일
- 변경 내용: 각 파일에서 무엇을 어떻게 바꾸는지
- 검증 기준: 변경이 올바르게 적용되었는지 확인하는 방법

코드베이스를 직접 탐색하여 이슈/대화에 명시되지 않은 관련 파일(예: 상수 참조, 테스트, 설정)도 식별한다.

탐색 도구 예시 (관련 파일/경로를 찾아 Phase 작성 시 B4 `path:LINE` citation에 활용):
- 셸 `find . -name "*.nix" -path "*<키워드>*"` 또는 그에 상당하는 검색 도구 — 파일 경로 검색
- 셸 `rg -n "<심볼>" <경로>` 또는 그에 상당하는 검색 도구 — import/상수/테스트 참조 발견
- `git log --oneline -20 -- <경로>` — 최근 변경 이력
- `git blame <파일>` — 라인별 맥락

관련 파일 누락 방지: `rg "<심볼>" modules/ libraries/ tests/` 또는 그에 상당하는 검색 도구로 repo 전체 재검색.

### Step 4: Phase별 가이드 작성

기본 이슈 코멘트 모드와 이슈 번호/URL이 있는 로컬 모드는 [references/guide-template.md](references/guide-template.md)의 템플릿에 따라 각 Phase를 작성한다.
이슈가 없는 로컬 모드는 [로컬 킥오프 프롬프트 구조](#로컬-킥오프-프롬프트-구조)를 우선하고, 필요한 경우 Phase 형식을 부분적으로 사용한다.

Phase 작성 원칙:
- 각 Phase는 독립 실행 가능해야 한다 (이전 Phase의 출력에 의존하되, 맥락 공유 없이도 수행 가능).
- 명령어와 기대 결과를 코드블록으로 제공한다.
- BEFORE/AFTER 형식으로 치환 내용을 명시한다 (체크리스트 C3).
- 비자명한 주장에는 인라인 citation을 붙인다 (체크리스트 B1). 예: `Nix rebuild 경로는 main-agent-only [run-da/references/hardening-contract.md의 main-agent-only commands 항목 참조]`.
- 근거 없는 주장은 `[UNVERIFIED]` 라벨 또는 삭제 (체크리스트 E1; 라벨 체계 상세는 [체크리스트 라벨 체계](references/llm-friendly-checklist.md#라벨-체계-anti-hallucination) 참조).

### Step 5: "진실 원천 우선" 원칙 적용

이슈에 기재된 값을 맹신하지 않는다. 가이드의 Phase 1(사전 확인)에서 반드시 CLI/파일시스템에서 실제 현재 값을 확인하는 단계를 포함한다.

예시:
```
이슈에 "현재 버전은 1.2.3"이라고 적혀 있더라도,
Phase 1에서 `grep version <파일>`로 실제 값을 확인하라는 지시를 포함한다.
실제 값이 이슈와 다르면 실제 값을 기준으로 진행한다.
```

이 원칙은 이슈 작성 시점과 가이드 실행 시점 사이의 시간차를 보상한다.
로컬 모드에서도 동일하게 적용한다. 대화 컨텍스트의 기억보다 cwd의 파일시스템, `git status`, `rg`, 관련 CLI의 실측 결과를 우선한다.

### Step 6: 커밋 메시지 템플릿 사전 작성

이슈 번호가 있는 가이드의 검증+커밋 Phase에는 완전한 커밋 메시지 템플릿을 미리 작성하여 포함한다.

```
git commit -m "$(cat <<'EOF'
<type>(<scope>): <요약>

<상세 설명>

Closes #<이슈번호>
EOF
)"
```

LLM이 커밋 메시지를 자의적으로 작성하지 않고, 가이드에 명시된 템플릿을 사용하도록 한다.
이슈가 없는 로컬 모드에서는 이슈 번호를 invent하지 않는다. 커밋이 작업 범위에 포함될 때만 템플릿을 넣고, `Closes #<이슈번호>` 줄은 명시적 이슈가 있을 때만 사용한다.

### Step 7: DA 피드백 수행 지시 포함

가이드의 마지막 Phase 또는 주의사항에 DA 피드백 루프 수행을 권장하는 지시를 포함한다.

```
구현 완료 후, run-da 스킬(for_pr 모드)을 실행하여
코드 품질을 검증한 뒤 PR을 생성하라.
```

### Step 8: Self-verification 패스 (CoVe 경량)

게시 또는 로컬 파일 저장 전 초안에 대해 Chain-of-Verification 경량판을 수행한다 (체크리스트 E2).
출처: [Chain-of-Verification (arXiv 2309.11495)](https://arxiv.org/abs/2309.11495), [Self-Alignment for Factuality (ACL 2024)](https://aclanthology.org/2024.acl-long.107/).

절차:
1. Claim 추출: 가이드 본문에서 비자명한 주장을 추출. 자명/trivial 사실 제외.
2. 검증 질문 재작성: 각 claim을 검증 질문으로 변환. 예: `"파일 X에 Y 함수가 있다"` → `"실제 파일 X에 Y 함수가 있는가?"`
3. 독립 답변: 초안을 보지 않은 상태로 파일 읽기·검색 도구 또는 `gh` CLI 재실행으로 질문에 답.
4. 불일치 처리: 답변과 초안이 일치하지 않으면 초안 수정. 확인 불가 시 `[UNVERIFIED]` 라벨 또는 삭제.

같은 시점에 공개 sanitization post-render scan을 수행한다: [references/sanitization-checklist.md](references/sanitization-checklist.md)의 금지(S1)/보존(S2) 기준, S3 scan 절차, 언어 유지 규칙(S4)을 초안에 적용한다. blanket redaction 금지 — S2 항목(repo-relative path, 검증 명령/결과, 실패 증상)은 지우지 않는다. 기본 모드(공개 게시)는 전체 적용하고, 로컬 모드는 S1 중 시크릿/토큰/키/복호화 값 금지만 적용한다.

이 E1/E2 anti-hallucination 계약과 작성 품질 계약은 기본 모드와 로컬 모드에 동일하게 적용된다. 게시 대상만 이슈 코멘트와 cwd 파일로 갈라진다.

### Step 9: 게시 또는 로컬 파일 저장

#### 기본 모드: 이슈 코멘트 게시

작성한 가이드를 이슈 코멘트로 게시한다. `--body-file`만 허용한다. 본문에는 `$HOME`, `$(...)`, 백틱, 큰따옴표, 내부 `EOF` 등 셸 해석 토큰이 포함될 수 있으며, 이번 스킬이 추가한 `Phase N 검증+커밋` 섹션 자체가 커밋 템플릿용 `cat <<'EOF'...EOF` 예시를 포함한다. 따라서 `$(cat <<'EOF' ... EOF)` 래퍼는 inner `EOF`에서 조기 종료되어 본문이 잘리거나 명령이 실행된다. `--body "<본문>"` 직접 전달과 quoted HEREDOC 모두 금지.

```bash
# 필수: 본문을 파일에 저장한 뒤 --body-file로 전달
gh issue comment <number> --body-file <path-to-guide.md>
```

참고: `gh issue comment --body-file -`로 stdin도 허용되지만, 생성된 가이드를 파일로 저장하는 워크플로가 디버깅·재실행에 유리하다.

#### 로컬 모드: cwd 파일 출력

`LOCAL_MODE=true`이면 이슈 코멘트 게시를 수행하지 않는다. cwd에 `HANDOFF-<주제-슬러그>.local.md`를 만들고, 최종 응답에 파일 경로를 보고한다.

- 출력 위치는 항상 현재 작업 디렉토리(cwd)이다. 이슈 URL의 repo root나 홈 디렉토리로 바꾸지 않는다.
- 파일명은 `HANDOFF-<주제-슬러그>.local.md`이다. 동일 파일명이 이미 있으면 더 구체적인 slug를 사용해 덮어쓰기를 피한다.
- 루트 `.gitignore`의 `*.local.md` 규칙에 자동 매칭되므로 repo 추적 오염을 만들지 않는다고 산출물 또는 최종 보고에 명시한다.
- `gh issue comment`, review/thread/issue resolve, `/create-issue` Step 6류 후속 연계는 스킵한다. 로컬 모드는 게시 경로만 바꾸는 것이 아니라, 이슈 경유 없이 새 세션 첫 프롬프트를 남기는 출력 경로이다.

## 복잡도별 분기

### 단순 (Phase 3)

| Phase | 내용 |
|-------|------|
| 1. 사전 확인 | 현재 값 확인 (1-2개 파일) |
| 2. 실행 | BEFORE/AFTER 치환 |
| 3. 검증 + 커밋 | grep 확인 + 커밋 |

단일 세션(~10분)으로 완료 가능. 가이드를 하나의 프롬프트로 전달한다.

### 중간 (Phase 4)

| Phase | 내용 |
|-------|------|
| 1. 사전 확인 | 현재 값 + 의존성 확인 |
| 2. 핵심 변경 | 주요 로직/설정 수정 |
| 3. 부수 변경 | 관련 파일 업데이트 |
| 4. 검증 + 커밋 | 빌드 + 기능 확인 + 커밋 |

단일 세션(~15분)으로 완료 가능. 가이드를 하나의 프롬프트로 전달한다.

### 복잡 (Phase 6)

| Phase | 내용 |
|-------|------|
| 1. 사전 확인 + 아키텍처 파악 | 현재 구조, 의존 관계, 영향 범위 분석 |
| 2. 기반 구조 변경 | 새 모듈/파일 생성, 인터페이스 정의 |
| 3. 핵심 로직 마이그레이션 | 기존 코드를 새 구조로 이전 |
| 4. 부수 코드 업데이트 | 참조, import, 설정 파일 갱신 |
| 5. 통합 검증 | 빌드 + 전체 기능 테스트 |
| 6. 정리 + 커밋 | old 아티팩트 제거 + 커밋 |

다중 세션 전략: 각 Phase를 `<details>` 접기로 제공하여 세션별로 독립 실행 가능하게 한다.

## 주의사항

- 복잡한 이슈의 세션 분리: Phase 6인 복잡한 이슈는 각 Phase를 `<details>` 태그로 접어서 제공한다. LLM이 한 세션에서 하나의 Phase만 펼쳐 실행하고, 다음 세션에서 다음 Phase를 진행한다.
- 대안 선택 기준 명시: 구현 방법에 대안이 있으면 각 대안의 장단점과 추천 선택지를 명시한다. LLM이 자의적으로 판단하지 않도록 한다.
- 환경별 분기 명시: macOS/NixOS 분기, `ssh minipc` 필요 여부 등 환경에 따라 달라지는 행동을 명확히 기술한다.
- 병렬 힌트 제공: 독립적으로 실행 가능한 명령에는 `(병렬 가능)` 힌트를 명시하여 LLM이 병렬 실행을 활용하도록 유도한다.
## 참조 자료

- [references/guide-template.md](references/guide-template.md) — LLM 이행 가이드 마크다운 템플릿 + TL;DR 블록 + 헤더 블록/Phase 구조/커밋 템플릿/QA 체크리스트 + 모범 패턴
- [references/llm-friendly-checklist.md](references/llm-friendly-checklist.md) — `create-issue`/`write-handoff` 공유 체크리스트. Normative(스킬 강제) + Informational(권장) 분리. 라벨 체계(`[UNVERIFIED]`/`[INFERRED]`/`[CONFLICTING]`)와 출처 링크
- [references/sanitization-checklist.md](references/sanitization-checklist.md) — `create-issue`/`write-handoff` 공유 단일 진실 원천. 공개 게시물 금지/보존 항목(S1/S2), post-render scan 절차(S3), 언어 유지 규칙(S4)
