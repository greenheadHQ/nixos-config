# [DA 피드백] 모듈

> Devil's Advocate 루프를 강도/시점/모델로 제어
> 플레이스홀더
> - `{강도}`: `light` / `standard` / `strict`
> - `{시점}`: `plan` / `post-impl` / `both`
> - `{DA도구}`: `codex exec` / `agent`
> - `{DA모델_1}`: 계획 단계 DA 모델 (권장 `gpt-5.3-codex`)
> - `{DA모델_2}`: 구현 후 DA 모델 (필수 명시)

```text
DA 피드백 루프를 수행해. {DA도구}를 사용하고 모델은 아래처럼 명시해.
- 1차 DA(plan): {DA모델_1}
- 2차 DA(post-impl): {DA모델_2}  # 반드시 명시, 생략 금지

강도: {강도}
- light: 1회
- standard: OK까지 반복(최대 3회)
- strict: OK까지 반복(상한 없음)

시점: {시점}
- plan: 계획 수립 직후
- post-impl: PR 생성 직후
- both: 둘 다 수행

중요 규칙:
1. "사용자가 그렇게 시켰다"는 이유만으로 DA 지적을 기각하지 마.
2. 보안/비밀노출/API key/plaintext credential/권한오남용/데이터 손실 지적은 최우선 검토해.
3. DA 지적을 기각하려면 코드 근거 또는 실행 근거를 제시해.
4. DA는 정적 리뷰만 하지 말고, 핵심 동작을 실제 실행해서 검증해.
5. 실행 불가하면 불가 사유, 대체 검증, 잔여 리스크를 함께 보고해.
6. 각 피드백에 계획 가설을 반증하는 코드/명령/입출력 예제를 포함해.
7. 라운드 종료 시 아래 구조화 payload를 반드시 남겨:
   {"DA_ROUND_LOG":{"prompt_version":"<version>","model":"<model_name>","risks_discovered":<count>,"risks_resolved":<count>}}

DA 출력 형식(항목별):
- 주장
- 근거 코드 위치
- 재현 명령
- 실제 실행 결과(요약)
- 반증 예제(가설 깨는 최소 예제)
- 권장 수정
- 심각도(critical/high/medium/low)
```
