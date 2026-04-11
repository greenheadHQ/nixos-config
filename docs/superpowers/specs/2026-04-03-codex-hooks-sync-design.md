# Codex Hooks Sync Design

> **Historical Note (#455):** 이 문서의 hook 분류 예시와 예상 산출물에 포함된
> `detect-pain-point.sh`, `collect-pain-points.sh`, `read-pain-points.sh`, `auto-archive.sh`는
> #455에서 제거되었다. 본문의 supported/lossy 분류, 예상 `.codex/hooks.json`, smoke test 예시는
> 제거 이전 기준이다. 현재 hook surface는 `settings.json`을 참조할 것.

## 상태

- 작성일: 2026-04-03
- 검증 기준일: 2026-04-03
- 로컬 검증 CLI: `codex-cli 0.118.0`
- 목표: 기존 Claude Code -> Codex harness sync에 hooks를 추가하되, Codex 공식 표면에서 의미가 유지되는 hook만 안전하게 투영한다.

## 1. 문제 정의

현재 harness sync는 skills, agents, MCP, AGENTS 계열만 Codex로 투영하고 hooks는 제외한다.
초기 설계 당시 Codex는 hooks를 지원하지 않았기 때문이다.

하지만 2026-04-03 기준 Codex 공식 문서에는 hooks가 experimental 기능으로 문서화되어 있다.
문제는 Claude hooks와 Codex hooks의 표면이 아직 크게 다르다는 점이다.

이 설계의 목적은 두 가지다.

1. Codex에서 직접 호환되는 Claude hook는 선언적으로 자동 sync한다.
2. 호환되지 않는 Claude hook는 조용히 흉내내지 않고, 경고와 compatibility report로 명시한다.

## 2. 최신 레퍼런스 기준

2026-04-03 기준으로 확인한 공식 레퍼런스:

- Codex Hooks: <https://developers.openai.com/codex/hooks>
- Codex Config Reference: <https://developers.openai.com/codex/config-reference>
- Codex generated hook schema: <https://github.com/openai/codex/tree/main/codex-rs/hooks/schema/generated>
- Claude Code Hooks Guide: <https://code.claude.com/docs/en/hooks-guide>

핵심 차이:

- Codex hooks는 experimental이다.
- Codex는 `config.toml`의 `[features] codex_hooks = true`가 있어야 hooks 엔진이 활성화된다.
- Codex hook 정의 파일은 `~/.codex/hooks.json` 또는 `<repo>/.codex/hooks.json`이다.
- Codex 문서화 이벤트는 `SessionStart`, `PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `Stop`이다.
- Codex의 `PreToolUse` / `PostToolUse`는 현재 사실상 `Bash`만 실질 지원한다.
- Codex는 `UserPromptSubmit` / `Stop`의 `matcher`를 현재 무시한다.
- Claude의 `SessionEnd`, `Notification`, `PermissionRequest`, `prompt` hook type 등은 Codex 공식 문서상 직접 대응이 없다.

따라서 1:1 포팅은 설계 목표가 될 수 없고, 호환성 분류와 안전한 축소 투영이 설계 중심이 된다.

## 3. 채택한 접근

채택: `호환성 컴파일러`

정의:
- Claude hook 선언을 입력으로 읽는다.
- 각 matcher-group을 `supported`, `lossy`, `unsupported`로 분류한다.
- 분류 결과를 바탕으로 `<repo>/.codex/hooks.json`과 compatibility report를 함께 생성한다.

이 접근을 고른 이유:

- 단순 복사보다 안전하다.
- unsupported 항목을 숨기지 않는다.
- Codex experimental surface가 바뀌어도 분류 테이블만 갱신하면 된다.
- 현재 사용자 요구인 `A + C`와 정확히 맞는다.
  - `A`: 사용자가 즉시 문제를 파악할 수 있어야 함
  - `C`: LLM이 원인 진단에 사용할 수 있는 구조화 리포트가 있어야 함

## 4. 책임 분리

### 4.1 Nix의 책임

전역 Codex 기능 enablement는 Nix가 담당한다.

즉, 아래 파일에 `[features] codex_hooks = true`를 선언적으로 넣는다.

- `modules/shared/programs/codex/files/config.toml`
- `modules/shared/programs/codex/files/config.darwin.toml`

이 설정은 hooks 엔진을 모든 Codex 세션에서 켜지만, 실제로 어떤 hook가 실행될지는 각 scope의 `hooks.json`이 결정한다.

### 4.2 sync.sh의 책임

`sync.sh` / `codex-sync`의 책임은 project-local hook 산출물 생성으로 제한한다.

생성 대상:

- `<repo>/.codex/hooks.json`
- `<repo>/.codex/hooks.compatibility.json`

생성하지 않는 것:

- `~/.codex/hooks.json`
- Claude 전용 의미를 억지로 흉내내는 래퍼
- 인접 기능을 이용한 비공식 에뮬레이션

## 5. 소스 오브 트루스

기본 소스는 선언적 Claude 설정이다.

우선순위:

1. 리포 선언 소스: `modules/shared/programs/claude/files/settings.json`
2. 런타임 effective 소스: `~/.claude/settings.json`

동작:

- 분류와 생성은 1번 선언 소스를 기준으로 한다.
- 2번 파일이 존재하면 drift check를 수행한다.
- 선언 소스와 effective 소스의 hook 구조가 다르면 compatibility report에 `drift_detected: true`로 기록한다.
- drift는 경고 대상이지만 sync 실패 사유는 아니다.

이 규칙은 선언적 관리 원칙을 유지하면서도, 실제 사용자 환경이 어긋났을 때 진단 근거를 남긴다.

## 6. 종료 코드 정책

기본 동작은 부분 성공이다.

- 지원되는 항목은 생성한다.
- unsupported / lossy 항목은 report와 stderr에 남긴다.
- 기본 종료 코드는 `0`이다.

이 설계에서 unsupported hook가 있다는 사실은 "실패"가 아니라 "현재 Codex 표면의 한계"다.
따라서 worktree bootstrap이나 평소 `codex-sync` 자동화를 깨지 않는 편이 맞다.

추가적인 strict mode는 이번 설계의 필수 범위에 넣지 않는다.

## 7. 호환성 분류 규칙

컴파일러는 Claude `hooks.<Event>[]`의 각 matcher-group을 독립 단위로 분류한다.
판정 기준은 "스크립트 내용"보다 먼저 "이벤트 + matcher 의미"다.

### 7.1 Supported

Codex에서 이벤트와 matcher 의미가 실질적으로 유지되는 경우만 허용한다.

허용 규칙:

- `UserPromptSubmit`
  - `matcher`가 `""`, `"*"`, 또는 생략이면 supported
- `Stop`
  - `matcher`가 `""`, `"*"`, 또는 생략이면 supported
- `SessionStart`
  - `matcher`가 `startup`, `resume`, `startup|resume`, `resume|startup`이면 supported

### 7.2 Lossy

이벤트는 유지되지만 일부 의미가 축소되는 경우다.

허용 규칙:

- `SessionStart`
  - Claude `matcher=""` 또는 `"*"`는 Codex에서 `startup|resume`으로 축소 변환
- `UserPromptSubmit`
  - Claude에 비어 있지 않은 matcher가 있으면 Codex가 이를 무시하므로 lossy
- `Stop`
  - Claude에 비어 있지 않은 matcher가 있으면 Codex가 이를 무시하므로 lossy

lossy 항목은 생성은 하되 report에 이유를 남긴다.

### 7.3 Unsupported

다음 조건 중 하나라도 맞으면 생성 대상에서 제외한다.

- Codex 공식 문서에 해당 이벤트가 없음
- Codex가 현재 그 matcher 의미를 보장하지 않음
- Codex 공식 표면이 아닌 hook type 또는 제어 계약에 의존함

현재 명시적 unsupported 규칙:

- 모든 `SessionEnd`
- 모든 `PreToolUse` except Bash-only matcher
- 모든 `PostToolUse` except Bash-only matcher
- Claude 전용 이벤트 및 hook type 전부

이 저장소에서는 현재 `PreToolUse` / `PostToolUse`가 모두 Bash-only 조건을 충족하지 않으므로 전부 unsupported가 된다.

## 8. 현재 저장소에 대한 분류 결과

입력 소스:
- `modules/shared/programs/claude/files/settings.json`

### 8.1 Supported

- `UserPromptSubmit` + `~/.claude/hooks/detect-pain-point.sh`
- `Stop` + `~/.claude/hooks/stop-notification.sh`
- `Stop` + `~/.claude/hooks/nrs-session-cleanup.sh`
- `Stop` + `~/.claude/hooks/collect-pain-points.sh`

### 8.2 Lossy

- `SessionStart` matcher `""`
  - `~/.claude/hooks/session-init-icons.sh`
  - `~/.claude/hooks/read-pain-points.sh`
  - Codex에서는 `startup|resume`으로 축소 변환

### 8.3 Unsupported

- `PreToolUse` matcher `AskUserQuestion`
  - `~/.claude/hooks/ask-notification.sh`
- `PreToolUse` matcher `ExitPlanMode`
  - `~/.claude/hooks/plan-notification.sh`
- `PreToolUse` matcher `Edit|Write`
  - `~/.claude/hooks/worktree-path-guard.sh`
- `PreToolUse` matcher `Skill`
  - `~/.claude/hooks/log-skill.sh`
- `PreToolUse` matcher `Edit|Write`
  - `~/.claude/hooks/fragile-hardcoding-guard.sh`
- `SessionEnd` matcher `""`
  - `~/.claude/hooks/nrs-session-cleanup.sh`
- `PostToolUse` matcher `ExitWorktree`
  - `~/.local/bin/nrs-relink fix-dangling`

정리:

- pain-point 수집/주입 계열은 상당 부분 이식 가능하다.
- Stop 알림 계열은 유지 가능하다.
- 편집 차단, skill logging, plan 승인 알림, AskUserQuestion 알림은 현재 Codex 표면상 직접 이식할 수 없다.

## 9. 산출물 형식

### 9.1 `.codex/hooks.json`

실행 산출물이다.

원칙:

- event > matcher-group > hooks[] 구조를 유지한다.
- unsupported group은 제거한다.
- lossy group은 변환 후 포함한다.
- command path는 기존 Claude hook 스크립트 경로를 우선 재사용한다.

예상 구조:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume",
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/session-init-icons.sh" },
          { "type": "command", "command": "~/.claude/hooks/read-pain-points.sh" }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/detect-pain-point.sh" }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/stop-notification.sh" },
          { "type": "command", "command": "~/.claude/hooks/nrs-session-cleanup.sh" },
          { "type": "command", "command": "~/.claude/hooks/collect-pain-points.sh" }
        ]
      }
    ]
  }
}
```

### 9.2 `.codex/hooks.compatibility.json`

기계 판독용 진단 리포트다.

필수 필드:

```json
{
  "generated_at": "2026-04-03T12:34:56+09:00",
  "generator": "syncing-codex-harness",
  "codex_cli_version": "0.118.0",
  "codex_hooks_docs_validated_on": "2026-04-03",
  "source_settings_path": "modules/shared/programs/claude/files/settings.json",
  "effective_settings_path": "/Users/example/.claude/settings.json",
  "drift_detected": false,
  "summary": {
    "total": 10,
    "supported": 2,
    "lossy": 1,
    "unsupported": 7
  },
  "items": [
    {
      "event": "PreToolUse",
      "matcher": "Edit|Write",
      "commands": ["~/.claude/hooks/worktree-path-guard.sh"],
      "status": "unsupported",
      "reason": "Codex PreToolUse currently supports Bash matcher only",
      "codex_mapping": null,
      "notes": []
    }
  ]
}
```

`items[]`는 Claude matcher-group 단위로 하나씩 기록한다.

### 9.3 stderr summary

`sync.sh all` 실행 시 아래 수준의 요약을 stderr에 출력한다.

```text
Hooks: 2 supported, 1 lossy, 7 unsupported
Hooks report: .codex/hooks.compatibility.json
Hooks output: .codex/hooks.json
```

## 10. sync.sh 통합 방식

`sync.sh`에 hook 전용 단계가 추가된다.

의도:

- 현재 `mcp-config`와 비슷하게 특정 산출물만 부분 갱신 가능해야 한다.
- `all`에서도 자동 포함되어야 한다.

새 서브커맨드:

- `hooks-config <project-root> [--project-settings=PATH] [--effective-settings=PATH]`

`all` 파이프라인 변경:

기존:
- init
- AGENTS.md
- skills
- agents
- AGENTS.override.md
- MCP
- trust
- gitignore

변경 후:
- init
- AGENTS.md
- skills
- agents
- AGENTS.override.md
- MCP
- hooks
- trust
- gitignore

주의:

- `.codex/config.toml`은 기존처럼 MCP 섹션만 관리한다.
- hooks enablement는 `config.toml` 템플릿 파일에서 선언적으로 관리한다.
- `sync.sh`는 `.codex/hooks.json`과 `.codex/hooks.compatibility.json`를 생성한다.

## 11. 문서 갱신 범위

다음 문서의 "Codex hooks 미지원" 서술은 최신 사실에 맞게 갱신한다.

- `modules/shared/programs/claude/files/skills/syncing-codex-harness/SKILL.md`
- `modules/shared/programs/claude/files/skills/syncing-codex-harness/references/sync.sh`
- `modules/shared/programs/claude/files/skills/syncing-codex-harness/references/codex-structure.md`
- `modules/shared/programs/claude/files/skills/syncing-codex-harness/references/agents-override-template.md`
- `AGENTS.override.md`

갱신 원칙:

- "not supported"를 "experimental, partial compatibility only"로 수정한다.
- Codex가 Claude hooks를 완전히 지원한다고 쓰지 않는다.
- 현재 지원 범위가 좁고 fail-open 지점이 있다는 사실을 반드시 남긴다.

## 12. 검증 전략

### 12.1 정적 검증

- `.codex/hooks.json`이 유효한 JSON이어야 한다.
- `.codex/hooks.compatibility.json`이 유효한 JSON이어야 한다.
- summary 수치와 items 집계가 일치해야 한다.
- drift 여부가 선언 소스와 effective 소스의 실제 차이와 일치해야 한다.

### 12.2 구조 검증

- `supported`와 `lossy` 항목만 `.codex/hooks.json`에 존재해야 한다.
- `unsupported` 항목은 `.codex/hooks.json`에 존재하면 안 된다.
- lossy `SessionStart`는 `startup|resume` matcher로 렌더되어야 한다.

### 12.3 런타임 smoke test

실험 기능이므로 런타임 검증은 best-effort smoke test로 정의한다.

검증 대상:

- global Codex config에 `[features] codex_hooks = true` 포함
- repo-local `.codex/hooks.json` 발견
- `SessionStart` context 주입 확인
- `UserPromptSubmit` hook 실행 확인
- `Stop` hook 실행 확인

이 단계는 Codex experimental 구현에 의존하므로, 실패 시 설계 오류와 런타임 회귀를 분리해서 판단해야 한다.

## 13. 비목표

이번 설계에서 하지 않는 것:

- `~/.codex/hooks.json` 생성
- unsupported Claude hook의 비공식 에뮬레이션
- notification 기능을 Codex 인접 기능으로 우회 매핑
- strict CI failure 정책
- Claude hook 스크립트를 Codex 전용으로 대량 재작성

즉, 이번 작업은 "안전한 직접 호환 hook sync"까지가 범위다.

## 14. 결정 요약

- 접근: 호환성 컴파일러
- 기본 정책: 부분 성공 + 경고 + structured report
- 종료 코드: 기본 `0`
- hook 소스: 선언적 repo 설정 우선, effective settings는 drift report용
- 산출물 위치: `<repo>/.codex/hooks.json`
- Codex enablement: Nix-managed global `config.toml`에 `[features] codex_hooks = true`
- unsupported hook: 생성하지 않음
- lossy hook: 생성하되 report에 이유 기록
