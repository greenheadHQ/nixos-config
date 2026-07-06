---
name: using-codex-exec
description: |
  Run Codex CLI non-interactive (codex exec, codex review).
  Trigger: 'codex exec', 'codex 실행', '비대화형 codex', 'codex review', '--yolo'.
  NOT for Codex settings/skill projection. NOT for claude -p (use using-claude-p).
---

# Codex Exec 사용

이 문서는 `codex exec` / `codex exec review`를 직접 호출하는 절차를 다룬다.
이 스킬은 다음 경로에서 참조된다:
- Claude Code 세션: `run-da`(audit 모드 포함) 등의 fan-out 시 기본 경로 (codex exec subprocess)
- headless 세션: CI, `codex exec` subprocess 등에서의 codex exec 직접 실행 (`claude -p` 자체의 사용법은 using-claude-p 스킬 참조)
- Codex 세션: fan-out은 native subagent가 기본이므로, 이 스킬은 사용자의 명시적 `codex exec` 요청에만 적용

## 작성 기준

- 확인 날짜: 2026-07-03
- 확인 버전: codex-cli 0.142.5
- 재검증: `codex --version && codex exec --help && codex exec review --help`

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
│  └─ YES → codex exec resume --last 또는 <session-id>
│           ⚠️ --ephemeral 세션은 resume 불가
│
└─ 일반 실행 → codex exec -s workspace-write [-o result.md]
               → references/patterns.md 패턴 1 참조
