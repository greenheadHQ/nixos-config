# DA Harness Research And Improvement Design

## Goal

`run-da`, `parallel-audit`, `plan-with-questions`를 중심으로 구성된 현재 LLM 감사 하네스를 전수조사하고, 그 결과를 바탕으로:

1. 현재 구조가 어떻게 형성되었는지 설명 가능한 수준으로 복원하고
2. 실제 토큰/비용 낭비 지점을 정량/정성으로 식별하고
3. 근거 기반 개선안을 도출하며
4. 다음 LLM이 즉시 구현에 착수할 수 있는 All-in-One handoff까지 작성한다.

이번 사이클은 리서치 전용이다. 코드 수정은 수행하지 않는다.

## Fixed Decisions

- 기본 조사 전략: `증거 우선형`
- 전환 조건: 로컬 세션 로그 모수가 부족하면 `공격적 감축형`으로 전환
- 최적화 1순위: `토큰/비용 최소화`
- 로그 범위: 이 Mac의 `Claude Code + Codex + 기타 관련 흔적` 전체
- 최종 산출물: `Research Dossier + Improvement Proposal + All-in-One LLM Handoff`

## Why This Strategy

단순히 `run-da 8개 reviewer를 4개로 줄이자`로 끝내면, 현재 구조가 왜 8개로 진화했는지, 어떤 안전장치를 유지해야 하는지, 어떤 reviewer만 줄여도 되는지를 설명할 수 없다.

따라서 이번 리서치는 아래 3개 증거축을 독립적으로 수집한 뒤 공통 결론만 채택한다.

1. 로컬 로그 축
2. 코드/PR/CIR/ADR 히스토리 축
3. 외부 논문/공식 엔지니어링 레퍼런스 축

## Current Baseline Facts

현재까지 확인된 사실:

- 관련 스킬 본문과 레퍼런스는 `modules/shared/programs/claude/files/skills/` 아래에 존재한다.
- 최근 구조 진화 타임라인의 핵심 커밋은 다음 순서로 보인다.
  - `2c4476d` `run-da`를 `codex exec` 기반 병렬 실행 엔진으로 전환
  - `cb7046c` background Bash tool 기반 병렬 실행으로 조정
  - `c992d23` Review Intensity 도입
  - `455ac54` Arbiter 레이어 도입
  - `55ffaf6` Review Intensity를 독립 에이전트 판정으로 전환
  - `16b45d9` for_plan Arbiter 오탐 완화
  - `eb460ed` zsh/bash 예시 안정화
- PR 타임라인도 위 커밋 흐름과 일치한다.
  - PR #342, #350, #364, #379, #382, #390, #393
- 로컬 로그 모수는 현재 전환 기준을 넘는다.
  - 관련 본세션 24개
  - `run-da` 포함 세션 24개
  - `parallel-audit` 포함 세션 22개
  - `plan-with-questions` 포함 세션 19개
  - `run-da + parallel-audit` 동시 사용 세션 22개
  - 세 스킬 모두 포함 세션 19개
  - 관련 subagent JSONL 132개
  - 토큰 메타데이터 포함 subagent JSONL 132개
- 따라서 현재로서는 `공격적 감축형`으로 강제 전환할 필요가 없다. 다만 실제 중복률 계산 결과가 매우 불안정하면 일부 결론은 `추정`으로 표시한다.

## Research Questions

이번 리서치는 다음 질문에 답해야 한다.

1. 현재 하네스는 어떤 단계와 의사결정으로 지금 구조에 도달했는가?
2. `run-da`와 `parallel-audit`에서 실제 토큰 낭비는 어디서 발생하는가?
3. reviewer/감사 에이전트 간 finding 중복은 실제로 얼마나 자주 발생하는가?
4. 어떤 구조가 비용 절감에 가장 직접적으로 기여하는가?
5. 어떤 안전장치는 유지해야 하며, 어떤 계층은 축소 또는 제거 가능한가?
6. 다음 LLM이 즉시 구현에 들어가려면 어떤 작업 단위와 검증 절차가 필요한가?

## Scope

### In Scope

- `run-da`
- `parallel-audit`
- `plan-with-questions`
- 이들을 호출/보조하는 레퍼런스 파일
- `using-codex-exec`와 관련 실행 제약
- 로컬 `Claude Code`/`Codex` 세션 로그 및 아카이브
- 관련 PR, issue, design spec, CIR/ADR 흔적
- 외부 multi-agent review / debate / judge / eval 레퍼런스

### Out Of Scope

- 이번 사이클에서의 실제 코드 수정
- unrelated skill 전체 품질 개선
- 현재 하네스를 대체하는 완전 신규 프레임워크 구현
- 비용 외 최적화만을 위한 대규모 재설계

## Evidence Sources

### Local Runtime Evidence

