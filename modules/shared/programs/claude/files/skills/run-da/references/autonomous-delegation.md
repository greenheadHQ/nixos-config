# 호출 보고와 자율주행 위임

설정 값의 타입·부재 기본값은 [execution-options.md](execution-options.md)가 소유한다. 이 문서는 `for_plan`/`for_pr`의 검토 강도 하향·사용자 판단 gate 처리 또는 fan-out 전에 위임 유무와 관계없이 읽는다. 설정 파일 없이 자연어로 위임한 경우에도 연장한도 계산에 필요한 부재 기본값은 execution-options.md의 "장기 선호 설정 파일" 절에서 확인한다.

### 호출 시점 보고 규약 (종료 조건·예상 비용 — 본 절이 단독 소유)

reviewer fan-out 발사 전에 다음을 한 문단으로 사용자에게 보고한다 (질문이 아니라 보고 — 진행을 막지 않는다):

- 종료 조건 요약: 수렴 predicate 2층([`references/protocol.md`](protocol.md) SSOT)의 한 줄 요약 + outer round 상한(값은 protocol.md 정본)과 이번 호출의 위임 연장 한도.
- 예상 비용: 이번 라운드의 실행 단위 수 × 역할별 effort (예: reviewer 4 × high + Arbiter 1 × xhigh), 반영 발생 시 재검증 라운드가 추가될 수 있다는 사실.

### 자율주행 위임 계약 (#1260 — 본 절이 단독 소유)

사용자가 무인 진행을 사전 위임하는 계약이다. 선언 채널은 두 가지 — 현재 발화의 자연어 선언(예: "자러 간다, 알아서 완주해") 또는 설정 파일 `[delegation] autonomous = true`. 채널 간 우선순위는 프로파일 resolution과 동일하게 현재 발화가 파일을 이긴다: 현재 발화의 명시적 위임 거부(예: "이번엔 위임 없이 물어보면서 진행해")는 파일의 `autonomous = true`보다 우선해 이 호출을 위임 없음으로 확정하고, 현재 발화에 위임 관련 선언이 없으면 파일 값(부재 시 기본값 `false`)을 따른다. 위임이 없으면 모든 gate는 각 정본의 질문 절차를 따른다.

장시간 판정과 1회 질문: FULL fan-out 기준 2 outer round 이상이 예상되는 호출인데 위임 선언이 없으면, 발사 전에 질문 도구로 위임 여부를 1회 묻는다 (이후 반복 질문 금지 — 응답이 이 호출의 위임 상태를 확정한다).

gate별 전이표 (gate의 상세 절차는 각 정본이 소유 — 본 표는 위임 유무 축만 소유한다). 이 표에 등록되지 않은 질문 gate의 위임 시 기본 동작은 자동 진행 금지 — 해당 지점에서 중단하고 상태를 보고한다 (새 gate가 정본에 생겨도 위임 전이가 미정 상태로 자동 진행되지 않게 하는 fail-closed 기본값):

| gate | 위임 없음 | 위임 있음 |
|------|-----------|-----------|
| SKIP 제안 승인 | 질문 도구 | 자동 LITE 승격 (SKIP 확정은 사용자 전용 — headless 규칙과 동일) |
| 3회 반복 판정 | 질문 도구 (수용/제외/배출) | 자동 수용 (지적대로 수정) — 단 보류 판정에는 적용 금지 (아래 gate 우선순위) |
| 라운드 한계효용 저하 | 질문 도구 | 현재 상태 보고 후 종료 (headless 규칙과 동일 — 자동 수정 계속 금지) |
| outer round 기본 상한 도달 (유효 상한 정의는 protocol.md "최대 라운드 수") | 질문 도구 (계속/종료) | `max_round_extensions`까지 자동 연장 후, 소진(유효 상한) 시 비수렴 종료 라벨로 종료 |
| fresh 반복 감지 | 질문 도구 | 자동 fresh 재실행 1회, 재발 시 종료 보고 |
| `remediation_scope` UNCLEAR | 질문 도구 (수정/배출/제외) | 미해결로 계산 (자동 수정 간주 금지 — headless 규칙과 동일) |
| NEEDS_MORE_INFO | 질문 도구 | CONFIRMED 자동 승격 (headless 규칙과 동일 — scope 전이표 적용) |
| LOW confidence 승격 | 질문 도구 | 확정·기각 계열 모두 미해결로 계산 — protocol `unresolved_count`에 "위임 상태의 미판단 LOW confidence verdict"로 편입되어 수렴을 차단한다 (fail-closed 승격 순서 유지)·기각 이력에 기록하지 않음. 종료 후 일괄 보고에 사용자 판단 대기 항목으로 명시 |
| 검증기 capability 불일치 (배포 시차) | 질문 도구 (배포 후 재시도/검증 생략 승인) | 위임으로 대체 불가 — 검증 생략 없이 중단 보고 (검증 없는 진행은 사전 위임 범위 밖) |
| 수렴 종료 후 push 최종 승인 | 질문 도구·승인 게이트 (for_pr Step 8 정본) | 자동 push (CONVERGED·DEFERRED_EXIT에 한함 — 비수렴 종료 push 금지는 아래 행) |
| codex exec 사전점검 실패 fallback | 원인 고지 + 질문 | 진행 불가 보고 후 해당 경로 종료 (자동 대체 금지 유지) |
| native effort 설정 수단 부재 | 질문 도구 (Arbiter-only 전환 승인) | 위임으로 대체 불가 — 전환하지 않고 중단 보고 (hardening 경계) |
| delegation-denied subprocess fallback | 질문 도구 (승인) | 위임으로 대체 불가 — 중단 보고 (hardening 경계) |
| 비수렴 종료(상한·중단) 후 push | 사용자 위임 보고 | push하지 않고 미해결 상태 보고 (기존 계약 유지) |

gate 우선순위 (한 finding에 여러 gate가 동시에 성립할 때): ①semantic malformed 처리 → ②LOW confidence·UNCLEAR 보류 (미해결 계산 — 이 상태의 finding은 3회 반복 자동 수용 대상이 아니다) → ③3회 반복 자동 수용. 보류 판정을 반복 횟수로 자동 수정하면 fail-closed 승격 계약이 우회된다 — recurrence key(세부 관점+위치)는 요약을 포함하지 않는 넓은 키라 서로 다른 실패 양상이 한 반복으로 묶일 수 있어, 보류 상태에서는 반복 자동화보다 사용자 판단 대기가 우선한다.

위임 제외 범위 (위임이 있어도 자동화하지 않는다): ①BLOCKED(malformed 재실행 후 잔존 — 자동 승격 금지 유지), ②hardening 계약의 subprocess fallback 승인(구조적 write 경계는 사전 위임으로 대체할 수 없다), ③마스킹 게이트를 통과하지 못하는 공개 배출(SECURITY disclosure-safe 불가 포함 — 위임과 무관하게 미해결), ④상한 연장의 무제한 반복(`max_round_extensions` 소진 후에는 종료).

종료 후 일괄 보고 필드: 위임 실행이 끝나면 라운드별 발견→확정→반영 수, 배출 이슈 번호, 자동 전이가 발동한 gate 목록(각 항목에 한 줄 사유), 종료 라벨, 미해결 항목을 한 번에 보고한다.
