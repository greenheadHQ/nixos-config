# Fresh 리뷰와 기각 이력

이 문서는 fresh prompt·suppression 조립뿐 아니라 `NOT_AN_ISSUE` 또는 사용자 제외 이력을 기록하기 전에도 적용한다.

### `fresh` modifier

모드 뒤에 `fresh`를 추가하면 (예: `for_pr fresh`) DA 에이전트에게 이전 라운드의 맥락을 전달하지 않는다.

| 구분 | 기본 동작 | `fresh` 동작 |
|------|----------|-------------|
| DA 프롬프트 | 이전 라운드 결과 요약 포함 가능 | 코드/계획 + 프로젝트 컨텍스트만 전달. 이전 라운드 언급 금지 |
| 편향 | 이전 발견에 anchoring 가능 | 매 라운드 완전 독립 리뷰 |
| 무한 루프 위험 | 낮음 (이전 맥락으로 중복 감소) | 높음 (동일 지적 반복 가능 → 메인 에이전트의 세션 내 반복 감지로 대응) |

`fresh` 사용 시 메인 에이전트는 DA 에이전트 프롬프트에 다음을 포함하지 않는다:
- 이전 라운드의 발견 사항
- 이전 라운드에서 수용/기각된 지적 내역
- "이번에는 다른 관점에서 봐주세요" 등 이전 라운드를 암시하는 표현

세션 내 기각 이력 (본 절이 정본): 메인 에이전트는 현재 세션·현재 changeset 범위에서 Arbiter `NOT_AN_ISSUE` 판정과 사용자 명시 제외 항목의 기각 이력을 자기 컨텍스트에 유지한다.

- 공통 필수 필드: 세부 관점, 위치(파일:줄 또는 계획 항목 번호), finding 요약. 기각 근거는 출처별 variant로 기록한다:
  - Arbiter 기각: `verdict: NOT_AN_ISSUE` + `rejection_basis` + (Plausibility 기각이면) `evidence_scope` + 기술적 반증 근거.
  - 사용자 제외: `dismissal: USER_EXCLUDED` + 사용자가 승인한 기술적 근거. verdict·rejection_basis는 요구하지 않는다 — Arbiter를 거치지 않은 제외에 판정 필드를 합성하지 않는다. 별도 범위 필드는 없다 — 이 이력의 적용 경계는 항상 현재 세션·현재 changeset이다 (위 공통 경계).
- suppression key: 세부 관점 + 위치 + 요약이 모두 일치할 때만 동일 지적으로 suppress한다. 관점·위치가 같아도 다른 failure mode면 새 finding으로 Arbiter에 보낸다. 주의 — 3회 반복·한계효용·신규 finding 계산이 쓰는 recurrence key(세부 관점 + 위치, [`references/protocol.md`](protocol.md))와 의도적으로 다르다: suppression은 다른 failure mode까지 억제하지 않도록 좁게, 반복 감지는 같은 위치의 재공격을 묶어 잡도록 넓게 잡는다.
- 무효화: changeset이 바뀌면(계획 수정, write phase 커밋 등) 이전 기각 이력은 새 changeset의 suppress 근거가 되지 않는다. Plausibility 기각 중 `evidence_scope: ENVIRONMENT_WORKLOAD`(환경·워크로드 가정 의존)는 같은 changeset이라도 라운드 간 suppress하지 않고 다시 판정한다 — `FROZEN_SURFACE`만 동일 changeset 내 suppress eligible이다.
- 적용 주체·시점: `fresh` 반복 라운드에서 메인 에이전트가 reviewer 결과 수집 후 Arbiter 입력 전에 suppression key exact match 항목만 제외한다 (main-agent-only).
- reviewer 비주입: 이 이력은 reviewer 프롬프트에 주입하지 않는다. anti-anchoring이 목적이므로 이전 finding 본문·Arbiter reasoning·transcript는 어떤 형태로도 전달하지 않는다.
- 세션을 넘는 영속 저장소는 두지 않는다 (실측상 세션 간 재제기는 관측되지 않았고, 관측된 재제기는 전부 동일 세션 내 라운드 간이다).
