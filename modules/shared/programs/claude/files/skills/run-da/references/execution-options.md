# 실행 지정과 장기 선호

## 실행 경로·파라미터 지정 (자연어 채널)

사용자는 실행 경로(codex exec / Claude Code 서브에이전트)와 실행 파라미터 — model·service_tier(codex exec 경로 전용), reasoning effort(codex exec와, 설정 수단이 광고된 native spawn에서 지원) — 를 호출 단위로 자연어로 지정할 수 있다 (예: "전부 codex xhigh로", "reviewer를 이 모델로, fast tier로 돌려줘", "Claude 서브에이전트로 돌려"). 메인 LLM이 사용자가 명시한 값을 경로/model/effort/tier 축으로 해석한다.

| 규칙 | 내용 |
|------|------|
| 해석 (환각 금지) | 사용자가 명시한 축만 채운다. 명시가 없는 축을 추론으로 채우지 않는다 — 그 축은 기본 정책을 따른다. 지정 표현이 어느 축·어느 값인지 불명확하면 질문 도구로 확인한다 |
| 적용 범위 | 해당 호출의 reviewer/auditor와 Arbiter 전체. 자연어 지정은 해당 호출에만 적용된다 — 호출을 넘는 장기 선호는 아래 "장기 선호 설정 파일" 절이 소유한다 |
| effort 지정 | 경로만 함께 지정된 경우의 role별 기본값보다 사용자 명시 effort가 우선한다 (더 구체적인 지정 우선) |
| 값 유효성 | 스킬은 값 집합을 예단하지 않는다 — 값 집합은 codex/모델이 소유한다. shell-safe 검증(구체 규칙과 실행 주체는 [arbiter-scaling.md](arbiter-scaling.md)의 role command guard)만 통과하면 그대로 주입하고, codex/API가 거부하면 그 에러를 사용자에게 그대로 보고한다. 값 거부는 재실행으로 해소되지 않으므로 자동 재시도하지 않는다. 조용한 대체/하향 금지. 단 `service_tier`는 Codex가 거부하지 않고 경고 후 생략한 채 rc 0으로 성공하는 축이므로(using-codex-exec 실측), rc 검사만으로는 무시를 감지할 수 없다 — tier가 주입된 실행의 성공 후 stderr 경고 검사는 [`references/arbiter-scaling.md`](arbiter-scaling.md) "사용자 지정 실행 파라미터"가 소유한다 |
| Arbiter 하한 | 전체 지정이 reviewer 강도를 낮춰도 Arbiter는 강도 하한(strong profile) 아래로 내려가지 않는다 — 하한·고지·예외(사용자가 Arbiter 축을 콕 집어 지정)는 [`references/arbiter-scaling.md`](arbiter-scaling.md)의 "Arbiter 추론 강도 하한"이 SSOT |
| 경로 지정 | codex exec 경로 지정 시 사전점검이 실패하면 다른 경로로 자동 대체하지 않고, 실패 원인과 대안(Claude 경로 진행 또는 중단)을 사용자에게 고지한 뒤 확인을 받는다. Claude 서브에이전트 경로 지정 시 현재 런타임에서 사용할 수 없으면 동일하게 고지한다. 모델은 Claude 경로에서는 세션 모델을 상속하며 특정 모델명을 고정하지 않는다 |
| 경로 제약 | model/tier 주입은 codex exec 경로 전용이고, effort는 codex exec와 설정 수단이 광고된 native spawn에서 지원된다. Claude 경로와 model/tier를 함께 지정하면 모순이므로 질문 도구로 확인한다. Codex 세션 native subagent 경로에는 model/tier 주입 수단이 없으므로, 지정 시 codex exec 경로로의 전환 여부를 사용자에게 확인한다. native 경로의 effort는 세션 표면에 광고된 spawn 단위 설정 수단이 있을 때만 반영 가능하다 — 설정 수단 부재 시의 전이는 [`references/arbiter-scaling.md`](arbiter-scaling.md)의 "Arbiter 추론 강도 하한" 절이 정본이다 |

모델명 박제 금지 원칙과의 관계: 이 채널의 값은 사용자 입력에서만 온다. 스킬 문서·기본값·예시에 특정 모델명을 두지 않는 원칙(sync 테스트의 모델 literal 잔존 게이트)은 그대로 유지된다.

