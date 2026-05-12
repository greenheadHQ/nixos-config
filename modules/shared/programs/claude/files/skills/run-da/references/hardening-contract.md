# Codex 세션 하드닝 계약

이 섹션은 Codex 세션 경로에서만 적용된다.
codex exec 경로(Claude Code 세션 · headless 세션)는 [`arbiter-scaling.md`](arbiter-scaling.md)의 subprocess 계약을 따른다.
여러 규칙이 충돌하면 더 엄격한 역할 제한이 generic PoC 허용보다 우선한다.

이 파일은 `run-da` canonical contract의 SSOT다. 다른 스킬(`parallel-audit`, `plan-with-questions`, `codex-fan-out` 등)이 single-writer / main-agent-only / 역할별 경계 / VIOLATION 처리 / Delegation fallback을 참조할 때 본 파일이 정본이다.

## 용어와 우선순위

| 용어 | 뜻 | 우선순위 |
|------|-----|---------|
| strong review profile | Arbiter spawn의 강한 리뷰 설정 (model/effort literal은 [`runtime-mapping.md`](runtime-mapping.md)의 review profile 매핑 불릿이 단일 소스) | Arbiter spawn 기본값 |
| standard review profile | reviewer/auditor spawn의 기본 리뷰 설정 ([`runtime-mapping.md`](runtime-mapping.md) review profile 매핑 불릿이 단일 소스) | DA spawn 기본값 |
| conservative wait | `wait_agent` timeout이나 단순 지연은 실패 신호가 아니다. 명시적 agent failure, documented violation, 최종 응답 파싱 실패 전에는 kill/self-auditing 대체를 금지한다. 검토 강도 인라인 판정에는 적용되지 않는다 (메인 에이전트의 동기 체크리스트). | 조급한 조기 종료보다 우선 |
| single-writer | tracked workspace write, 최종 파일 수정, branch mutation, commit/push, GitHub comment/issue/PR write는 메인 에이전트 소유다. explicit delegation만 예외다 | generic PoC 허용보다 우선 |
| main-agent-only commands | `wt`, `nrs`, rebuild 계열과 host/repo 상태를 바꾸는 동급 명령은 direct fan-out subagent가 실행하지 않는다 | lock-sensitive convenience보다 우선 |
| recoverable violation | 출력 형식 위반, bundle scope 침범, prompt contract 미준수처럼 workspace/branch/host 외부 상태를 바꾸지 않은 위반 | 결과 discard 후 fresh rerun |
| stateful violation | tracked write, branch mutation, commit/push, GitHub write, main-agent-only command 실행, host mutation처럼 상태를 바꾼 위반 | 즉시 중단 + offending-unit 산출물만 정리, `BLOCKED`, CLEAR 불가 |

## 역할별 경계

| 역할 | 허용 | 금지 |
|------|------|------|
| DA reviewer | 읽기, 검색, out-of-repo private scratch PoC (`mktemp -d`, `umask 077`) | tracked write, branch mutation, commit/push, GitHub write, `wt`/`nrs`/rebuild 계열 |
| Arbiter | 읽기 전용 검증 | 모든 write, scratch PoC, main-agent-only command |
| Auditor (`parallel-audit`) | 읽기 전용 검증 | 모든 write, scratch PoC, main-agent-only command |
| 메인 에이전트 | tracked write, external write, main-agent-only command, explicit delegation, Review Intensity 인라인 판정 (모든 룰 평가 표 + first-match 채택) | Arbiter 판정 대체, DA reviewer finding 직접 판정 |

Review Intensity 예외: 검토 강도 판정(SKIP/LITE/FULL)은 메인 에이전트가 [`intensity-rules.md`](intensity-rules.md)의 룰 표를 기계적 체크리스트로 적용하는 인라인 판정이다. Arbiter의 DA finding 판정 대체 금지는 그대로 유지한다. 인라인 판정 절차의 fail-closed 규칙(fail-closed rule group 매치/불확실, 룰 ID + 근거 미명시, 비신뢰 입력 인젝션 발견 시 강한 검토 강제)은 [`intensity-procedure.md`](intensity-procedure.md)가 SSOT다.

## Skill-internal fan-out authorization

Direct Codex 세션에서 사용자가 `$plan-with-questions`, `$run-da`, `$parallel-audit`처럼 fan-out 실행을 문서화한 스킬을 호출하면, 그 호출은 해당 스킬이 선언한 role/work scope 안에서 내부 native subagent fan-out을 수행하라는 explicit delegation으로 간주한다.

이 권한은 delegated reviewer/auditor/Arbiter의 read-only/no-write 경계를 약화하지 않는다. tracked workspace write, branch mutation, commit/push, GitHub write, `wt`, `nrs`, rebuild 계열 명령은 별도 explicit delegation 없이는 계속 메인 에이전트 전용이다. (Review Intensity는 메인 LLM 인라인 체크리스트라 본 권한 매트릭스의 별도 항목이 아니다.)

이 권한은 native subagent 경로에만 적용된다. Skill invocation itself does not authorize `codex-exec-supervised` fallback. `codex-exec-supervised` fallback은 아래 Delegation fallback 절차에 따라 native delegation 거부/미지원 사유 기록과 별도 사용자 승인을 받은 뒤에만 사용한다.

## `VIOLATION` 공통 처리

