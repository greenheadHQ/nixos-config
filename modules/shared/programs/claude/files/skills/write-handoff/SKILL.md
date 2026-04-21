---
name: write-handoff
argument-hint: "[issue-number or URL]"
description: |
  Write LLM migration guide comment on GitHub issue.
  Trigger: 'LLM 이행', '이행 가이드', '인수인계', '세션 인수인계', 'write-handoff', 'handoff'.
  NOT for PR 본문 (use create-pr). NOT for 이슈 생성 (use create-issue).
---

# LLM 이행 가이드 작성

`$ARGUMENTS`로 이슈 번호(예: `#252`, `252`) 또는 이슈 URL을 수신한다.
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
| 사용자에게 질문 | `AskUserQuestion` 도구 | plain-text 번호 질문 |
| helper 스크립트 경로 | `~/.claude/scripts/write-handoff-repo-slug.sh` | `~/.codex/scripts/write-handoff-repo-slug.sh` |

본문의 "질문 도구"는 위 표의 런타임별 질문 도구를 가리킨다.
helper 스크립트는 양 런타임에서 동일 source를 공유한다 (Home Manager로 각 경로에 프로비저닝).

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
| 7 | **Next Session Starter 블록** | 다음 세션 LLM이 바로 실행할 명령어/재개 지점 (recency bias) |

복잡도에 따라 Phase 수가 3-6개로 조정된다. 상세 템플릿은 [references/guide-template.md](references/guide-template.md) 참조.

