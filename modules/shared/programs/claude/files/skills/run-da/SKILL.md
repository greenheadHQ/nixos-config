---
name: run-da
argument-hint: "[for_plan|for_pr|both] [full] [fresh]"
description: |
  Run Devil's Advocate review on plans or code. Args: for_plan, for_pr, both. Modifier: full, fresh.
  Trigger: 'DA', '피드백 루프', 'YAGNI 리뷰', '코드 리뷰 루프', 'run-da',
  'HALLUCINATION 관점에서 코드 검증', '설계 검토', '코드 품질 리뷰', '간단한 변경 DA 필요 여부', 'DA 필요', 'DA 생략'.
  Also trigger when the user asks whether a simple change can skip DA; this skill owns the SKIP/LITE/FULL decision path.
  NOT for PR/AI review-comment HALLUCINATION classification (use review-pr-feedback). NOT for PR 코멘트 (use review-pr-feedback). NOT for 전수조사 (use parallel-audit). NOT for DA session log/statistics/verdict 분포 정량 분석 (use analyzing-da-sessions, 사용자 명시 호출 전용).
---

# Devil's Advocate 피드백 루프

기본 경로는 4개 reviewer bundle을 변경 규모에 맞게 병렬 실행하여 계획/코드를 엄격 리뷰한다.
명시적 exhaustive override가 필요할 때만 `run-da ... full`로 8개 세부 도메인까지 확장한다.

주의: Review Intensity 판단은 메인 LLM의 인라인 체크리스트다 (자유 추론 금지)

Review Intensity 판단은 메인 LLM이 [`references/intensity-rules.md`](references/intensity-rules.md)의 룰 표를 기계적 체크리스트로 적용한다.
"이건 단순한 변경이니 DA를 건너뛰어도 된다"는 자유 추론은 금지다.
직접 `/run-da` 호출에서는 호출을 생략하지 마라 — run-da를 호출한 뒤 메인 LLM은 모든 룰을 평가한 표를 plan/대화에 남긴 뒤 first-match 룰의 단계를 채택해 SKIP/LITE/FULL을 결정한다.
예외적으로, 문서화된 자동 호출자는 동일 체크리스트를 호출 직전에 재사용할 수 있다. 이 경우에도 룰 표 복제나 자유 추론은 금지이며, SKIP은 질문 도구 승인 없이는 완료 상태가 아니다.
체크리스트 표가 없거나 fail-closed rule group(보안/모듈/설정·의존성 — 자세한 ID는 `intensity-rules.md`)이 하나라도 매치/불확실이면 강한 검토(FULL)로 fail-closed.
합리화 방지 상세는 [`references/intensity-procedure.md`](references/intensity-procedure.md)와 [`references/protocol.md`](references/protocol.md) 참조.

## 모드

| `$ARGUMENTS` | 동작 |
|--------------|------|
| `for_plan` | 계획 단계 DA 1회 — 계획 파일 또는 대화 컨텍스트 대상 ([`modes/for_plan.md`](modes/for_plan.md)) |
| `for_pr` | 구현 후 코드 DA 1회 — git diff 대상 ([`modes/for_pr.md`](modes/for_pr.md)) |
| `both` | for_plan 전체 → 사용자의 계획 승인 → 구현 → 1차 커밋 → for_pr 전체 → 최종 커밋 후 push + PR 생성. 각 단계의 실행 강도는 Review Intensity에 따라 독립적으로 결정 |
| *(비어있음)* | 사용자에게 모드 선택을 질문한다 |

### `full` modifier

모드 뒤에 `full`을 추가하면 (예: `for_pr full`, `both full fresh`)
Review Intensity 판단을 건너뛰고 exhaustive override를 실행한다.

| 구분 | 기본 동작 | `full` 동작 |
|------|----------|------------|
| 경중 판단 | 자동 수행 (SKIP/LITE/FULL) | 건너뜀 → exhaustive FULL 강제 |
| fan-out | 판단 결과에 따라 0 / 선택 bundle / 4 reviewer bundles | 항상 8개 세부 도메인 |
| 사용 시점 | 일반 | 사용자 명시적 exhaustive 요청, recall 민감도가 높은 변경, 예외적 고위험 diff |

