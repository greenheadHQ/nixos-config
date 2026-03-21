---
name: review-pr-feedback
description: |
  Triage PR comments (CodeRabbit, AI, human) and apply valid feedback.
  Trigger: 'PR 코멘트', 'coderabbit', '코드리뷰 반영', '리뷰 피드백', 'PR 피드백 처리'.
  NOT for DA (use run-da). NOT for PR 본문 (use create-pr).
---

# PR 리뷰 피드백 처리

PR에 달린 모든 리뷰 코멘트를 수집하고, 각 피드백을 다각도로 검증하여
유효한 것만 코드에 반영한 뒤, 모든 피드백에 사유를 답변하는 스킬.

## 빠른 참조

| 항목 | 설명 |
|------|------|
| 입력 | 현재 브랜치의 PR 또는 PR 번호/URL |
| 출력 | 유효 피드백 반영 커밋 + 전체 피드백 답글 |
| 대상 | CodeRabbit, AI 리뷰어, 인간 팀원의 모든 코멘트 |
| 핵심 도구 | gh CLI, 코드베이스 검색, 에이전트 병렬 실행 |

## 절차

### Step 1: PR 코멘트 수집

현재 브랜치에 연결된 PR의 미해결 코멘트를 전체 수집한다.

```bash
# 현재 브랜치의 PR 번호 확인
gh pr view --json number -q .number

# PR의 리뷰 코멘트 전체 수집 (review comments)
gh api repos/{owner}/{repo}/pulls/{pr_number}/comments --paginate

# PR의 일반 코멘트 수집 (issue comments)
gh api repos/{owner}/{repo}/issues/{pr_number}/comments --paginate

# PR의 리뷰 요약 수집
gh api repos/{owner}/{repo}/pulls/{pr_number}/reviews --paginate
```

REST API는 review thread의 resolved 상태를 제공하지 않는다. resolved 상태를 확인하려면 GraphQL `reviewThreads` 쿼리의 `isResolved` 필드를 사용한다.

```bash
gh api graphql -f query='
  query($owner: String!, $repo: String!, $pr: Int!) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $pr) {
        reviewThreads(first: 100) {
          nodes {
            isResolved
            comments(first: 10) {
              nodes { body author { login } path line }
            }
          }
        }
      }
    }
  }
' -f owner='{owner}' -f repo='{repo}' -F pr='{pr_number}'
```

수집한 코멘트 중 이미 resolved된 것은 제외한다.
나머지를 리뷰어별, 파일별로 정리한다.

### Step 2: 코멘트 분류

각 코멘트를 다음 3개 카테고리로 분류한다:

| 카테고리 | 설명 | 기본 처리 |
|----------|------|----------|
| **actionable** | 코드 변경이 필요한 실질적 피드백 | Step 3 검증 후 반영 |
| **outside-diff** | 이번 PR diff 범위 밖의 지적 | 별도 이슈로 분리하거나 기각 |
| **nitpick** | 스타일/취향 수준의 사소한 지적 | 합리적이면 반영, 아니면 기각 |

분류가 애매한 코멘트는 actionable로 분류하여 Step 3에서 면밀히 검증한다.

### Step 3: 다각도 검증

actionable로 분류된 각 피드백을 다음 7개 기준으로 검증한다:

**유효성 (Validity)**
지적이 실제 문제인가? 코드를 직접 확인하여 리뷰어의 지적이 사실에 기반하는지 검증한다.
존재하지 않는 문제를 지적한 경우 HALLUCINATION으로 표시한다.

**타당성 (Soundness)**
제안된 수정이 합리적인가? 리뷰어가 제안한 해결 방법이 문제를 실제로 해결하는지,
더 나은 대안이 없는지 확인한다.

**복잡성 (Complexity)**
수정 비용 대비 효용이 있는가? 사소한 개선을 위해 대규모 리팩토링을 요구하는 경우,
비용-효용 분석을 수행한다.

