---
name: write-handoff
argument-hint: "[issue-number or URL]"
description: |
  Write LLM migration guide comment on GitHub issue.
  Trigger: 'LLM 이행', '이행 가이드', '인수인계', '세션 인수인계', 'write-handoff', 'handoff'.
  NOT for PR 본문 (use create-pr). NOT for 이슈 생성 (use create-issue).
---

# LLM 이행 가이드 작성

`$ARGUMENTS`로 이슈 번호(예: `#123`, `123`) 또는 이슈 URL을 수신한다.
해당 이슈를 분석하여 LLM이 자율적으로 처음부터 끝까지 작업을 수행할 수 있는
Phase 기반 이행 가이드를 작성하고, 이슈 코멘트로 게시한다.

## 빠른 참조

| 항목 | 위치 |
|------|------|
| 이행 가이드 마크다운 템플릿 | [references/guide-template.md](references/guide-template.md) |

## 런타임 도구 매핑

이 스킬은 Claude Code 세션과 direct Codex 세션 모두에서 동작한다.
아래 행동은 런타임에 해당하는 도구로 수행한다.

| 행동 | Claude Code 세션 | Codex 세션 |
|------|------------------|------------|
| 사용자에게 질문 | `AskUserQuestion` 도구 | `request_user_input` |

본문의 "질문 도구"는 위 표의 런타임별 질문 도구를 가리킨다.

## 가이드 구조

이행 가이드는 다음 섹션으로 구성한다.

| # | 섹션 | 역할 |
|---|------|------|
| 0 | **TL;DR 블록** | 상황/현재 상태/다음 액션/Blockers — 새 세션 LLM이 가이드 상단에서 전체 맥락 파악 (primacy bias) |
| 1 | 헤더 블록 | 대상/목표/예상소요/난이도 — 한눈에 파악 가능한 메타 정보 |
| 2 | 핵심 원칙 | 행동 제약 1-3개 — 작업 전체에 적용되는 불변 규칙 |
| 3 | Phase 1: 사전 확인 | CLI/파일시스템에서 현재 값 확인 (병렬 가능 힌트 포함) |
| 4 | Phase 2: 실행 | BEFORE/AFTER 치환 또는 상세 변경 지시 |
| 5 | Phase 3: 검증 + 커밋 | 빌드 확인 + git add/commit 템플릿 |
| 6 | 주의사항 | 환경 분기, 대체 행동, 예외 처리 |

복잡도에 따라 Phase 수가 3-6개로 조정된다. 상세 템플릿은 [references/guide-template.md](references/guide-template.md) 참조.

