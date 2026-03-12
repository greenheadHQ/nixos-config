---
modules:
  - principles
  - planning
  - da-feedback
  - verification
  - commit
  - pr
---

# 기능개발 (풀)

> 대상: 대규모 기능 개발, 아키텍처 변경
> 버전: feature-dev-full@v2.0

```text
[1차 DA — 계획 단계]
{DA_TOOL}로 DA를 수행해. 모델은 {DA_MODEL_1}을 명시해.

[구현 → 검증 → 1차 커밋 → PR]
1차 커밋 직후 바로 push + PR 생성(2차 DA를 기다리지 말 것).

[2차 DA — PR 열린 상태]
{DA_TOOL}로 2차 DA를 수행해. 모델은 반드시 {DA_MODEL_2}로 명시.
각 라운드 종료 시 prompt version/model/리스크 증감을 기록해.
DA와 CodeRabbit 피드백은 병렬로 처리하고, 유효한 항목만 후속 커밋으로 반영.
```

```vars
DA_TOOL|코드 실행 도구|codex exec,claude agent|codex exec
DA_MODEL_1|1차 DA 모델|gpt-5.4,claude-opus-4-6|gpt-5.4
DA_MODEL_2|2차 DA 모델|gpt-5.4,claude-opus-4-6|claude-opus-4-6
DA_INTENSITY|DA 강도|light,standard,strict|strict
DA_TIMING|DA 시점|both|both
```
