# Prompt System (모듈 + 프리셋)

이 디렉터리는 LLM 작업 지시문을 `재사용 모듈`과 `실전 프리셋`으로 분리해 관리한다.

## 배경

- AS-IS 참고 소스: `local PROMPTS.md` (기존 단일 프롬프트 문서)
- 목표: 중복 문구를 줄이고, 상황별로 조합 가능한 프롬프트 체계 제공

## 구조

```text
scripts/prompts/
├── modules/
│   ├── principles.md
│   ├── planning.md
│   ├── da-feedback.md
│   ├── verification.md
│   ├── commit.md
│   └── pr.md
└── presets/
    ├── feature-dev-full.md
    ├── feature-dev-light.md
    ├── bugfix.md
    ├── refactoring.md
    ├── code-review.md
    ├── exploration.md
    ├── domain-unfamiliar.md
    ├── tech-learning.md
    └── pr-feedback.md
```

## CLI 사용법

`prompt-render` 명령으로 preset의 코드 블록을 추출하고 placeholder를 치환한 뒤 clipboard에 복사한다.

```bash
# 예시 1 — 순수 대화형
prompt-render --preset feature-dev-full
# DA_TOOL: codex exec ↵
# DA_MODEL_1: gpt-5.3-codex ↵
# DA_MODEL_2: gpt-5.3-codex ↵

# 예시 2 — --var 혼합
prompt-render --preset feature-dev-full --var DA_TOOL="codex exec" --var DA_MODEL_1=gpt-5.3-codex
# DA_MODEL_2: gpt-5.3-codex ↵  (나머지만 대화형)

# 예시 3 — --non-interactive 실패
prompt-render --preset feature-dev-full --var DA_TOOL="codex exec" --non-interactive
# Error: missing variables: DA_MODEL_1, DA_MODEL_2
# exit code: 2
```

`cheat-browse --prompts`로 fzf preset 브라우저를 열고, Enter로 선택하면 대화형 렌더가 실행된다.

> 범위 제외: GUI/에디터 통합, 원격 동기화는 본 시스템 범위 외

## 핵심 운영 정책

1. DA 피드백을 `사용자 지시`만으로 기각하지 않는다.
2. DA는 정적 코드리뷰만 하지 않고 핵심 동작을 실행 검증한다.
3. DA 피드백에는 계획 가설을 반증하는 코드/재현 예제를 포함한다.
4. 2차 DA는 모델명을 반드시 명시한다.
5. PR 생성은 2차 DA 완료를 기다리지 않고 먼저 수행한다.

## 권장 흐름 (feature-dev-full)

1. 계획 수립 + 1차 DA(plan)
2. 구현 + 테스트 + 1차 커밋
3. 즉시 push + PR 생성
4. PR이 열린 상태에서 2차 DA(post-impl)와 CodeRabbit 피드백을 병렬 처리
5. 후속 커밋을 PR에 추가 push

## 모델 정책

- 기본 권장: `gpt-5.3-codex`
- 2차 DA 실행 시 `-m <모델>` 생략 금지

## 버전 관리 규칙

- 프리셋 버전 태그: `preset-name@vX.Y` (예: `feature-dev-full@v1.0`)
- 변경 로그 최소 항목:
  - 변경 전 버전 / 변경 후 버전
  - 변경 이유
  - 기대 효과
  - 회귀 위험
- 변수 스키마는 프리셋 상단에 명시:
  - 모델 변수: `{DA_MODEL_1}`, `{DA_MODEL_2}`
  - 도구 변수: `{DA_TOOL}`
  - DA 제어: `{DA_INTENSITY}`, `{DA_TIMING}`
  - 도메인 변수: `{LEARN_TARGET}`, `{FAMILIAR_TECH}`, `{TARGET}`

## 참고 레퍼런스

- OpenAI Prompting Best Practices: https://help.openai.com/en/articles/6654000-best-practices-for-prompting
- OpenAI Prompting Guide: https://developers.openai.com/api/docs/guides/prompting
- OpenAI Evaluation Best Practices: https://developers.openai.com/api/docs/guides/evaluation-best-practices
- Anthropic Be Clear and Direct: https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/be-clear-and-direct
- Anthropic Eval Tool: https://docs.anthropic.com/en/docs/test-and-evaluate/eval-tool
