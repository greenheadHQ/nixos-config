# Fan-out / Fan-in (for_issue, for_action Step 3.5)

`for_issue` 레퍼런스 수집과 `for_action`의 Step 3.5 외부 자문 양쪽이 사용하는 codex exec 병렬 호출 카탈로그.

## 역할 카탈로그

fan-out 에이전트에 할당할 수 있는 역할:

| 역할 | 설명 | 모델 권장 |
|------|------|----------|
| 코드베이스 분석 | 관련 파일/모듈/패턴 탐색 | Sonnet |
| 이슈/PR 검색 | 기존 이슈, closed PR, 중복 확인 | Sonnet |
| 커밋 이력 분석 | 관련 커밋, blame, 변경 맥락 | Sonnet |
| 웹 리서치 | 외부 문서, 라이브러리, 패턴 조사 | Sonnet |
| 의존성/사이드이펙트 | 변경의 영향 범위, 의존 관계 분석 | Sonnet |
| 기술 자문 (Step 3.5) | 옵션별 anchoring-neutral 평가 매트릭스 | codex exec high reasoning |

LLM이 작업의 복잡도/도메인에 따라 에이전트 수(2-6개)와 역할을 동적으로 결정한다.
DA/review 에이전트는 run-da canonical contract의 프로파일을 따른다 (reviewer/Intensity는 standard, Arbiter는 strong).

## 런타임 분기

codex exec fan-out 패턴은 [`/codex-fan-out` 스킬](../../codex-fan-out/SKILL.md)이 단일 소스다.

- **Claude Code 세션**: codex exec 기본. 사전점검(`command -v codex >/dev/null && codex --version >/dev/null 2>&1`) 실패 시 Agent tool fallback (`run_in_background: true`).
- **headless 세션**: codex exec only.
- **Codex 세션**: native subagent fan-out (기존).

codex exec 실행 시 각 에이전트 프롬프트에 "파일을 수정하지 마라" no-write boundary를 명시한다.

**Codex 세션 fan-out delegation 거부 처리**: Codex 세션에서 `spawn_agent`가 정책상 거부되면 [run-da SKILL.md "Delegation fallback (정책 요약)"](../../run-da/SKILL.md#delegation-fallback-정책-요약)을 그대로 적용한다 (BLOCKED + 사용자 승인 대기 → 승인 시 codex exec subprocess fallback, no-write boundary 동일). 명칭과 정책은 run-da SSOT를 따르며 본문에 별도 신설하지 않는다.

## fan-in 통합 전략

에이전트 결과를 카테고리별로 분류하여 통합한다:
1. **코드 패턴**: 코드베이스에서 발견한 관련 패턴, 기존 구현
2. **관련 이슈/PR**: 중복, 선행 작업, 참고 이슈
3. **외부 레퍼런스**: 웹 리서치 결과, 문서, 패턴
4. **사이드이펙트**: 변경이 다른 모듈/기능에 미치는 영향
5. **기술 자문 매트릭스 (Step 3.5)**: 옵션별 evaluation matrix + disqualifier

중복을 제거하고, 모순이 있으면 명시하여 스무고개 질문에 포함한다.
