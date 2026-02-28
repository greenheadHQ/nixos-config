# 기능개발 (라이트)

> 포함 요소: 원칙 + 계획 + 검증 + DA(light, post-impl) + 커밋
> 대상: 중소규모 기능
> 플레이스홀더
> - `{DA_TOOL}`: `codex exec` 또는 `claude agent`
> - `{DA_MODEL_2}`: 예) `gpt-5.3-codex` (필수)

```text
YAGNI/NGMI를 제1원칙으로 삼고, 최소 변경으로 구현해.

상세 계획을 세우고 불명확점은 질문으로 해소해.

구현 후 핵심 동작을 실제 실행으로 검증하고 1차 커밋해.

그 다음 {DA_TOOL}로 구현 후 DA를 1회 수행해. 모델은 반드시 {DA_MODEL_2}를 명시해.
DA 피드백은 사용자 지시라는 이유로 기각하지 말고, 실행 근거 중심으로 선별 반영해.
```

```vars
DA_TOOL|코드 실행 도구|codex exec,claude agent|codex exec
DA_MODEL_2|DA 모델|gpt-5.3-codex,claude-opus-4-6|gpt-5.3-codex
```