템플릿 상단의 **TL;DR 블록** (상황/현재 상태/다음 액션/Blockers)은 `references/guide-template.md`에서 정의한다. primacy bias를 활용하여 새 세션 LLM의 맥락 파악 속도를 높인다 (출처: [Lost in the Middle (TACL 2024)](https://direct.mit.edu/tacl/article/doi/10.1162/tacl_a_00638/119630/Lost-in-the-Middle-How-Language-Models-Use-Long)).

## 절차

### Step 1: 이슈 내용 읽기 + 컨텍스트 확보

`$ARGUMENTS`가 비어있으면 런타임 도구 매핑 표의 질문 도구로 이슈 번호 또는 URL을 요청한다.
`$ARGUMENTS`에서 이슈 번호 또는 URL을 파싱한다.

```bash
# 이슈 번호인 경우
gh issue view <number> --json title,body,labels,assignees,comments

# URL인 경우
gh issue view <url> --json title,body,labels,assignees,comments
```

**bare 번호 입력 시 cwd 확인 필수**: `$ARGUMENTS`가 `123`, `#123` 같은 bare 번호이고 `gh repo view --json nameWithOwner -q .nameWithOwner`로 확인한 cwd repo가 handoff 대상 repo와 다를 가능성이 있으면, 질문 도구로 사용자에게 이슈 URL(`https://github.com/owner/repo/issues/N` 형태)을 재확인받은 뒤 그 URL로 `gh issue view`를 재실행한다. 확인 없이 진행하면 cwd repo의 동일 번호 이슈에 잘못 코멘트가 게시될 수 있다.

이슈 본문, 라벨, 기존 코멘트를 분석하여 작업 범위를 파악한다.

### Step 2: 복잡도 판단

이슈의 변경 규모와 범위를 판단하여 Phase 깊이를 결정한다.

| 복잡도 | Phase 수 | 세션 전략 | 판단 기준 | 예시 |
|--------|---------|----------|----------|------|
| 단순 | 3 | 단일 세션 ~10분 | 파일 1-2개, 값 치환 수준 | 버전 업데이트, 경로 변경, 상수 교체 |
| 중간 | 4 | 단일 세션 ~15분 | 파일 3-5개, 로직 수정 포함 | 옵션 추가, 조건분기 변경, 설정 구조 변경 |
| 복잡 | 6 | 다중 세션, Phase별 독립 프롬프트 | 파일 6개 이상, 아키텍처 수준 변경 | 대규모 리팩토링, 새 모듈 도입, 서비스 마이그레이션 |

복잡도 판단이 애매하면 한 단계 높게 잡는다 (과소 추정보다 과대 추정이 안전).

### Step 3: 변경 대상 추출

이슈에서 다음 정보를 추출한다:

- **변경 대상 파일**: 이슈에 명시된 파일 경로 + 코드베이스 탐색으로 발견한 관련 파일
- **변경 내용**: 각 파일에서 무엇을 어떻게 바꾸는지
- **검증 기준**: 변경이 올바르게 적용되었는지 확인하는 방법

코드베이스를 직접 탐색하여 이슈에 명시되지 않은 관련 파일(예: 상수 참조, 테스트, 설정)도 식별한다.

**탐색 도구 예시** (관련 파일/경로를 찾아 Phase 작성 시 B4 `path:LINE` citation에 활용):
- 셸 `find . -name "*.nix" -path "*<키워드>*"` 또는 그에 상당하는 검색 도구 — 파일 경로 검색
- 셸 `rg -n "<심볼>" <경로>` 또는 그에 상당하는 검색 도구 — import/상수/테스트 참조 발견
- `git log --oneline -20 -- <경로>` — 최근 변경 이력
- `git blame <파일>` — 라인별 맥락

관련 파일 누락 방지: `rg "<심볼>" modules/ libraries/ tests/` 또는 그에 상당하는 검색 도구로 repo 전체 재검색.

### Step 4: Phase별 가이드 작성

[references/guide-template.md](references/guide-template.md)의 템플릿에 따라 각 Phase를 작성한다.

**Phase 작성 원칙:**
- 각 Phase는 독립 실행 가능해야 한다 (이전 Phase의 출력에 의존하되, 맥락 공유 없이도 수행 가능).
- 명령어와 기대 결과를 코드블록으로 제공한다.
- BEFORE/AFTER 형식으로 치환 내용을 명시한다 (체크리스트 C3).
- **비자명한 주장에는 인라인 citation을 붙인다** (체크리스트 B1). 예: `Nix rebuild 경로는 main-agent-only [run-da/references/hardening-contract.md의 main-agent-only commands 항목 참조]`.
- **근거 없는 주장은 `[UNVERIFIED]` 라벨 또는 삭제** (체크리스트 E1; 라벨 체계 상세는 [체크리스트 라벨 체계](references/llm-friendly-checklist.md#라벨-체계-anti-hallucination) 참조).

### Step 5: "진실 원천 우선" 원칙 적용

이슈에 기재된 값을 맹신하지 않는다. 가이드의 Phase 1(사전 확인)에서 반드시 CLI/파일시스템에서 실제 현재 값을 확인하는 단계를 포함한다.

예시:
```
이슈에 "현재 버전은 1.2.3"이라고 적혀 있더라도,
Phase 1에서 `grep version <파일>`로 실제 값을 확인하라는 지시를 포함한다.
실제 값이 이슈와 다르면 실제 값을 기준으로 진행한다.
```

이 원칙은 이슈 작성 시점과 가이드 실행 시점 사이의 시간차를 보상한다.

### Step 6: 커밋 메시지 템플릿 사전 작성

가이드의 검증+커밋 Phase에 완전한 커밋 메시지 템플릿을 미리 작성하여 포함한다.

```
git commit -m "$(cat <<'EOF'
<type>(<scope>): <요약>

<상세 설명>

Closes #<이슈번호>
EOF
)"
```

LLM이 커밋 메시지를 자의적으로 작성하지 않고, 가이드에 명시된 템플릿을 사용하도록 한다.

### Step 7: DA 피드백 수행 지시 포함

가이드의 마지막 Phase 또는 주의사항에 DA 피드백 루프 수행을 권장하는 지시를 포함한다.

```
구현 완료 후, run-da 스킬(for_pr 모드)을 실행하여
코드 품질을 검증한 뒤 PR을 생성하라.
```

### Step 8: Self-verification 패스 (CoVe 경량)

게시 전 초안에 대해 Chain-of-Verification 경량판을 수행한다 (체크리스트 E2).
출처: [Chain-of-Verification (arXiv 2309.11495)](https://arxiv.org/abs/2309.11495), [Self-Alignment for Factuality (ACL 2024)](https://aclanthology.org/2024.acl-long.107/).

절차:
1. **Claim 추출**: 가이드 본문에서 비자명한 주장을 추출. 자명/trivial 사실 제외.
2. **검증 질문 재작성**: 각 claim을 검증 질문으로 변환. 예: `"파일 X에 Y 함수가 있다"` → `"실제 파일 X에 Y 함수가 있는가?"`
3. **독립 답변**: 초안을 보지 않은 상태로 파일 읽기·검색 도구 또는 `gh` CLI 재실행으로 질문에 답.
4. **불일치 처리**: 답변과 초안이 일치하지 않으면 초안 수정. 확인 불가 시 `[UNVERIFIED]` 라벨 또는 삭제.

### Step 9: 이슈 코멘트로 게시

작성한 가이드를 이슈 코멘트로 게시한다. **`--body-file`만 허용**한다. 본문에는 `$HOME`, `$(...)`, 백틱, 큰따옴표, 내부 `EOF` 등 셸 해석 토큰이 포함될 수 있으며, 이번 스킬이 추가한 `Phase N 검증+커밋` 섹션 자체가 커밋 템플릿용 `cat <<'EOF'...EOF` 예시를 포함한다. 따라서 `$(cat <<'EOF' ... EOF)` 래퍼는 inner `EOF`에서 조기 종료되어 본문이 잘리거나 명령이 실행된다. `--body "<본문>"` 직접 전달과 quoted HEREDOC 모두 금지.

```bash
# 필수: 본문을 파일에 저장한 뒤 --body-file로 전달
gh issue comment <number> --body-file <path-to-guide.md>
```

참고: `gh issue comment --body-file -`로 stdin도 허용되지만, 생성된 가이드를 파일로 저장하는 워크플로가 디버깅·재실행에 유리하다.

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

- **복잡한 이슈의 세션 분리**: Phase 6인 복잡한 이슈는 각 Phase를 `<details>` 태그로 접어서 제공한다. LLM이 한 세션에서 하나의 Phase만 펼쳐 실행하고, 다음 세션에서 다음 Phase를 진행한다.
- **대안 선택 기준 명시**: 구현 방법에 대안이 있으면 각 대안의 장단점과 추천 선택지를 명시한다. LLM이 자의적으로 판단하지 않도록 한다.
- **환경별 분기 명시**: macOS/NixOS 분기, `ssh minipc` 필요 여부 등 환경에 따라 달라지는 행동을 명확히 기술한다.
- **병렬 힌트 제공**: 독립적으로 실행 가능한 명령에는 `(병렬 가능)` 힌트를 명시하여 LLM이 병렬 실행을 활용하도록 유도한다.
## 참조 자료

- **[references/guide-template.md](references/guide-template.md)** — LLM 이행 가이드 마크다운 템플릿 + TL;DR 블록 + 헤더 블록/Phase 구조/커밋 템플릿/QA 체크리스트 + 모범 패턴
- **[references/llm-friendly-checklist.md](references/llm-friendly-checklist.md)** — `create-issue`/`write-handoff` 공유 체크리스트. Normative(스킬 강제) + Informational(권장) 분리. 라벨 체계(`[UNVERIFIED]`/`[INFERRED]`/`[CONFLICTING]`)와 출처 링크