**실현가능성 (Feasibility)**
현재 아키텍처에서 구현 가능한가? Nix 표현식 제약, 플랫폼 호환성, 의존성 등
기술적 제약을 고려하여 실현 가능 여부를 판단한다.

**YAGNI**
불필요한 추가를 요구하는 것은 아닌가? "미래에 필요할 수 있으니 지금 추가하자"는
충분한 근거가 아니다.

**REGRESSION**
수정 시 다른 기능에 회귀가 발생하지 않는가? 변경의 영향 범위를 코드베이스 전체에서
추적하여 회귀 위험을 평가한다.

**HALLUCINATION**
리뷰어가 존재하지 않는 문제를 지적한 것은 아닌가? AI 리뷰어(CodeRabbit 등)는
코드 맥락을 잘못 이해하고 허위 문제를 지적하는 경우가 있다.
해당 코드를 직접 읽어 확인한다.

### Step 4: 유효 피드백 반영

검증 기준을 통과한 피드백만 코드에 반영한다.

- 각 피드백별로 필요한 코드 변경을 수행한다.
- 변경 후 기존 기능에 회귀가 없는지 확인한다.
- 관련된 피드백들은 가능하면 하나의 논리적 단위로 묶어 변경한다.

### Step 5: 커밋 및 푸시

반영한 변경 사항을 커밋하고 원격에 푸시한다.

- 커밋 메시지에 어떤 피드백을 반영했는지 명시한다.
- conventional commit 형식을 따른다 (예: `fix(module): address PR feedback`).
- 반영할 피드백이 여러 영역에 걸쳐 있으면, 논리적으로 분리하여 복수 커밋으로 나눈다.

### Step 6: 피드백 답글 작성

모든 피드백(반영 여부 무관)에 대해 사유를 담은 답글을 작성한다.

```bash
# 리뷰 코멘트에 답글
gh api repos/{owner}/{repo}/pulls/{pr_number}/comments/{comment_id}/replies \
  -f body="답글 내용"

# 일반 코멘트에 답글
gh api repos/{owner}/{repo}/issues/{pr_number}/comments \
  -f body="답글 내용"
```

답글 작성 기준:

| 처리 결과 | 답글 내용 |
|----------|----------|
| **반영** | 어떻게 반영했는지 간략 설명 + 커밋 해시 참조 |
| **기각 (HALLUCINATION)** | 실제 코드 동작을 근거로 지적이 사실과 다름을 설명 |
| **기각 (YAGNI)** | 현재 불필요한 이유를 간결히 설명 |
| **기각 (REGRESSION)** | 수정 시 발생할 회귀 위험을 구체적으로 설명 |
| **기각 (복잡성)** | 비용-효용 분석 결과를 제시 |
| **별도 이슈 분리** | 생성한 이슈 번호를 링크 |

## 검증 기준 요약

| 기준 | 질문 | 실패 시 |
|------|------|---------|
| 유효성 | 지적이 실제 문제인가? | 기각 (HALLUCINATION) |
| 타당성 | 제안된 수정이 합리적인가? | 대안 제시 또는 기각 |
| 복잡성 | 수정 비용 대비 효용이 있는가? | 기각 (비용 과다) |
| 실현가능성 | 현재 아키텍처에서 가능한가? | 기각 (기술 제약) |
| YAGNI | 지금 필요한 변경인가? | 기각 (불필요) |
| REGRESSION | 수정 시 회귀 위험이 없는가? | 기각 (회귀 위험) |
| HALLUCINATION | 리뷰어의 지적이 사실인가? | 기각 (허위 지적) |

### 기각 포맷

기각 시 다음 필드를 모두 포함한다:

