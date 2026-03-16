---
name: da-feedback
argument-hint: "[for_plan|for_pr|both]"
description: |
  Run Devil's Advocate feedback loop with 8 domain-specialized parallel review
  agents (YAGNI, NGMI, HALLUCINATION, SECURITY, SIDE_EFFECT, CONSISTENCY,
  READABILITY, CLEAN_CODE) to rigorously review plans or code.
  Args: for_plan (plan DA 1x), for_pr (code DA 1x), both (2x).
  NOT for PR 코멘트(CodeRabbit 등) 처리 (use review-pr-feedback).
  NOT for 전수조사/감사 (use parallel-audit).
  NOT for PR 본문 작성 (use pr-detailed).
  NOT for 계획 수립 (use plan-with-questions).
  Triggers: "DA", "Devil's Advocate", "피드백 루프", "DA 피드백",
  "da feedback", "코드 리뷰 루프", "YAGNI 리뷰", "DA 리뷰",
  "피드백 루프 실행", "DA loop", "devil's advocate review".
---

# Devil's Advocate 피드백 루프

8개 영역별 전문 DA 에이전트를 병렬 실행하여 계획/코드를 엄격 리뷰한다.

## 모드

| `$ARGUMENTS` | 동작 |
|--------------|------|
| `for_plan` | 계획 단계 DA 1회 — 계획 파일 또는 대화 컨텍스트 대상 |
| `for_pr` | 구현 후 코드 DA 1회 — git diff 대상 |
| `both` | 계획 DA + 사용자 승인 + 구현 + 코드 DA 총 2회 |
| *(비어있음)* | 사용자에게 모드 선택을 질문한다 |

## 빠른 참조

| 항목 | 위치 |
|------|------|
| 8개 DA 영역 상세 + 프롬프트 템플릿 | [references/da-domains.md](references/da-domains.md) |
| 피드백 프로토콜 상세 | [references/protocol.md](references/protocol.md) |

## 8개 DA 영역

| 영역 | 집중 관점 | 심각도 기준 |
|------|----------|-----------|
| YAGNI | 불필요한 추상화, 미래 대비 과설계 | 사용처 0인 코드/인터페이스 존재 |
| NGMI | 근본적 설계 결함, 확장 불가 구조 | 요구사항 변경 시 전면 재작성 필요 |
| HALLUCINATION | 존재하지 않는 API/플래그/경로 사용 | 실행 시 즉시 에러 |
| SECURITY | 인증 우회, 비밀 노출, 입력 미검증 | 공격 표면 확대 |
| SIDE_EFFECT | 수정하지 않은 기존 기능에 대한 영향 | 기존 동작 변경/파괴 |
| CONSISTENCY | 프로젝트 컨벤션/네이밍/구조 위반 | 코드베이스 일관성 훼손 |
| READABILITY | 이해하기 어려운 로직, 주석 부재 | 다음 개발자(LLM 포함)가 의도 파악 불가 |
| CLEAN_CODE | 중복 코드, 매직넘버, 죽은 코드 | 유지보수 비용 증가 |

상세 프롬프트 템플릿과 출력 형식은 [references/da-domains.md](references/da-domains.md) 참조.

## 절차

### for_plan 모드

1. 현재 계획 파일(`.claude/plans/`) 또는 대화 컨텍스트에서 계획 내용을 수집한다.
2. 8개 영역별 DA 에이전트를 **한 턴에 동시 병렬 실행**한다.
   - 각 에이전트에게 계획 전체 내용 + 프로젝트 컨텍스트를 제공한다.
   - 에이전트는 읽기 전용이며 수정 권한이 없다.
3. 모든 DA 결과를 수신한 뒤 종합 리포트를 작성한다.
4. 유효한 지적만 선별하여 계획에 반영한다.
   - 기각하는 지적에는 반드시 근거를 명시한다.
5. 반영 후 동일 8개 DA를 **새 에이전트로** 재실행한다 (fresh perspective 보장).
6. 8개 DA 전부 CLEAR를 반환할 때까지 반복한다.

### for_pr 모드

1. `git diff`로 변경사항을 수집한다 (staged + unstaged).
2. 8개 영역별 DA 에이전트를 **한 턴에 동시 병렬 실행**한다.
   - 각 에이전트에게 diff + 프로젝트 컨텍스트를 제공한다.
   - 에이전트는 읽기 전용이며 수정 권한이 없다.
3. 모든 DA 결과를 수신한 뒤 종합 리포트를 작성한다.
4. 유효한 지적만 선별하여 코드에 반영하고 커밋한다.
   - 기각하는 지적에는 반드시 근거를 명시한다.
5. 반영 후 동일 8개 DA를 **새 에이전트로** 재실행한다 (fresh perspective 보장).
6. 8개 DA 전부 CLEAR를 반환할 때까지 반복한다.
7. 최종 승인 후 push한다.

### both 모드

1. **for_plan 절차** 전체를 수행한다.
2. 사용자의 계획 승인을 받은 뒤 구현을 진행한다.
3. 구현 완료 후 1차 커밋을 생성한다.
4. **for_pr 절차** 전체를 수행한다.
5. 최종 커밋 후 push하고 PR을 생성한다.

## 피드백 프로토콜

핵심 원칙 요약:

- **PoC 의무화**: DA가 위반을 지적하면 구체적 파일:줄 또는 계획 항목 번호를 제시해야 한다.
  증거 없는 추상적 우려는 기각한다.
- **기각 시 근거 제시**: "사용자 지시"만으로 DA 지적을 기각하지 않는다.
  기술적 근거를 반드시 명시한다.
- **Fresh perspective 보장**: 매 라운드마다 새 에이전트를 사용한다.
  이전 라운드의 판단에 편향되지 않도록 한다.
- **무한 루프 방지**: 3회 연속 동일 지적이 반복되면 사용자 결정에 위임한다.
- **탈출 조건**: 8개 DA 모두 CLEAR를 반환하면 루프를 종료한다.

상세 프로토콜은 [references/protocol.md](references/protocol.md) 참조.

## 주의사항

- 매 라운드 새 에이전트를 사용한다 (이전 라운드 결과에 의한 확증 편향 방지).
- DA 에이전트는 읽기 전용이다. 코드나 계획을 직접 수정하지 않는다.
- "사용자 지시"만으로 DA 지적을 기각하지 않는다. 기술적 근거가 필수이다.
- DA 결과에서 다른 영역을 침범한 지적은 해당 영역의 DA 결과로 이관하거나 무시한다.
- 피드백 루프 결과는 PR 코멘트로 게시하여 이력을 보존한다.

## 참조 자료

- **[references/da-domains.md](references/da-domains.md)** -- 8개 DA 영역별 상세 정의, 프롬프트 템플릿, 출력 형식
- **[references/protocol.md](references/protocol.md)** -- 피드백 수용/기각 판단 기준, PoC 의무화 규칙, 무한 루프 방지, DA_ROUND_LOG 페이로드, PR 코멘트 형식