템플릿 상단의 **TL;DR 블록** (상황/현재 상태/다음 액션/Blockers)과 말미의 **Next Session Starter 블록** (재개 지점)은 `references/guide-template.md`에서 정의한다. primacy/recency bias를 활용하여 새 세션 LLM의 맥락 파악 속도를 높인다 (출처: [Lost in the Middle (TACL 2024)](https://direct.mit.edu/tacl/article/doi/10.1162/tacl_a_00638/119630/Lost-in-the-Middle-How-Language-Models-Use-Long)).

## 절차

### Step 1: 이슈 내용 읽기 + 컨텍스트 확보

**1-A. 이슈 읽기**

`$ARGUMENTS`가 비어있으면 런타임 도구 매핑 표의 질문 도구로 이슈 번호 또는 URL을 요청한다.
`$ARGUMENTS`에서 이슈 번호 또는 URL을 파싱한다.

```bash
# 이슈 번호인 경우
gh issue view <number> --json title,body,labels,assignees,comments

# URL인 경우
gh issue view <url> --json title,body,labels,assignees,comments
```

이슈 본문, 라벨, 기존 코멘트를 분석하여 작업 범위를 파악한다.

**1-B. Repo slug 확보 (필수)**

LLM이 helper 스크립트를 직접 호출한다. 런타임 도구 매핑 표의 helper 경로를 사용한다.

```bash
# Claude Code 세션
~/.claude/scripts/write-handoff-repo-slug.sh "$ARGUMENTS"
# Codex 세션
~/.codex/scripts/write-handoff-repo-slug.sh "$ARGUMENTS"
```

우선순위 (helper 내부, fail-closed):
1. **이슈 인자가 있으면**: `gh issue view "$issue_arg" --json url`로 URL 파싱. 실패 시 **빈 줄 반환 (cwd fallback 하지 않음)**.
2. **이슈 인자가 없으면**: cwd repo의 `gh repo view --json nameWithOwner`.
3. 결과가 빈 줄이면 → 아래 **1-D. 값 확보 실패 처리**.

**주의 (bare 번호 입력 시 cwd 의존)**: `$ARGUMENTS`가 `123`, `#123` 같은 bare 번호일 때 `gh issue view 123`은 **cwd repo의 이슈로 해석**된다. cwd가 handoff 대상 repo와 다르면 **전혀 다른 이슈**를 resolve하여 잘못된 repo slug를 placeholder 검증을 통과하는 형태로 반환할 수 있다. `gh issue view --json`은 `repository` 필드를 지원하지 않으므로 이 모호성을 helper 내부에서 제거할 방법이 없다. bare 번호 입력 시 LLM은:

1. `gh repo view --json nameWithOwner -q .nameWithOwner`로 현재 cwd repo를 확인한다.
2. 작업 맥락(이슈 본문의 파일 경로, 사용자 요청 등)을 살펴 cwd가 handoff 대상 repo와 일치하는지 판단한다.
3. 확신이 없으면 런타임 도구 매핑 표의 질문 도구로 **이슈 URL 또는 repo slug**를 사용자에게 명시적으로 확답받고, helper를 URL 인자로 재실행한다.

bare 번호 + cwd 불일치 조합은 Step 1-D 실패 처리 대상이다.

**1-C. Handoff 대상 branch 확보 (필수)**

`git branch --show-current`는 작성자 LLM의 cwd 현재 branch일 뿐, handoff 대상 branch가 아니다.
사용자가 main으로 돌아왔거나 다른 feature branch에서 `/write-handoff <num>`을 호출한 경우,
엉뚱한 branch가 NSS에 주입되어 placeholder 검증을 통과해도 의미상 잘못된 branch가 게시될 수 있다.
cwd 기반 추정을 사용하지 않고 아래 절차를 따른다.

1. **GraphQL linkedBranches 1순위**: 이슈에 Development panel로 명시적 연결된 branch 조회. `nodes`가 비어 있지 않으면 그 값 사용.
   ```bash
   gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){
     repository(owner:$o,name:$r){
       issue(number:$n){
         linkedBranches(first:1){nodes{ref{name}}}
       }
     }
   }' -f o="<OWNER>" -f r="<REPO>" -F n=<NUM> \
     -q '.data.repository.issue.linkedBranches.nodes[0].ref.name'
   ```
2. **closedByPullRequestsReferences 2순위**: 이미 PR이 연결된 이슈면 2-step hop으로 branch 조회. `gh issue view --json closedByPullRequestsReferences`는 `number`/`url`/`repository`만 반환하고 `headRefName`을 포함하지 않으므로 PR 번호를 받은 뒤 `gh pr view`로 다시 조회한다.
   ```bash
   PR_NUM=$(gh issue view "$NUM" --json closedByPullRequestsReferences \
     -q '.closedByPullRequestsReferences[0].number' 2>/dev/null)
   [ -n "$PR_NUM" ] && [ "$PR_NUM" != "null" ] && \
     gh pr view "$PR_NUM" --json headRefName -q .headRefName
   ```
3. **사용자 직접 확답 (최종 게이트)**: 1·2에서 값 확보 실패 시 런타임 도구 매핑 표의 질문 도구로 handoff 대상 branch를 질의한다. bypass 불가. `git branch --show-current`의 cwd branch를 묵시적 default로 사용하지 않는다.

**`gh CLI --json` wrapper 제약**: `gh issue view --json`은 REST-style wrapper 필드만 노출하여 `repository`/`linkedBranches` 필드를 지원하지 않는다 (gh 2.89.0 최신에서도 동일). GitHub GraphQL API 자체는 [`Issue.repository`](https://docs.github.com/en/graphql/reference/objects#repository)와 [`Issue.linkedBranches`](https://docs.github.com/en/graphql/reference/objects#linkedbranch) 타입을 제공하므로 위처럼 `gh api graphql`로 직접 조회한다.

**1-D. 값 확보 실패 / 유효성 검사 처리**

1-B 또는 1-C 결과가 빈 문자열, `null` 리터럴 문자열, placeholder 형태(`<...>`)인 경우:
1. helper를 재실행하거나 (1-B), `gh api graphql` 쿼리 / PR 2-step hop을 직접 재시도한다 (1-C).
2. 여전히 실패하면 런타임 도구 매핑 표의 질문 도구로 사용자에게 repo slug / branch를 확답받는다.
3. **NSS 블록에 unresolved placeholder(`<REPO_SLUG>`, `<BRANCH_NAME>`, `<unknown-*>`, 빈 문자열)가 남은 상태로는 Step 9(게시)로 진행하지 않는다.** Step 8 self-verification에서 placeholder 잔존 여부를 재검증한다.

**Shell-안전성 가드 (필수)**: NSS 블록은 `REPO='...'` / `BRANCH='...'` 처럼 single-quoted literal로 값을 삽입하여 `$(...)`, 백틱, `$var` 해석을 차단한다. 확보한 값에 **`'`(single quote)** 가 포함되면 single-quoted literal을 조기에 닫아 주변 명령을 오염시킬 수 있으므로 치환 즉시 게시를 중단하고 질문 도구로 사용자에게 escape 전략을 확답받는다. (참고: `\`는 Git이 `git check-ref-format`에서 거부하므로 branch 이름에 존재할 수 없고, `$`/`"`/백틱은 Git이 허용하지만 single-quoted literal 내부에서는 리터럴로 처리되어 안전하다.)

Next Session Starter 블록 작성 시 위에서 확보한 두 값을 실제 값으로 치환해 handoff 본문에 포함한다. 예시 template의 repo slug(`greenheadHQ/nixos-config` 등) 하드코딩을 그대로 두지 않는다.

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
- `Glob "**/*.nix"` 또는 `find . -name "*.nix" -path "*<키워드>*"` — 파일 경로 검색
- `Grep -n "<심볼>" <경로>` — import/상수/테스트 참조 발견
- `git log --oneline -20 -- <경로>` — 최근 변경 이력
- `git blame <파일>` — 라인별 맥락

관련 파일 누락 방지: `Grep "<심볼>" modules/ libraries/ tests/`로 repo 전체 재검색.

### Step 4: Phase별 가이드 작성

[references/guide-template.md](references/guide-template.md)의 템플릿에 따라 각 Phase를 작성한다.

**Phase 작성 원칙:**
- 각 Phase는 독립 실행 가능해야 한다 (이전 Phase의 출력에 의존하되, 맥락 공유 없이도 수행 가능).
- 명령어와 기대 결과를 코드블록으로 제공한다.
- BEFORE/AFTER 형식으로 치환 내용을 명시한다 (체크리스트 C3).
- **비자명한 주장에는 인라인 citation을 붙인다** (체크리스트 B1). 예: `Nix rebuild 경로는 main-agent-only [run-da/SKILL.md의 main-agent-only commands 항목 참조]`.
- **근거 없는 주장은 `[UNVERIFIED]` 라벨 또는 삭제** (체크리스트 E1). 근접 추론은 `[INFERRED]`, 출처 상충은 `[CONFLICTING]`.

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
3. **독립 답변**: 초안을 보지 않은 상태로 `Read`/`Grep`/`gh` 재실행으로 질문에 답.
4. **불일치 처리**: 답변과 초안이 일치하지 않으면 초안 수정. 확인 불가 시 `[UNVERIFIED]` 라벨 또는 삭제.
5. **NSS placeholder 검증 (필수)**: Next Session Starter 블록의 BRANCH와 REPO가 다음 중 하나라도 해당하면 Step 1-D "값 확보 실패 처리" 순서로 실제 값 확보 후 치환. 치환 완료 전에는 Step 9(게시)로 진행하지 않는다.
    - `<...>` 형태 placeholder (`<REPO_SLUG>`, `<BRANCH_NAME>`, `<unknown-*>`, `<repo-root-path>` 등)
    - 빈 문자열
    - `null` 리터럴 문자열 (jq 쿼리가 `linkedBranches=[]`에서 `null`을 출력하는 케이스)
    - `refs/heads/main` 같은 기본 branch가 실제 handoff 대상과 다른 경우
    - **REPO 값이 Step 1-B에서 확보한 repo slug와 불일치**: 예시 template의 repo slug(`greenheadHQ/nixos-config` 등)이 남아 있고 실제 handoff 대상이 다른 repo인 경우. Step 1-B에서 확보한 repo slug와 **문자열 비교하여 동일 여부 확인**. 다르면 반드시 치환.
6. **Shell-안전성 재검증 (필수)**: NSS 블록의 `REPO=` / `BRANCH=` 할당이 **single-quoted literal(`'...'`)** 형태인지 확인하고, 값에 `'`(single quote)이 포함되어 있으면 Step 9를 중단한다 (Step 1-D Shell-안전성 가드 참조).

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
- **QA 체인**: 스킬 관련 이슈의 기본 QA 체인은 `/run-da for_pr` + skill-creator 플러그인(evals/queries.json 검증)이다. `/parallel-audit`는 다중 스킬 영향·광범위 사이드이펙트·고위험 변경일 때만 조건부로 추가한다. 검증 축(frontmatter/구조/links/evals)은 유지하고 도구만 활성 경로로 교체한다.
- **병렬 힌트 제공**: 독립적으로 실행 가능한 명령에는 `(병렬 가능)` 힌트를 명시하여 LLM이 병렬 실행을 활용하도록 유도한다.
- **Anti-hallucination 라벨**: 미검증 사항은 `[UNVERIFIED]` 인라인 라벨 사용 (체크리스트 E1). 근접 추론은 `[INFERRED]`, 출처 상충은 `[CONFLICTING]`. `<!-- 미검증: ... -->` HTML 주석은 **DEPRECATED** — 신규 가이드는 `[UNVERIFIED]` 라벨을 사용한다.

## 참조 자료

- **[references/guide-template.md](references/guide-template.md)** — LLM 이행 가이드 마크다운 템플릿 + TL;DR 블록 + Next Session Starter 블록 + 헤더 블록/Phase 구조/커밋 템플릿/QA 체크리스트 + 모범 패턴
- **[references/llm-friendly-checklist.md](references/llm-friendly-checklist.md)** — `create-issue`/`write-handoff` 공유 체크리스트. Normative(스킬 강제) + Informational(권장) 분리. 라벨 체계(`[UNVERIFIED]`/`[INFERRED]`/`[CONFLICTING]`)와 출처 링크