```

## 명령 alias

| 명령 | 설명 |
|------|------|
| `codex e` | `codex exec`의 단축 alias |
| `codex review` | top-level alias (⚠️ `codex exec review`와 다름 — 아래 gotcha §5 참조) |
| `--yolo` | `--dangerously-bypass-approvals-and-sandbox`의 숨은 alias |

## 호환성 매트릭스

### exec 전용 플래그 (review 미지원)

| 플래그 | 설명 |
|--------|------|
| `-i, --image <FILE>...` | 이미지 첨부 (0.142.5 기준 다중 지정 가능) |
| `-s, --sandbox <SANDBOX_MODE>` | 샌드박스 정책 (read-only, workspace-write, danger-full-access) — review/resume은 미지원 |
| `-C, --cd <DIR>` | 작업 디렉토리 지정 |
| `--add-dir <DIR>` | 추가 쓰기 가능 디렉토리 |
| `--oss` | 오픈소스 프로바이더 |
| `--local-provider <OSS_PROVIDER>` | 로컬 프로바이더 (lmstudio/ollama) |
| `-p, --profile <CONFIG_PROFILE_V2>` | `$CODEX_HOME/<name>.config.toml`을 기본 유저 config 위에 레이어 |
| `--color <COLOR>` | 색상 설정 (always/never/auto) |

### review 전용 플래그

| 플래그 | 설명 |
|--------|------|
| `--uncommitted` | 미커밋 변경 리뷰 |
| `--base <BRANCH>` | 베이스 브랜치 대비 리뷰 |
| `--commit <SHA>` | 특정 커밋 리뷰 |
| `--title <TITLE>` | 리뷰 요약 제목 (scope flag와 조합 가능, 상호 배타 규칙에 미참여. 단독 사용 시 `--commit <SHA>` 필요 — 재확인: 2026-07-03, 0.142.5) |

### exec · review · resume 공통 플래그

| 플래그 | 설명 |
|--------|------|
| `-c, --config <key=value>` | config 오버라이드 |
| `--enable <FEATURE>` | 피처 활성화 |
| `--disable <FEATURE>` | 피처 비활성화 |
| `--strict-config` | config.toml에 인식 불가 필드가 있으면 에러 (신규, 0.142.5) |
| `-m, --model <MODEL>` | 모델 선택 (생략 권장 — config.toml 기본값 사용) |
| `--output-schema <FILE>` | JSON Schema 출력 형식 — 0.142.5부터 review/resume도 지원 (이전에는 exec 전용) |
| `--dangerously-bypass-approvals-and-sandbox` | 샌드박스 우회 (`--yolo` 숨은 alias) |
| `--dangerously-bypass-hook-trust` | 영속 hook trust 없이 활성 hook 실행 허용 (신규, 0.142.5 — 자동화 전용, 위험) |
| `--skip-git-repo-check` | Git 저장소 체크 건너뜀 |
| `--ephemeral` | 세션 파일 미저장 |
| `--ignore-user-config` | `$CODEX_HOME/config.toml` 로드 차단 (auth만 유지) |
| `--ignore-rules` | user/project execpolicy `.rules` 파일 로드 차단 |
| `--json` | JSONL 이벤트 출력 |
| `-o, --output-last-message <FILE>` | 마지막 메시지 파일 저장 (review의 upstream bug #12502는 0.142.5에서 해소됨 — known-issues.md §2 참조) |

⚠️ 승인(approval) 관련 CLI 플래그는 존재하지 않는다. `exec`/`review`/`resume`은 headless 실행이므로 승인 프롬프트 자체가 불가능하고, approval은 항상 `never`로 고정된다 (`--ignore-user-config`로 확인한 CLI 기본값 기준, 2026-07-03 실측). 과거 버전에 있던 자동 실행 플래그(승인 자동화 + `--sandbox workspace-write`를 한 번에 지정)는 0.142.5에서 완전히 제거되었다. 동일 의도의 실행은 아래로 대체한다:

- `exec`: `-s workspace-write` (승인은 이미 자동이므로 샌드박스 tier만 지정하면 된다)
- `review`/`resume`: 전용 sandbox 플래그가 없으므로 `config.toml`의 `sandbox_mode`를 따르거나, 필요 시 `--dangerously-bypass-approvals-and-sandbox`를 사용한다

### ⚠️ review 상호 배타 규칙

다음 4개 인자는 모두 상호 배타적 — 한 번에 하나만 사용 가능:

|  | PROMPT | --base | --uncommitted | --commit |
|---|:---:|:---:|:---:|:---:|
| PROMPT | — | ❌ | ❌ | ❌ |
| --base | ❌ | — | ❌ | ❌ |
| --uncommitted | ❌ | ❌ | — | ❌ |
| --commit | ❌ | ❌ | ❌ | — |

위반 시 에러:

```
error: the argument '[PROMPT]' cannot be used with '--base <BRANCH>'
error: the argument '--base <BRANCH>' cannot be used with '--uncommitted'
```

재확인: 2026-07-03, 0.142.5에서도 4개 변형 모두 동일하게 상호 배타 유지됨 (완화되지 않음).

근본 원인과 상세 분석: [references/known-issues.md](references/known-issues.md) §1

## 입력 방법

표 안의 모든 `codex exec` 호출에는 `env CODEX_PROGRAMMATIC=1`을 codex 프로세스에 적용한다 (issue #585: Codex 0.124+ user-level hooks의 early-exit 신호).

| 방법 | 예시 |
|------|------|
| 인라인 문자열 | `env CODEX_PROGRAMMATIC=1 codex exec -s workspace-write "짧은 질의"` |
| stdin 파이프 | `cat prompt.md \| env CODEX_PROGRAMMATIC=1 codex exec -s workspace-write -o result.md` |
| stdin 마커 | `env CODEX_PROGRAMMATIC=1 codex exec review -` (stdin에서 읽음) |
| 파일 리다이렉트 | `env CODEX_PROGRAMMATIC=1 codex exec -s workspace-write < prompt.md -o result.md` |
| here-doc | `env CODEX_PROGRAMMATIC=1 codex exec -s workspace-write <<'EOF' ... EOF` |

⚠️ PROMPT 인자와 stdin을 동시에 사용하는 경우(0.142.5 신규 동작, `codex exec --help` 기준): stdin이 파이프된 상태에서 PROMPT 인자도 함께 주어지면, stdin 내용이 프롬프트에 `<stdin>` 블록으로 append된다. 이전 버전에서는 이 조합의 동작이 문서화되어 있지 않았다. 위 표의 각 방법은 여전히 단독 사용을 기본으로 하되, 혼용 시 이 append 동작을 인지한다.

## 표준 실행 절차

NixOS에서 `-s read-only` / `-s workspace-write`를 구조적으로 강제하려면 `bubblewrap`이
PATH에 있어야 한다. bwrap 의존성, 임시 우회, tier별 실측은 [known-issues.md §16](references/known-issues.md#16-nixos-bwrap-의존)을 참조한다.

### 일반 exec

프롬프트를 파일로 작성하고, stdin 파이프로 전달하며, `-o`로 결과를 저장한다:

```bash
cat > /tmp/prompt.md <<'PROMPT'
이 변경의 배포 리스크를 3개 이내로 지적한다.
PROMPT
```

⚠️ `run_in_background` 환경: 여기서 Bash tool 호출을 종료하고, 아래를 별도 호출로 실행한다 ([§11](references/known-issues.md) 하위 항목).

```bash
# marker must apply to `codex`, not `cat` (issue #585): Codex 0.124+ user-level hooks의 early-exit 신호.
cat /tmp/prompt.md | env CODEX_PROGRAMMATIC=1 codex exec -s workspace-write -o /tmp/result.md 2>&1
```

인라인 프롬프트도 가능하다 (짧은 질의에 한해):

```bash
env CODEX_PROGRAMMATIC=1 codex exec -s workspace-write "git diff 기준으로 회귀 가능성 한 줄 요약"
```

### 코드 리뷰 — scope flag만 사용 (커스텀 지시 불필요)

```bash
env CODEX_PROGRAMMATIC=1 codex exec review --base main > /tmp/review.md 2>&1
env CODEX_PROGRAMMATIC=1 codex exec review --uncommitted > /tmp/review.md 2>&1
env CODEX_PROGRAMMATIC=1 codex exec review --commit <sha> > /tmp/review.md 2>&1
```

review 결과 저장에는 `-o`(`--output-last-message`) 또는 stdout 리다이렉트(`> file 2>&1`) 둘 다 사용 가능하다.
`-o`가 빈 파일을 생성하던 upstream bug(#12502)는 0.142.5에서 해소됨 (재확인: 2026-07-03, known-issues.md §2 참조). 과거 문서/스크립트가 이 회피책으로 stdout 리다이렉트를 쓰고 있다면 그대로 두어도 무방하다 — 대체 필수는 아니다.

### 코드 리뷰 — 커스텀 지시 필요

PROMPT과 scope flag이 상호 배타이므로, 두 가지 대안 중 선택한다:

방법 A — AGENTS.md 활용 (영구 지시, review diff 스코핑 유지)

프로젝트 `AGENTS.md` 또는 `~/.codex/AGENTS.override.md`에 리뷰 정책을 배치한 뒤,
scope flag으로 review를 실행하면 지시가 자동 적용된다.
(지시 파일 우선순위: [references/patterns.md](references/patterns.md) 패턴 3 참조)

방법 B — exec 우회 (1회성 지시, 최대 유연성)

`codex exec` (review 미사용)에 `git diff` 출력과 커스텀 지시를 프롬프트로 직접 전달한다.
`-o`로 결과 저장이 가능하고, 프롬프트 내용을 자유롭게 구성할 수 있다.

상세 명령과 예제: [references/patterns.md](references/patterns.md) 패턴 3, 4

### 세션 재개

```bash
env CODEX_PROGRAMMATIC=1 codex exec resume --last          # 마지막 세션 재개
env CODEX_PROGRAMMATIC=1 codex exec resume <session-id>    # 특정 세션 재개
env CODEX_PROGRAMMATIC=1 codex exec resume --last --all    # cwd 필터 해제하여 전체 세션 중 최신 재개
```

⚠️ `--ephemeral` 세션은 파일이 저장되지 않으므로 resume 불가. `No saved session found` 에러 발생.

## Gotchas

1. `--search`는 exec에서 미동작: `error: unexpected argument '--search' found`. 대안: `-c web_search=live` (재확인: 2026-07-03, 0.142.5에서도 동일)
2. 과거 자동 실행 플래그(승인 자동화 + `--sandbox workspace-write`를 함께 지정하던 단축 플래그)는 0.142.5에서 완전히 제거됨: 그 이름 그대로 호출하면 `error: unexpected argument ... found`. exec에서는 `-s workspace-write`로 명시한다. 재확인 결과 이 조합은 config.toml의 `sandbox_mode`를 조용히 override하지 않는다 — 명시한 `-s` 값이 그대로 적용된다 (2026-07-03 실측: `-s read-only` 지정 시 config.toml이 `danger-full-access`여도 실제로 `read-only`로 실행됨).
3. CODEX_API_KEY는 exec 전용: interactive TUI와 VS Code extension에서는 무시됨. OPENAI_API_KEY는 auth 체인에 미참여 (TUI prefill 전용). 우선순위: CODEX_API_KEY > ephemeral tokens > auth.json (상세: [known-issues.md](references/known-issues.md) 워크트리 참고)
4. ephemeral 세션 resume 불가: `--ephemeral`으로 실행한 세션은 파일 미저장되어 `No saved session found` 에러 발생
5. `codex review` (top-level) vs `codex exec review`: 전자는 `-m`, `--json`, `-o`, `--output-schema`, `--ephemeral`, `-s/--sandbox` 등 미지원 (재확인: 2026-07-03, `codex review --help`). 비대화형 자동화에는 반드시 `codex exec review` 사용
6. Bash tool sandbox에서 `&` + `$!` 미작동: Claude Code의 Bash tool에서 background process PID 캡처(`$!`)가 리터럴 문자열로 반환됨. shell-level 병렬 대신 여러 병렬 Bash tool 호출 (예: codex exec 경로의 `run-da` — audit 모드 포함) + `cat file | env CODEX_PROGRAMMATIC=1 codex exec ... -` stdin pipe를 사용한다. 이 제약은 Codex 세션의 native subagent 경로에는 적용되지 않는다. 상세: [known-issues.md](references/known-issues.md) §11
7. stdin pipe로 stdin hang 방지: Claude Code Bash tool에서 병렬 호출 시 codex exec가 background로 자동 전환되면, stdin이 닫히지 않아 `Reading additional input from stdin...`에서 hang이 발생한다. `cat file | env CODEX_PROGRAMMATIC=1 codex exec ... -` stdin pipe를 사용하면 pipe EOF가 stdin을 구조적으로 닫아 hang을 방지한다: `cat "$DIR/prompt.md" | env CODEX_PROGRAMMATIC=1 codex exec -s workspace-write --ephemeral -o "$DIR/result.md" - 2>"$DIR/stderr.log"`. 인라인 인자 `"$(cat file)"`와 `< /dev/null`은 사용하지 않는다. 상세: [known-issues.md](references/known-issues.md) §14

## 모델 사용 원칙

- 기본 모델: `~/.codex/config.toml`의 `model` 값을 따른다.
- 리뷰 전용 모델: `review_model` 설정으로 분리 가능하다.
- 실무 원칙:
  1. `-m`을 생략하고 기본 모델을 사용한다.
  2. `model is not supported` 오류 시 `-m`을 제거하고 재시도한다.
  3. 모델명을 매번 다르게 혼용하지 않는다.

## 운영 체크리스트

실행 전:
- `codex --version`으로 기대 버전 확인
- `pwd`가 대상 저장소 루트인지 확인
- 프롬프트 파일 경로와 결과 파일 경로를 분리

실행 후:
- 결과 파일 생성 여부 확인 (`-o` 또는 리다이렉트)
- 빈 결과 시 stderr 로그부터 확인
- 다음 라운드 입력에 반영할 액션 항목만 추출

## 하지 말아야 할 패턴

| 금지 패턴 | 발생 에러 | 올바른 대안 |
|-----------|----------|------------|
| review에서 PROMPT + scope flag | `'[PROMPT]' cannot be used with '--base'` | 의사결정 트리의 방법 A 또는 B |
| exec 전용 플래그를 review에 전달 | `unexpected argument` | exec 전용/공통 매트릭스 확인 |
| `-m o3` / `-m o4-mini` 등 비Codex 모델 지정 | "Model metadata not found" + "model is not supported" | `-m` 생략, config.toml 기본 모델 사용 |
| `-m` 플래그로 매번 다른 모델 지정 | 불일치/에러 위험 | config.toml 기본값 사용 원칙 |
| 실패 원인 미확인 후 반복 재시도 | 동일 에러 반복 | known-issues.md 진단 절차 |
| 긴 루프에서 결과 파일 저장 생략 | 결과 유실 | `-o` 또는 리다이렉트 필수 사용 |

## 참조

- 상황별 실행 패턴: [references/patterns.md](references/patterns.md)
- 제한사항/트러블슈팅: [references/known-issues.md](references/known-issues.md)

문서와 CLI 동작이 다를 때는 CLAUDE.md의 "스킬 문서 불일치 시 행동 원칙"을 따른다.
`codex exec --help` / `codex exec review --help` 출력이 이 문서보다 항상 우선하는 진실 원천이다.