- `~/.claude/skill-usage.log`
- `~/.claude/projects/**/<session>.jsonl`
- `~/.claude/projects/**/subagents/*.jsonl`
- `~/.claude/archive/**`
- `~/.claude/history.jsonl`
- `~/.codex/sessions/**`
- `~/.codex/archived_sessions/**`
- `~/.codex/history.jsonl`
- `~/.codex/logs_1.sqlite`

### Code And Design Evidence

- `modules/shared/programs/claude/files/skills/run-da/**`
- `modules/shared/programs/claude/files/skills/parallel-audit/**`
- `modules/shared/programs/claude/files/skills/plan-with-questions/**`
- `modules/shared/programs/claude/files/skills/using-codex-exec/**`
- `docs/superpowers/specs/**`
- git commit history
- GitHub PR/issue history

### External Evidence

우선순위는 아래와 같다.

1. 공식 엔지니어링 문서
2. 논문/학술 preprint
3. 평가 가이드/공식 docs
4. 고품질 실무 글

마케팅성 글, 레퍼런스 없는 블로그, 2차 요약글은 보조 참고로만 사용한다.

## Sufficiency Gate For Local Logs

로컬 로그를 정량 근거로 채택하려면 아래 기준을 통과해야 한다.

- `run-da` 실제 세션 10개 이상
- `parallel-audit` 실제 세션 8개 이상
- reviewer/subagent 출력 50개 이상
- 같은 라운드 내 reviewer 중복 비교 가능 세션 5개 이상

기준 미달 시:

- 로컬 로그는 정성 근거로만 사용
- 최종 개선안은 `공격적 감축형`으로 이동
- 재현율 손실 가능성을 리스크로 명시

현재 baseline은 기준을 통과한다.

## Research Workflow

### Workstream 1: Session Inventory

목표:

- 관련 세션 전체 목록 확보
- 하네스 호출 패턴 복원
- 세션별 사용 조합 식별

방법:

- `skill-usage.log`로 1차 후보 세션 추출
- 세션 JSONL과 아카이브에서 실제 본문 존재 여부 확인
- `subagents/*.jsonl`와 parent session 연결

산출:

- 세션 인벤토리 테이블
- 세션별 스킬 조합 테이블
- reviewer/arbiter/intensity 존재 여부 플래그

### Workstream 2: Duplicate And Cost Analysis

목표:

- reviewer 간 finding 중복과 토큰 낭비를 계량

정규화 키:

- `domain + normalized location`

location 정규화 규칙:

- 코드 리뷰: `file:line`
- 계획 리뷰: `plan step`
- 위치 누락 finding은 별도 bucket으로 분리

핵심 지표:

- total reviewer count
- total findings
- unique findings
- duplicate findings ratio
- repeated findings across rounds
- token per unique finding
- token per confirmed issue
- arbiter-rejected duplicate share
- domain overlap matrix

보조 지표:

- wall-clock time
- round count
- NEEDS_MORE_INFO 비율
- CLEAR 도달까지의 누적 토큰

### Workstream 3: Architecture Archaeology

목표:

- 현재 구조가 왜 생겼는지 commit/PR/issue/doc 기준으로 설명

대상:

- PR #342, #350, #364, #368, #379, #382, #390, #393
- 관련 issue/설계 문서
- `docs/superpowers/specs/*`

산출:

- commit/PR 타임라인
- 각 구조 변화의 배경 문제
- 유지해야 할 설계 의도 vs 제거 가능한 역사적 잔재

### Workstream 4: External Pattern Extraction

목표:

- 외부 레퍼런스에서 비용 절감에 유효한 패턴만 추출

현재 유력 패턴:

- reviewer 수보다 reviewer 다양성이 중요
- 모든 reviewer에게 모든 critique를 broadcast하면 redundancy가 커짐
- 잘 정의된 단일 judge가 다수 judge보다 일관적일 수 있음
- reviewer 증식보다 selective escalation이 효율적임
- 평가지표는 finding count보다 `unique signal` 중심이어야 함

산출:

- source table
- 패턴별 지지 근거
- 현재 하네스와의 매핑표

## Improvement Proposal Generation Rules

개선안은 아래 기준을 통과한 것만 채택한다.

### Rule 1: Cost Reduction Must Be Structurally Explainable

`왜 줄여도 되는지` 설명할 수 없는 감축안은 채택하지 않는다.

예:

- finding overlap가 높다
- reviewer 역할 차이가 약하다
- 동일 diff를 동일 수준의 프롬프트로 반복 공급한다
- arbiter가 어차피 중복 critique를 다시 압축한다

### Rule 2: Evidence Strength

최우선 채택 조건:

- 로컬 증거와 외부 근거가 동시에 지지

차선 채택 조건:

- 둘 중 하나가 매우 강하고 반대 근거가 없음

### Rule 3: Immediate Implementability

