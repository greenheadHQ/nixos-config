---
modules:
  - principles
  - planning
  - verification
  - commit
---

# 리팩토링

> 대상: 동작 불변 구조 개선

```text
기능 동작은 바꾸지 않고 구조만 개선해.
계획 단계에서 동작 동일성 검증 방법(테스트/스모크/비교 기준)을 먼저 정의해.

{DA_TOOL}로 구현 후 DA를 수행해. 모델은 반드시 {DA_MODEL_2}를 명시하고, 각 지적에 반증 예제를 포함하게 해.
유효한 항목만 반영해 후속 커밋해.
```

```vars
DA_TOOL|코드 실행 도구|codex exec,claude agent|codex exec
DA_MODEL_2|DA 모델|gpt-5.4,claude-opus-4-6|gpt-5.4
```