자동 판정의 FULL도 여전히 강한 기본 검토다. 차이는 fan-out뿐이다:
- 자동 `FULL` = `Correctness`, `Design`, `Regression`, `Maintainability` 4 bundle
- `full` modifier = 위 bundle을 8개 세부 도메인으로 확장한 exhaustive override

### `fresh` modifier

모드 뒤에 `fresh`를 추가하면 (예: `for_pr fresh`, `both fresh`) DA 에이전트에게 이전 라운드의 맥락을 전달하지 않는다.

| 구분 | 기본 동작 | `fresh` 동작 |
|------|----------|-------------|
| DA 프롬프트 | 이전 라운드 결과 요약 포함 가능 | 코드/계획 + 프로젝트 컨텍스트만 전달. 이전 라운드 언급 금지 |
| 편향 | 이전 발견에 anchoring 가능 | 매 라운드 완전 독립 리뷰 |
| 무한 루프 위험 | 낮음 (이전 맥락으로 중복 감소) | 높음 (동일 지적 반복 가능 → 반복 감지 규칙으로 대응) |

`fresh` 사용 시 메인 에이전트는 DA 에이전트 프롬프트에 다음을 포함하지 않는다:
- 이전 라운드의 발견 사항
- 이전 라운드에서 수용/기각된 지적 내역
- "이번에는 다른 관점에서 봐주세요" 등 이전 라운드를 암시하는 표현

메인 에이전트는 finding의 세부 관점 + 위치(파일:줄 또는 계획 항목 번호) 조합으로 라운드 간 반복 감지를 수행한다.

## 빠른 참조

