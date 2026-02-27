# 기능개발 (풀)

> 포함 요소: 원칙 + 계획 + 검증 + DA(strict, both) + 커밋 + PR
> 대상: 대규모 기능 개발, 아키텍처 변경
> 버전: `feature-dev-full@v1.0`
> 플레이스홀더
> ⚠️ 사용 전 필수 — 반드시 `{DA_TOOL}`, `{DA_MODEL_1}`, `{DA_MODEL_2}`를 실제 값으로 치환
> - `{DA_TOOL}`: `codex exec` 또는 `agent`
> - `{DA_MODEL_1}`: 예) `gpt-5.3-codex`
> - `{DA_MODEL_2}`: 예) `gpt-5.3-codex` (필수)

```text
YAGNI/NGMI를 제1원칙으로 삼아. 오버엔지니어링은 금지하고 기존 코드와 통일성을 유지해.

상세 계획을 세우고, 불명확점/판단기준 부족/사이드이펙트 인지 여부를 질문으로 모두 해소해.
계획은 반드시 <goal>/<constraints>/<deliverables>/<validation>/<risks> 구조로 작성해.

[1차 DA - 계획 단계]
{DA_TOOL}로 DA 리뷰를 수행해. 모델은 {DA_MODEL_1}을 명시해.
DA는 사용자 지시만으로 기각하지 말고, 실행 가능 근거를 가진 위험만 지적하게 해.

구현 후 핵심 동작을 실제 실행으로 검증하고 결과를 남겨.
검증 완료 시 1차 커밋.

1차 커밋 직후 바로 push + PR 생성(2차 DA를 기다리지 말 것).

[2차 DA - PR 열린 상태에서 병렬]
{DA_TOOL}로 2차 DA를 수행해. 모델은 반드시 {DA_MODEL_2}로 명시.
DA는 각 지적마다 재현 명령, 실행 결과 요약, 계획 가설 반증 예제를 포함해야 해.
각 라운드 종료 시 prompt version/model/리스크 증감을 기록해.
DA와 CodeRabbit 피드백은 병렬로 처리하고, 유효한 항목만 후속 커밋으로 반영해 PR에 추가 push.
```