| 필드 | 필수 | 설명 |
|------|------|------|
| **기각 분류** | ✅ | `HALLUCINATION` / `VERIFIED_FALSE_POSITIVE` / `STALE_REVIEW` / `SCOPE_DEFERRAL` / `DESIGN_TRADEOFF` / `TECHNICAL_DISAGREEMENT` / `WRONG_REFERENCE` 중 택1 |
| **검증 방법** | ✅ | Read 도구로 확인한 파일:줄, 또는 로컬 재현 결과 |
| **기술적 근거** | ✅ | 1문장 이상 |
| **신뢰도** | ✅ | HIGH / MEDIUM / LOW (LOW 시 사용자 AskUserQuestion) |

## 검증 의무

### 피드백 검증 시 로컬 확인 의무
- 리뷰어의 각 지적을 수용하기 전에, 해당 파일:줄을 직접 Read 도구로 읽어 지적이 사실인지 확인한다.
- 가능하면 로컬에서 재현을 시도한다 (빌드, 명령 실행, 설정 확인 등).
- "리뷰어가 지적했으니 맞겠지"라는 가정으로 검증 없이 수용하지 않는다.
- 특히 AI 리뷰어(CodeRabbit 등)의 피드백은 HALLUCINATION 비율이 높으므로, 반드시 코드를 직접 읽어 확인한 뒤 수용/기각한다.
- 사용자에게 판단을 요청할 때는 [사용자 질문 시 맥락 설명 의무](../run-da/SKILL.md#사용자-질문-시-맥락-설명-의무)를 따른다 (WTF Moment 방지).

## 기각 분류 가이드라인 (HALLUCINATION 오분류 방지)

리뷰어의 지적을 기각할 때 정확한 분류를 사용한다.

| 상황 | 올바른 분류 | 잘못된 분류 |
|------|------------|------------|
| 리뷰어가 존재하지 않는 코드/동작을 지적 | `HALLUCINATION` | - |
| 리뷰어가 이미 수정된 코드를 지적 | `STALE_REVIEW` | ~~HALLUCINATION~~ |
| 리뷰어와 기술적 견해가 다름 | `TECHNICAL_DISAGREEMENT` | ~~HALLUCINATION~~ |
| 리뷰어가 잘못된 경로/파일을 참조 | `WRONG_REFERENCE` | ~~HALLUCINATION~~ |
| 리뷰어의 지적이 현재 변경 범위 밖 | `SCOPE_DEFERRAL` | ~~HALLUCINATION~~ |

특히 CodeRabbit(AI 리뷰어)의 지적은 **stale diff 기반 리뷰**인 경우가 많다.
이미 수정된 항목에 대한 지적은 "리뷰어가 날조한 것"(HALLUCINATION)이 아니라
"리뷰 시점의 diff와 현재 상태가 다른 것"(STALE_REVIEW)이다.

(근거: #298 Case 6에서 CodeRabbit 4건을 모두 HALLUCINATION으로 분류. Items #1, #2는 이미 수정된 항목이었으므로 STALE_REVIEW가 정확한 분류.)

## 주의사항

- **모든 피드백에 답글 필수**: 반영하든 기각하든, 사유를 명시한 답글을 남긴다. 무응답은 금지.
- **AI 리뷰어 맹신 금지**: CodeRabbit 등 AI 리뷰어의 피드백도 동일한 검증 기준을 적용한다. AI라고 무조건 맞는 것이 아니며, HALLUCINATION 비율이 특히 높으므로 반드시 코드를 직접 확인한다.
- **outside-diff 처리**: PR 범위 밖의 지적은 유효하더라도 이번 PR에서 처리하지 않는다. 별도 이슈로 등록하거나, 범위 밖임을 답글로 설명한다.
- **반영 전 회귀 확인**: 피드백을 반영할 때마다 변경이 다른 기능을 깨뜨리지 않는지 확인한다. 특히 플랫폼 간(macOS/NixOS) 호환성에 주의한다.
- **기각 사유는 구체적으로**: "불필요합니다"가 아니라, 왜 불필요한지 근거를 제시한다. 리뷰어가 납득할 수 있는 수준의 설명을 작성한다.
