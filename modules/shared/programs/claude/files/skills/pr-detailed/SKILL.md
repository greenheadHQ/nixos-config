---
name: pr-detailed
argument-hint: "[update]"
description: |
  Create/update PR with CIR/Human Test/Pre-Merge guide. Args: (none)=create, update.
  Trigger: 'PR 본문', 'PR 작성', 'PR 만들어줘', 'PR 업데이트', 'Human Test'.
  NOT for DA (use da-feedback). NOT for PR 코멘트 (use review-pr-feedback).
---

# 상세 PR 작성

`$ARGUMENTS`가 비어있으면 새 PR을 생성하고, `update`이면 기존 PR 본문을 업데이트한다.

## 빠른 참조

| 항목 | 위치 |
|------|------|
| 8섹션 PR 본문 템플릿 상세 | [references/pr-template.md](references/pr-template.md) |
| Pre-Merge E2E 테스트 가이드 작성 규칙 | [references/pre-merge-guide.md](references/pre-merge-guide.md) |

## 필수 8섹션 템플릿

PR 본문은 반드시 다음 8개 섹션을 포함한다.

| # | 섹션 | 역할 |
|---|------|------|
| 1 | Summary | 핵심 변경 1-3 bullet + `Closes #N` |
| 2 | 기존 문제/배경 | Pain point — 왜 이 변경이 필요한지 |
| 3 | CIR (Change Intent Record) | 발견 경위 + 설계 의도 + 대안 검토 이력 |
| 4 | ADR (Architecture Decision Record) | 대안 비교 테이블 (대안/설명/장점/단점/결정) |
| 5 | 구현 상세 | 변경 파일 테이블 + 핵심 코드 스니펫 |
| 6 | 참고 레퍼런스 | 관련 PR/이슈/외부 링크 (커밋 해시 포함) |
| 7 | Human Test Plan | 단계별 기대동작 + 실패 시 진단 가이드 |
| 8 | Pre-Merge E2E 테스트 가이드 | LLM이 직접 실행하는 자동 검증 절차 |

각 섹션의 작성 규칙, 예시, 흔한 실수는 [references/pr-template.md](references/pr-template.md) 참조.

## 절차

### 새 PR 생성 (기본)

`$ARGUMENTS`가 비어있거나 `update`가 아닌 경우 새 PR을 생성한다.

1. **변경 분석**: `git diff main...HEAD`와 커밋 히스토리(`git log main..HEAD --oneline`)를 분석하여 변경 범위를 파악한다.
2. **연관 이슈 탐색**: 커밋 메시지, 브랜치명, 변경 내용에서 이슈 번호를 추출한다. 관련 이슈가 있으면 Summary에 `Closes #N`을 포함한다.
3. **CIR 수집**: 코드 인라인 주석(`# CIR:`, `# === Change Intent Record ===`)과 커밋 메시지에서 의사결정 이력을 추출한다. 현재 대화 컨텍스트에서도 방향 전환/대안 거부 이력을 수집한다.
4. **ADR 테이블 구성**: 검토한 대안들을 비교 테이블로 정리한다. 대안이 1개뿐이면 ADR 섹션을 간소화한다.
5. **8섹션 템플릿 작성**: [references/pr-template.md](references/pr-template.md)의 템플릿에 따라 전체 PR 본문을 작성한다.
6. **Pre-Merge E2E 가이드 작성**: [references/pre-merge-guide.md](references/pre-merge-guide.md)의 규칙에 따라 Phase 기반 검증 가이드를 포함한다.
7. **PR 생성**: `gh pr create --title "<제목>" --body "<본문>"`으로 PR을 생성한다. 제목은 70자 미만, conventional commit 형식을 따른다.

### 기존 PR 업데이트 (`update`)

`$ARGUMENTS`가 `update`인 경우 기존 PR 본문을 보강한다.

1. **현재 PR 확인**: `gh pr view --json body,title,number`로 현재 PR 본문을 가져온다.
2. **누락 섹션 탐지**: 8섹션 중 빠진 섹션을 식별한다.
3. **부실 섹션 강화**: 있지만 내용이 부실한 섹션(예: Summary만 있고 CIR 없음)을 보강한다. 커밋 히스토리, 코드 변경, 대화 컨텍스트에서 추가 정보를 수집한다.
4. **업데이트 적용**: `gh pr edit <number> --body "<새 본문>"`으로 PR 본문을 업데이트한다.

## Pre-Merge E2E 테스트 가이드 작성 규칙

PR 본문의 8번째 섹션으로, LLM이 PR을 머지하기 전에 직접 실행할 수 있는 검증 절차를 기술한다.

핵심 구조:
- **Phase 0 (정적 검증)**: 파일 존재 확인, 값 반영 확인, old 값 부재 확인을 grep/ls 등으로 수행한다.
- **Phase 1-N (기능 검증)**: 기능별로 프롬프트 + 기대동작 + 실패 시 진단을 기술한다.
- **Phase N+1 (Regression)**: 인접 기능이 깨지지 않았는지 의도적으로 혼동 가능한 쿼리로 검증한다.

상세 작성 규칙은 [references/pre-merge-guide.md](references/pre-merge-guide.md) 참조.

## 주의사항

- **ADR 테이블 표기**: 채택한 대안은 ✅, 기각한 대안은 ❌로 표시한다.
- **참고 레퍼런스에 해시 필수**: 관련 PR/커밋을 언급할 때 반드시 커밋 해시(단축 7자) + 1줄 설명을 포함한다. 해시 없는 "관련 PR 참조" 식의 모호한 레퍼런스는 금지한다.
- **DA 피드백 분리**: DA 피드백 루프 결과는 PR 본문이 아닌 별도 코멘트로 분리한다. PR 본문에는 최종 결론만 반영한다.
- **CIR 없는 PR**: 단순 변경(타이포 수정, 버전 업데이트 등)은 CIR/ADR 섹션을 "해당 없음 — 단순 변경"으로 간소화한다. 무리하게 의사결정 이력을 만들어내지 않는다.
- **Codex 호환**: 특정 도구명을 하드코딩하지 않는다. "gh pr create를 실행한다"가 아니라 "PR을 생성한다"처럼 행동 의도로 기술한다. 단, 참조/예시에서의 CLI 명령은 예외로 허용한다.

## 참조 자료

- **[references/pr-template.md](references/pr-template.md)** — 8섹션 PR 본문 마크다운 템플릿 + 섹션별 작성 규칙/예시/흔한 실수
- **[references/pre-merge-guide.md](references/pre-merge-guide.md)** — Pre-Merge E2E 테스트 가이드 작성 규칙 + Phase 구조 + 결과 보고 형식