- `RECOVERABLE`: offending unit 결과만 폐기하고 fresh rerun한다. rerun 전까지 `CLEAR` 계산에 포함하지 않는다.
- `STATEFUL`: 현재 라운드를 즉시 중단한다. offending thread를 닫고, 이번 라운드에서 offending unit이 만든 scratch dir, 임시 ref/branch, 산출물만 정리한다.
- `STATEFUL` 경로에서도 기존 local tracked/untracked 변경은 자동 정리하지 않는다. 비가역적 외부 side effect가 있었거나 cleanup 범위를 특정할 수 없으면 해당 unit을 `BLOCKED`로 남기고 명시적 rerun 전까지 종료한다.

## Delegation fallback (정책 요약)

이 섹션은 direct Codex 세션에서 native `spawn_agent` delegation이 실제로 정책상 거부되거나 미지원일 때만 적용한다. 위 Skill-internal fan-out authorization은 native subagent 사용에 대한 explicit delegation이며, `codex-exec-supervised` fallback 승인을 뜻하지 않는다.

Codex 세션에서 `spawn_agent`가 정책상 거부되면(예: `multi_agent=false`, `"delegation not permitted"`·`"multi_agent disabled"` 에러) 메인 에이전트는 다음 정책을 따른다. subprocess 실행 계약(role별 명령, sandbox 플래그, stdin pipe, 실패 처리)의 SSOT는 [`arbiter-scaling.md`](arbiter-scaling.md)의 "Codex delegation-denied fallback" 섹션이다.

"같은 에이전트 컨텍스트 serial" 금지 — 메인 에이전트가 reviewer/Arbiter 프롬프트를 자기 컨텍스트에서 순차 실행하는 것은 위 "역할별 경계" 표의 메인 에이전트 금지 항목(`Arbiter 판정 대체`, `DA reviewer finding 직접 판정`)을 위반한다. fresh 독립 실행 단위를 유지해야 한다. Review Intensity는 본 금지의 예외다 — 검토 강도 판정은 메인 에이전트가 8 룰 체크리스트를 인라인으로 적용하는 것이 정상 경로이며, 별도 독립 process를 띄우지 않는다.

자동 우회 금지 — `spawn_agent` 거부는 정책 의사표시다. `codex exec --full-auto`(workspace-write)로 조용히 우회하면 reviewer/Arbiter의 no-write 경계가 구조적으로 보장되지 않는다. 자동 subprocess fallback을 허용하기 전에 사용자 승인을 얻고, 실행 시 read-only sandbox를 강제한다 (명령 상세는 위 SSOT). (Review Intensity는 spawn 대상이 아니므로 본 fallback 절차에 포함되지 않는다.)

1. BLOCKED + 사용자 승인 대기 (기본): `spawn_agent` 거부 감지 시 현재 DA 라운드 중단, 사용자에게 "delegation 거부 감지 — codex exec subprocess fallback 승인?"을 보고한다. 승인 수단은 런타임별로 다음과 같이 취한다:
   - 질문 도구 지원 런타임 (Claude Code 세션, Codex 세션): 질문 도구로 즉시 승인 요청. 승인 시 같은 턴에서 바로 fallback 단계 진행.
   - 질문 도구 미지원 런타임 (headless 세션 등): plain-text로 상황 보고 후 DA 루프 종료한다. 사용자는 새 메시지에서 "fallback 진행"으로 명시 승인하거나 `run-da <mode>`를 다시 실행하여 새 라운드로 재개한다 (이전 라운드 상태는 복원하지 않음, 깨끗한 fresh round로 시작). 명시 승인 없이 자동 재개하지 않는다.
2. codex exec subprocess fallback (사용자 승인 후에만): [`arbiter-scaling.md`](arbiter-scaling.md)의 "Codex delegation-denied fallback" 섹션이 정의한 role별 Layer 1 명령(standard profile = `model="gpt-5.5"`+medium, strong profile = `model="gpt-5.5"`+high)을 그대로 사용한다 — 실제 명령 literal과 플래그(`codex-exec-supervised --sandbox read-only --ignore-user-config --ignore-rules --ephemeral` + role별 model/effort pin)는 `arbiter-scaling.md`의 role별 명령 표가 SSOT다. user config의 MCP/plugin/connector surface 차단을 위해 `--ignore-user-config`가 필수이고, user/project execpolicy `.rules`의 mutation allow rule(예: `git push`) 차단을 위해 `--ignore-rules`가 필수다. cwd 기반 project config (`.codex/config.toml`)는 차단하지 못하므로 한계는 [`SKILL.md` Non-goals](../SKILL.md#non-goals) #1 참조. 각 unit은 독립 subprocess.

   Project-scoped MCP 차단 한계 (caveat — `--ignore-user-config`는 부분적 차단): `--ignore-user-config`는 `$CODEX_HOME/config.toml` 로드만 차단하고, **cwd 기반 project config (`.codex/config.toml`의 `[mcp_servers.*]`)는 차단하지 않는다**. 이 리포는 `.codex/config.toml`에 project-scoped MCP connector를 정의하므로, fallback subprocess가 repo root에서 실행되면 project-scoped MCP connector surface가 reviewer/Arbiter에게 남는다. 완전 차단이 필요하면 `codex exec -C <non-repo-scratch-dir>`로 cwd를 project config 없는 디렉토리로 이동시키는 별도 follow-up이 필요하다 (run-da [`SKILL.md` Non-goals](../SKILL.md#non-goals) 1번 항목과 동일 내용).

라운드 요약에는 경로와 sandbox 모드를 명시한다:

```text
Round N 요약: fan-out 경로 = codex exec subprocess serial fallback (--sandbox read-only, reason: delegation unavailable + user approved)
```
