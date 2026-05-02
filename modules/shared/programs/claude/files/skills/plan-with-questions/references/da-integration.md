# DA Integration (Step 5 호출 + Step 6 결과 반영)

`for_action` 모드 Step 5/6의 `/run-da for_plan` 호출 계약과 결과 반영 상태표.

## Step 5: DA for_plan 실행 [일반 모드]

`for_action` 모드에서 모든 사용자 질문이 해소되면 계획 추적 도구 진입 전에 `/run-da for_plan`을 실행한다.

- **무조건 호출**: for_action 모드에서 DA 호출 여부를 메인 LLM이 판단하지 않는다. Review Intensity 판단은 run-da 내부의 독립 에이전트가 수행하므로, 이 단계를 건너뛸 이유가 없다.
- **런타임 분기는 run-da를 따른다**: 3-way 분기 — Codex 세션에서는 native subagent, Claude Code 세션에서는 codex exec(사전점검 후 불가 시 Agent tool fallback), headless 세션에서는 codex exec.
- **기본 경로는 lean default**: `/run-da for_plan`의 자동 FULL은 4 reviewer bundle 기본 리뷰다. 8개 세부 도메인 exhaustive path는 명시적 `full` modifier가 있을 때만 쓴다.
- **YAGNI 예외 근거**: DA 호출 자체는 YAGNI 판단 대상이 아니다. 변경이 "단순"해 보여도 독립 에이전트가 SKIP으로 판단하면 사용자 승인을 거쳐 자동 생략된다. 메인 LLM은 호출만 하면 된다.
- **책임 분리**: Review Intensity 판단은 run-da의 책임이다. 메인 LLM은 DA 호출 여부를 스스로 판단하지 않는다.
- **thread cap 준수**: Codex 세션에서는 current session의 open-thread cap(`agents.max_threads`, unset 기본 6)을 넘기지 않고, completed reviewer/Arbiter thread를 다음 round/retry 전에 `close_agent`로 닫아야 한다.
- **Codex 세션 hardening 계약 준수**: `/run-da for_plan`의 reviewer/Intensity는 standard review profile, Arbiter는 strong review profile을 따른다. `wait_agent` timeout만으로 중간 kill/self-auditing 대체를 하지 않고, reviewer PoC는 repo 밖 scratch에 한정한다.
- **main-agent-only 유지**: single-writer/main-agent-only boundary는 `run-da` canonical contract를 그대로 따른다. tracked write, branch mutation, commit/push, GitHub write, `wt`/`nrs`/rebuild 계열은 for_plan subagent가 직접 실행하지 않는다. 상세 용어와 violation 처리 규칙은 [run-da/references/hardening-contract.md](../../run-da/references/hardening-contract.md) `Codex 세션 하드닝 계약`을 따른다.
- **타이밍**: 반드시 계획 추적 도구 진입 전에 이 단계를 완료한다 (DA 에이전트가 일반 모드에서 full tool access로 PoC 검증을 수행할 수 있도록).

## Step 6: DA 결과 반영 [일반 모드]

DA for_plan의 Arbiter 판정 결과와 selective consistency 집계(해당 시)를 함께 처리한다. 상세 상태 전이는 [`run-da/references/protocol.md`](../../run-da/references/protocol.md)의 "DA → Arbiter → Main Agent 상태 흐름" 및 "Selective consistency 상태 전이" 참조.

| verdict × stability_status | 메인 에이전트 행동 |
|----------------------------|-------------------|
| CONFIRMED_ISSUE (stability=`N/A` 또는 `stable`, `low_confidence_warning=false`) | 계획에 자동 반영한다. |
| NOT_AN_ISSUE (stability=`N/A` 또는 `stable`, `low_confidence_warning=false`) | 반영 불필요 (Arbiter 판정을 신뢰한다). |
| NEEDS_MORE_INFO (stability=`N/A` 또는 `stable`) | 질문 도구로 사용자 판단을 요청한다. |
| 임의 verdict + `stability_status=stable` + `low_confidence_warning=true` | fail-closed 승격: 질문 도구로 사용자 판단 요청 (unanimous이어도 low-confidence 이력 공유). |
| majority verdict + `stability_status=split` | 질문 도구로 사용자 판단 요청. vote-shape(2:1)와 minority verdict도 함께 제시. |
| `stability_status=fragmented` 또는 partial_failure | BLOCKED. 질문 도구 지원 시 사용자 판단 요청(비유법 포함), 미지원 시 자동 승격 금지하고 중단 보고. |

DA 결과 반영 후 plan 파일의 `Decision Log`에 ADR 미니 형식으로 중요 변경을 기록한다 (상세는 [`plan-file-template.md`](./plan-file-template.md) Decision Log 섹션).
