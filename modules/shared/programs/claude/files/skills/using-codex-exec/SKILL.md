---
name: using-codex-exec
description: >-
  Run Codex CLI subprocesses for explicit codex exec requests, headless automation, and
  non-interactive code review. Use when requests mention `codex exec`/`비대화형 codex`, or before
  you launch, probe, or verify a codex exec subprocess yourself. Use using-claude-p for Claude
  headless execution.
---

# Codex Exec 사용

이 문서는 `codex exec` / `codex exec review` subprocess의 라우팅과 성공 계약을 다룬다.
상세 명령과 실행 계약은 아래 상황별 문서가 소유하며, 본문은 실행 경로 선택을 다룬다.
설정 키워드 검색으로 시작하지 말고 실행 경로 게이트부터 읽는다 — wrapper 계약이 통째로
우회된 세션이 다수였다.

## 실행 경로 게이트

| 실행 문맥 | 선택 경로 | 적용 조건 |
|----------|----------|----------|
| Direct Codex 세션의 review/audit/planning fan-out | native subagent | 기본 경로. nested `codex exec`를 선택하지 않는다. |
| Claude Code 세션·headless 자동화 | `codex-exec-supervised` (Layer 1) | stdin EOF 규약 + timeout budget 보장이 필요한 programmatic 호출. [known-issues.md §15](references/known-issues.md#15-codex-exec-supervised-wrapper로-14-위에-timeout-budget-한계-보강-issue-593) 참조. |
| 사용자가 literal raw 실행을 요청했거나 1회성 수동 진단 | raw `codex exec` | alias를 피하도록 `command codex` 또는 `env ... codex`로 호출한다. |

`run-da`는 스킬의 라우팅 계약이 우선한다. Direct Codex 세션에서
subprocess fallback이 필요하면 해당 스킬이 요구하는 별도 사용자 승인을 먼저 받는다.

## 작성 기준

- 확인 날짜: 2026-07-10
- 확인 버전: codex-cli 0.144.1
- 재검증: `command codex --version && command codex exec --help && command codex exec review --help && command codex exec resume --help`
- 버전 warn 시 최소 재검증 세트: 위 help diff + smoke 3종 (① 패턴 8 스모크 ② 성공 계약 판정식
  ③ help diff에서 변경이 의심되는 개별 항목 — 각 항목이 명시한 호출 형태 그대로). 개별 항목
  스탬프가 헤더 스탬프보다 우선하며, 전면 재확인 없이 헤더만 올리지 않는다.
- 스탬프 축 주의: 하네스 속성 항목(Bash tool 동작 등)은 codex가 아니라 Claude Code 버전으로
  스탬프한다 — codex 버전에 스탬프하면 재검증 트리거가 영원히 걸리지 않는다.

CLI 버전이 바뀌면 플래그/동작이 달라질 수 있으므로, 실행 전 도움말로 확인한다.

## 범위

| 포함 | 제외 |
|------|------|
| `codex exec` 비대화형 실행 | Codex 세션의 기본 subagent fan-out (`run-da` — audit 모드 포함) |
| `codex exec review` 코드 리뷰 | 대화형 TUI 사용법 |
| `codex exec resume` 세션 재개 | Codex 설정 파일 전체 관리 |
| stdin/파일 기반 프롬프트 전달 | Codex settings/skill projection (repo 정책/검증 스크립트 참조) |
| 결과 저장 및 자동화 출력 | |

## 의사결정 트리

```
codex exec 실행이 필요한가?
│
├─ 코드 리뷰인가?
│  ├─ YES → 커스텀 리뷰 지시가 필요한가?
│  │  ├─ YES ─────────────────────────────────────────────┐
│  │  │  ⚠️ review에서 PROMPT과 scope flag                 │
│  │  │  동시 사용 불가 (Known Issue #7825)                 │
│  │  │                                                    │
│  │  │  방법 A: AGENTS.md에 리뷰 지시 배치 후              │
│  │  │         review --base/--uncommitted 실행           │
│  │  │         (영구 지시, review의 diff 스코핑 유지)       │
│  │  │                                                    │
│  │  │  방법 B: codex exec에 diff + 지시를                 │
│  │  │         프롬프트로 직접 전달 (review 서브커맨드 미사용)│
│  │  │         (1회성 지시, 가장 유연)                      │
│  │  │                                                    │
│  │  │  → references/patterns.md 패턴 3, 4 참조           │
│  │  └──────────────────────────────────────────────────┘
│  │
│  └─ NO → codex exec review + scope flag
│          → references/patterns.md 패턴 2 참조
│
├─ 세션 재개인가?
│  └─ YES → codex exec resume <session-id> (id 명시가 정석 — --last 회피)
│           ⚠️ 저장 세션 없는 cwd의 --last는 무출력 hang 또는 새 세션
│           silent fallback (gotcha 4 두 축) → wrapper timeout 필수,
│           stderr/session id와 응답 context로 실제 재개 여부 검증
│
└─ 일반 실행 → 위 실행 경로 게이트로 raw/supervised 선택
               → references/patterns.md 패턴 1 참조
```

## 필요한 문서 선택

| 상황 | 읽을 문서 |
|------|-----------|
| subprocess 실행 전 | [execution-contracts.md](references/execution-contracts.md) — stdin·rc·결과 파일·background 회수·비신뢰 입력 경계 |
| 플래그 조합·alias·모델·effort·tier 설정 | [cli-reference.md](references/cli-reference.md) |
| exec·review·resume 호출 작성 | [execution-guide.md](references/execution-guide.md) |
| 병렬 실행·루프·격리 실행·fan-out 전 스모크 | [patterns.md](references/patterns.md) |
| 실행 실패·버전별 제약 진단 | [known-issues.md](references/known-issues.md) |

## 필수 실행 경계

- programmatic subprocess는 supervised 경로, stdin EOF, timeout budget을 적용한다. 프롬프트·stdout·stderr·결과 파일을 분리한다.
- CLI rc와 비어 있지 않은 결과·형식 계약을 함께 확인한다. 쓰기 작업은 외부에서 결정적 postcondition을 확인한다. stderr의 `ERROR:` 문자열이나 완료 표식만으로 성공을 판정하지 않는다.
- background는 pipe rc를 즉시 보존하고 guard, `.rc` 영속화, `exit "$rc"` 계약으로 회수한다. 종료 전 `-o` 부재와 단순 대기 지연은 실패가 아니다.
- fan-out 전 최소 스모크와 반복 작업의 진척·circuit breaker를 유지한다.
- read-only는 비밀 읽기와 웹검색을 차단하지 않는다. 비신뢰 입력은 execution-contracts의 env·cwd·설정 격리 및 외부 질의 경계를 적용한다.
- 명시한 `service_tier`는 성공 시에도 silent omit 경고를 확인한다. 사용자 지정 값과 권한·자원 범위를 조용히 대체하지 않는다.

문서와 CLI 동작이 다를 때는 CLAUDE.md의 "스킬 문서 불일치 시 행동 원칙"을 따른다.
help는 공개 surface의 SSOT다. help에서 사라진 hidden flag의 제거 여부는 실행 smoke로만 판정한다.
문서에서 명령 문자열을 찾을 때는 command substitution을 피하도록 `rg -F 'codex exec'`처럼
작은따옴표와 fixed-string 검색을 사용한다.