실행 계약(env 변수, shell-safe 검증, 주입 위치)은 [`references/arbiter-scaling.md`](arbiter-scaling.md)의 "사용자 지정 실행 파라미터" 섹션이 SSOT다. 미지정 시 역할별 기본값·축 구조·resolution 순서는 [`references/runtime-mapping.md`](runtime-mapping.md)의 "실행 프로파일" 절이 SSOT다.

## 장기 선호 설정 파일 (#1260 — 본 절이 정본)

매 호출 자연어 지정을 반복하지 않도록, 장기 선호는 스킬 밖 설정 파일 `~/.config/run-da/preferences.toml`에 둔다 (Nix 선언 관리 밖 가변 파일 — 선호는 시간에 따라 역전된 실측이 있어 스킬 기본값으로 고정하지 않는다). 메인 에이전트는 호출 진입 시 이 파일을 읽는다 — 파일·키 부재는 기본값 적용이며 오류가 아니다. 부재 시 기본값의 소유: `[profile]` 축은 runtime-mapping.md 실행 프로파일 표의 기본값이고, `[delegation]` 축은 본 절이 소유한다 — `autonomous` 부재 = `false`(위임 없음), `max_round_extensions` 부재 = `2`. 값 검증: `autonomous`는 TOML boolean `true`만 위임 선언으로 인정한다 — 그 외 값·타입은 부재와 동일하게 위임 없음으로 처리하고(fail-closed — 잘못된 값이 무인 진행을 활성화하지 않는다) 사용자에게 보고한다. `max_round_extensions`는 0 이상의 정수만 유효하며, 그 외 값은 부재 기본값을 적용하고 보고한다 — 유효하지 않은 값을 유효 상한 계산에 쓰지 않는다. 기계 파서는 두지 않는다 (문서 계약).

아래 블록은 사용자 설정 예시다 (기본값 명세가 아니다 — 예시 값은 부재 시 기본값과 다를 수 있다):

```toml
[profile]
# 각 키는 실행 프로파일의 한 축에 대응한다 (runtime-mapping.md "실행 프로파일" 정본).
# 값 집합은 스킬이 예단하지 않는다 — shell-safe 검증만 통과하면 그대로 주입.
backend = "codex-exec"        # 실행 backend 선호 — 지원 경로 중 선택하는 제어값 (codex-exec | native | claude). 미지·불명확 값은 주입하지 않고 질문
reviewer_effort = "high"      # reviewer/auditor effort — shell-safe 검증 후 그대로 주입 (값 집합은 codex/모델 소유)
arbiter_effort = "xhigh"      # Arbiter effort — 주입 규칙은 effort와 동일, 하한 미만 값은 하한이 이긴다 (아래 참조)
service_tier = ""             # 빈 값 = 미지정. 잘못된 값은 오류가 아니라 조용한 생략이 되므로 runner가 stderr 경고를 검사해 보고한다 — 위 "값 유효성"의 tier 분기 참조

[delegation]
autonomous = false            # true = 자율주행 사전 위임 ([자율주행 위임 계약](autonomous-delegation.md))
max_round_extensions = 2      # 위임 시 상한 자동 연장 허용 횟수. 연장 한 번 = outer round 한 개 추가 (유효 상한 정의는 protocol.md "최대 라운드 수" 정본)
```

우선순위는 resolution 순서(runtime-mapping.md 정본)를 따른다 — 현재 발화의 자연어 지정이 파일보다 우선하고, 파일 값은 role 기본값보다 우선한다. 파일 값의 provenance는 "사용자 명시"로 취급한다 (`RUN_DA_USER_EFFORT_OVERRIDE` 등 명시 표식 규칙 동일 적용) — 단 Arbiter 하한의 "명시 축 예외"는 현재 발화의 축 지정에만 적용되고 파일 값에는 적용되지 않는다 (파일은 장기 기본값이지 이번 호출의 의도적 하향이 아니다). 같은 원리로 `backend` 설정 값은 희망 경로의 선택일 뿐 실행 권한 승인을 대체하지 않는다 — Direct Codex 세션의 subprocess 경로 승인 경계([`references/hardening-contract.md`](hardening-contract.md))는 설정 파일과 무관하게 유지된다.