이번 handoff는 다음 LLM이 바로 구현해야 하므로, 개선안은 구체적 파일 단위로 분해 가능해야 한다.

우선 후보 예시:

- `run-da` reviewer/domain 수 재설계
- `parallel-audit` default agent count 재설계
- reviewer 역할 차별화 강화
- finding selective propagation
- arbiter 단순화
- 프롬프트 공통부 축소

### Rule 4: Verification Clarity

각 권장 변경에는 최소 1개의 검증 지표가 붙어야 한다.

예:

- total tokens 감소
- duplicate ratio 감소
- token per unique finding 감소
- unique findings 유지
- wall-clock 감소

### Rule 5: Handoff Readiness

최종 권장안은 다음 요소를 모두 포함해야 한다.

- 수정 파일
- 변경 규칙
- 작업 순서
- 검증 명령
- 로그 재계측 절차
- 금지사항
- 완료 정의

## Expected Improvement Areas

현재 시점에서 유력한 조사 대상은 다음과 같다.

1. `run-da` 8개 reviewer/domain 구조의 축소 또는 통합
2. `parallel-audit` 기본 10개 에이전트 재설계
3. reviewer 간 finding broadcast 정책 제거 또는 selective화
4. 단일 강한 arbiter 중심 구조 재평가
5. 프롬프트 공통부/중복 컨텍스트 축소
6. Review Intensity가 reviewer 수를 더 강하게 줄이도록 재설계
7. 평가 지표를 `finding 수` 중심에서 `unique signal` 중심으로 이동

위 항목은 아직 최종 결론이 아니라 조사 우선순위이다.

## Final Deliverable Contract

최종 문서는 하나의 파일 안에 아래 3개 파트가 이어지는 구조로 작성한다.

### Part A: Research Dossier

필수 항목:

- 현재 하네스 구조 요약
- 로그 모수와 신뢰성 판정
- 중복/낭비 분석 결과
- commit/PR/CIR/ADR 타임라인
- 외부 레퍼런스 테이블
- 핵심 결론

### Part B: Improvement Proposal

개선안은 아래 등급으로 분류한다.

- `P0`: 토큰 절감 효과가 크고 위험이 낮은 변경
- `P1`: 유력하지만 추가 검증이 필요한 변경
- `P2`: 장기 아이디어

각 개선안 형식:

- 문제
- 근거
- 권장 변경
- 대안
- 트레이드오프
- 예상 비용 절감
- 재현율 리스크

### Part C: All-in-One LLM Handoff

다음 LLM이 추가 해석 없이 구현에 들어갈 수 있도록 아래를 포함한다.

- 수정 대상 파일 목록
- 파일별 변경 규칙
- 권장 작업 순서
- 실행/검증 명령
- 로그 재계측 방법
- 금지사항
- 완료 정의

## Acceptance Criteria

다음 조건을 모두 만족해야 이번 리서치를 완료로 본다.

1. 다음 LLM이 문서 하나만 읽고 구현에 착수할 수 있어야 한다.
2. 각 권장 변경에는 최소 1개 이상의 근거가 있어야 한다.
3. 비용 절감 주장에는 가능한 한 정량 근거가 붙어야 한다.
4. 정량 근거가 약한 항목은 `추정`으로 명시해야 한다.
5. 로컬 로그, 코드 히스토리, 외부 레퍼런스 3축이 모두 문서에 반영되어야 한다.

## Risks And Mitigations

### Risk: Log Parsing Is Messy

대응:

- `skill-usage.log`를 1차 인덱스로 사용
- JSONL 본세션과 subagent 파일을 교차 검증
- 복원 실패한 세션은 제외하고 제외 근거 기록

### Risk: Duplicate Detection Over-Merges

대응:

- 1차 기준은 `domain + location`
- 텍스트 유사도는 보조 지표로만 사용
- location 없는 finding은 별도 취급

### Risk: Aggressive Cost Cutting Hurts Recall

대응:

- P0 개선안에도 재현율 리스크를 명시
- 가능하면 `unique findings` 유지 조건을 acceptance에 포함

### Risk: Historical Intent Is Misread

대응:

- commit message, PR body, spec, issue를 함께 읽는다
- 문서화되지 않은 추론은 `추론`으로 표시한다

## Outbound Handoff Constraints

다음 구현 LLM에게는 아래 제약을 건다.

- 연구를 다시 처음부터 반복하지 말 것
- Part C의 작업 순서를 우선 따를 것
- P0부터 착수할 것
- 검증 없이 “완료”를 주장하지 말 것
- 로그 재계측 결과가 기존 baseline보다 나빠지면 중단하고 보고할 것

## Recommended Next Step After This Design

이 디자인 승인 후 바로 수행할 일:

1. 실제 리서치 수행
2. 결과를 같은 문서 구조에 맞춰 정리
3. All-in-One handoff 작성
4. 사용자가 검토 후 구현 단계로 넘김