| 항목 | 위치 |
|------|------|
| Mode for_plan 절차 | [`modes/for_plan.md`](modes/for_plan.md) |
| Mode for_pr 절차 (for_plan delta) | [`modes/for_pr.md`](modes/for_pr.md) |
| 런타임 도구 매핑 + codex exec 위생 + fallback 세부 정보 | [`references/runtime-mapping.md`](references/runtime-mapping.md) |
| literal 재사용 환각 주의 (issue #632) | [`../using-codex-exec/references/known-issues.md`](../using-codex-exec/references/known-issues.md#literal-재사용-시-random-suffix-환각-금지-issue-632) |
| Codex 세션 하드닝 계약 (single-writer / 역할별 경계 / VIOLATION / Delegation fallback) | [`references/hardening-contract.md`](references/hardening-contract.md) |
| Review Intensity 인라인 체크리스트 절차 (메인 LLM 기계적 적용 + fail-closed) | [`references/intensity-procedure.md`](references/intensity-procedure.md) |
| Review Intensity 판단 알고리즘 규칙 (룰 표 + 안정적 ID + fail-closed group) | [`references/intensity-rules.md`](references/intensity-rules.md) |
| 메인 에이전트 의무 (행동 + 사용자 질문 맥락 + 검증) | [`references/main-agent-obligations.md`](references/main-agent-obligations.md) |
| DA reviewer bundle 상세 + 프롬프트 템플릿 | [`references/da-domains.md`](references/da-domains.md) |
| DA → Arbiter 상태 흐름 + 합리화 방지 + PR 코멘트 형식 | [`references/protocol.md`](references/protocol.md) |
| Arbiter 프롬프트 + 5가지 판정 기준 | [`references/arbiter-prompt.md`](references/arbiter-prompt.md) |
| Arbiter 스케일링 + 실행 계약 (+ Review Intensity 인라인 체크리스트 실행 계약) | [`references/arbiter-scaling.md`](references/arbiter-scaling.md) |
| Selective consistency 정책 (vote-shape + offline kappa) | [`references/stability-measurement.md`](references/stability-measurement.md) |
| Validation-path catalog | [`references/validation-paths.md`](references/validation-paths.md) |

## 용어 정책

이 스킬은 Claude Code 세션과 Codex 세션 양쪽에서 호출된다. 본문은 도구-중립 용어를 쓰고, 런타임별 실제 도구는 [`references/runtime-mapping.md`](references/runtime-mapping.md)에서 binding한다.

| 용어 유형 | 처리 |
|----------|------|
| 섹션명 / 정책명 | keep (정책 이름으로 기능. 역사적 이유로 legacy 정책명 참조가 남아 있을 수 있다) |
| 사용자 질문 실행 지시 | "질문 도구" (Claude Code 전용 도구명을 본문에서 literal로 쓰지 않는다) |
| 파일 읽기 지시 | "파일 읽기 도구" (런타임 도구 매핑 표의 "파일 읽기" 행에 binding) |
| 병렬 실행 지시 | "병렬 실행" 또는 "fan-out 실행" (런타임 도구 매핑 표의 "fan-out 실행" 행에 binding) |

## DA reviewer bundles

| reviewer bundle | 포함 세부 도메인 | 집중 관점 | 심각도 기준 |
|-----------------|------------------|----------|-----------|
| Correctness | HALLUCINATION + SECURITY | 존재하지 않는 가정, 안전하지 않은 경계, 검증 누락 | 실행 즉시 실패 또는 공격 표면 확대 |
| Design | YAGNI + NGMI | 과설계, 막다른 구조, 요구 변경 시 붕괴할 추상화 | 구조적 재작업 필요 |
| Regression | SIDE_EFFECT + CONSISTENCY | 기존 동작 파괴, 인접 기능 파급, 프로젝트 패턴 드리프트 | 기존 계약/관례 훼손 |
| Maintainability | READABILITY + CLEAN_CODE | 이해 난이도, 중복, 매직값, 죽은 코드 | 유지보수 비용 증가 |

기본 FULL path는 위 4개 reviewer bundle을 사용한다. 각 finding은 bundle 이름 아래에서
세부 관점(`HALLUCINATION`, `SECURITY` 등)을 함께 표기한다.

명시적 exhaustive override(`run-da ... full`)는 위 bundle을 다음 8개 세부 도메인으로 확장한다:
`YAGNI`, `NGMI`, `HALLUCINATION`, `SECURITY`, `SIDE_EFFECT`, `CONSISTENCY`, `READABILITY`, `CLEAN_CODE`.

상세 프롬프트 템플릿과 출력 형식은 [`references/da-domains.md`](references/da-domains.md) 참조.

## 핵심 invariants

본 스킬 호출 시 반드시 적용되는 행동 규칙. 상세는 [`references/main-agent-obligations.md`](references/main-agent-obligations.md) SSOT 참조.

1. Review Intensity는 메인 LLM 인라인 체크리스트다 — 메인 LLM이 모든 룰을 평가한 표를 기록하고 first-match로 단계를 채택한다. 자유 추론 금지. fail-closed rule group(보안/모듈/설정·의존성) 매치/불확실 시 강한 검토 fail-closed ([`references/intensity-procedure.md`](references/intensity-procedure.md)).
2. Single-writer / main-agent-only — tracked workspace write, branch mutation, commit/push, GitHub write, `wt`/`nrs`/rebuild 계열은 메인 에이전트 소유. DA reviewer/Arbiter는 위임 금지 ([`references/hardening-contract.md`](references/hardening-contract.md) 역할별 경계). Review Intensity 인라인 판정은 메인 에이전트의 정상 경로다.
3. Conservative wait — `wait_agent` timeout이나 단순 지연만으로 reviewer/Arbiter를 kill하지 않는다. explicit failure signal, documented violation, 최종 응답 파싱 실패가 없는 한 self-auditing으로 대체하지 않는다. (Review Intensity는 인라인 체크리스트라 wait 대상 아님.)
4. PoC 의무화 — DA가 위반을 지적하면 구체적 파일:줄 또는 계획 항목 번호를 제시. 증거 없는 추상적 우려는 Arbiter가 NOT_AN_ISSUE로 판정한다.
5. CONFIRMED_ISSUE 자동 반영 — Arbiter가 CONFIRMED_ISSUE로 판정한 항목은 자동 반영. CRITICAL 심각도는 진행 차단.
6. 사용자 전건 보고 + 질문 도구 의무 — 모든 Arbiter 판정 결과를 사용자에게 보고. NEEDS_MORE_INFO/`split` 항목은 [`references/main-agent-obligations.md`](references/main-agent-obligations.md#사용자-질문-시-맥락-설명-의무)의 5요소 맥락(현재 상황 / 문제 / 비유법 / 선택지 장단점 / 질문)으로 질문 도구 호출.
7. Fresh perspective 보장 — 매 라운드마다 새 reviewer/Arbiter 실행 단위 (Codex: 새 native subagent thread, codex exec: 새 `codex exec` 프로세스).

## 주의사항

- 매 라운드 새 reviewer/Arbiter 실행 단위를 사용한다.
- Codex 세션 경로에서는 completed reviewer/Arbiter thread를 다음 round/retry 전에 명시적으로 `close_agent`로 닫는다. 닫지 않으면 open-thread slot이 회수되지 않는다.
- Codex 세션 경로의 reviewer/auditor는 standard review profile, Arbiter는 strong review profile을 사용한다 ([`references/runtime-mapping.md`](references/runtime-mapping.md) review profile 매핑). Review Intensity는 별도 process가 아니라 메인 LLM 인라인 체크리스트.
- codex exec 경로의 DA `codex exec` 프로세스는 `codex-exec-supervised --sandbox read-only --ignore-user-config --ignore-rules --ephemeral` (Layer 1)로 실행되어 코드/계획 write를 read-only sandbox로 구조적으로 차단한다. `--ignore-rules`는 user/project execpolicy `.rules`의 network/system mutation allow rule(예: `git push`)도 차단한다. 프롬프트에서도 수정 금지를 명시한다.
- "사용자 지시"만으로 DA 지적을 기각하지 않는다. 기술적 근거가 필수이다.
- DA 결과에서 다른 bundle 범위를 침범한 지적은 해당 bundle의 DA 결과로 이관하거나 무시한다.
- 피드백 루프 결과는 PR 코멘트로 게시하여 이력을 보존한다 ([`references/protocol.md`](references/protocol.md) 참조).

## Non-goals

이 스킬이 구조적으로 보장하지 않는 경계. 수용 가능한 근사로 운영하되, 구조적 enforcement는 별도 follow-up 범위다.

1. `spawn_agent` per-child read-only sandbox 부재: Codex `spawn_agent` API는 자식 에이전트에 read-only sandbox를 구조적으로 강제할 수 없다 (codex-cli 0.124.0 기준 `--ignore-user-config`, `--ephemeral`, `--sandbox` 전역 옵션만 존재, per-child flag 없음). reviewer/Arbiter의 "읽기 전용" 경계는 프롬프트 지시 + 사후 diff 점검으로만 운영한다. 자식이 구조적으로 write를 못 하게 막지는 않는다. (Review Intensity는 spawn 대상이 아니므로 본 한계가 적용되지 않는다.)

   연관 한계 (project config MCP 차단 불가): `--ignore-user-config`는 `$CODEX_HOME/config.toml` 로드만 차단하고, **cwd 기반 project config (`.codex/config.toml`의 `[mcp_servers.*]`)는 차단하지 않는다**. 이 리포는 `.codex/config.toml`에 project-scoped MCP connector를 정의하므로, Delegation fallback subprocess가 repo root에서 실행되면 project-scoped MCP connector surface가 reviewer/Arbiter에게 남을 수 있다. 완전 차단이 필요하면 `codex exec -C <non-repo-scratch-dir>`로 cwd를 project config 없는 디렉토리로 이동시키는 별도 Non-goal 범위 follow-up이 필요하다.
2. push / PR / comment 작성은 네트워크·auth 정책 의존: `for_pr` 마지막 단계 `push`, `both` 마지막 단계 `push + PR 생성`, PR 코멘트 게시 형식은 네트워크 가능 환경 + GitHub auth 전제. `sandbox_mode=danger-full-access` 또는 GitHub 커넥터 경로에서만 자동 실행한다. 다른 샌드박스 모드에서는 해당 단계를 명시적 사용자 승인 후 수행하거나, 메인 에이전트가 사용자에게 위임한다.
3. zsh 고정 가정 (headless 포함): codex exec 경로의 `_DA_SID` 해시 계산, cleanup glob `*(N)` qualifier, heredoc 문법 등은 zsh 전제다. bash/sh 환경에서는 `*(N)`이 문법 오류가 난다. headless 세션도 zsh 환경에서의 실행을 지원 범위로 둔다 — bash/sh headless는 현재 지원 범위 밖이다 (POSIX-safe helper 도입 전까지). POSIX-safe 변형은 별도 follow-up (예: guardrail 스킬에서 shell 전제 lint).
4. `/tmp` 쓰기 권한은 sandbox 정책 의존: `danger-full-access` · `workspace-write` 모드에서는 `mktemp -d /tmp/...`가 정상 동작한다. 더 제한적인 sandbox에서는 실패할 수 있다. 필요 시 `mktemp -d "${TMPDIR:-/tmp}/..."`로 대체하거나 repo 내부 임시 디렉토리로 우회한다 (follow-up).
