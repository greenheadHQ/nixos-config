---
name: using-codex-exec
description: |
  Codex CLI non-interactive execution (codex exec, codex exec review, codex e,
  codex exec resume, codex review) in Claude Code sessions: running prompts,
  code reviews, result capture, --yolo bypass.
  Claude Code 전용 — Codex CLI 에이전트는 이 스킬을 사용하지 않는다.
  NOT for syncing harness/projecting skills to .agents/ (use syncing-codex-harness).
  NOT for Codex config.toml or trust settings (use configuring-codex).
  NOT for claude -p / headless Claude Code 비대화형 모드 (use using-claude-p).
  Triggers: "codex exec", "codex 실행", "codex CLI", "비대화형 codex",
  "non-interactive codex", "codex review", "codex 리뷰", "코드 리뷰 피드백",
  "codex exec review", "codex 결과 저장", "-o result.md", "codex e",
  "codex exec resume", "codex --yolo".
---

# Codex Exec 사용

Claude Code 세션 내부에서 `codex exec`를 정확하고 반복 가능하게 실행하는 절차를 다룬다.

## 작성 기준

- 확인 날짜: **2026-03-15**
- 확인 버전: **codex-cli 0.114.0**
- 재검증: `codex --version && codex exec --help && codex exec review --help`

CLI 버전이 바뀌면 플래그/동작이 달라질 수 있으므로, 실행 전 도움말로 확인한다.

## 범위

| 포함 | 제외 |
|------|------|
| `codex exec` 비대화형 실행 | 대화형 TUI 사용법 |
| `codex exec review` 코드 리뷰 | Codex 설정 파일 전체 관리 → `configuring-codex` |
| `codex exec resume` 세션 재개 | Claude 하네스 투영 → `syncing-codex-harness` |
| stdin/파일 기반 프롬프트 전달 | |
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
└─ 일반 실행 → codex exec --full-auto [-o result.md]
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
| `-i, --image <FILE>` | 이미지 첨부 |
| `-s, --sandbox <MODE>` | 샌드박스 정책 (read-only, workspace-write, danger-full-access) |
| `-C, --cd <DIR>` | 작업 디렉토리 지정 |
| `--add-dir <DIR>` | 추가 쓰기 가능 디렉토리 |
| `--output-schema <FILE>` | JSON Schema 출력 형식 |
| `--oss` | 오픈소스 프로바이더 |
| `--local-provider <PROVIDER>` | 로컬 프로바이더 (lmstudio/ollama) |
| `-p, --profile <PROFILE>` | config.toml 프로필 |
| `--color <COLOR>` | 색상 설정 (always/never/auto) |
| `--progress-cursor` | 커서 기반 진행률 |

### review 전용 플래그

| 플래그 | 설명 |
|--------|------|
| `--uncommitted` | 미커밋 변경 리뷰 |
| `--base <BRANCH>` | 베이스 브랜치 대비 리뷰 |
| `--commit <SHA>` | 특정 커밋 리뷰 |
| `--title <TITLE>` | 리뷰 요약 제목 (scope flag와 조합 가능, 상호 배타 규칙에 미참여. 단독 사용 시 `--commit <SHA>` 필요) |

### exec · review 공통 플래그

| 플래그 | 설명 |
|--------|------|
| `-c, --config <key=value>` | config 오버라이드 |
| `--enable <FEATURE>` | 피처 활성화 |
| `--disable <FEATURE>` | 피처 비활성화 |
| `-m, --model <MODEL>` | 모델 선택 (생략 권장 — config.toml 기본값 사용) |
| `--full-auto` | 자동 실행 (-a on-request, --sandbox workspace-write) |
| `--dangerously-bypass-approvals-and-sandbox` | 샌드박스 우회 (--yolo 숨은 alias) |
| `--skip-git-repo-check` | Git 저장소 체크 건너뜀 |
| `--ephemeral` | 세션 파일 미저장 |
| `--json` | JSONL 이벤트 출력 |
| `-o, --output-last-message <FILE>` | 마지막 메시지 파일 저장 (**review에서 upstream bug #12502로 빈 파일 생성**) |

### ⚠️ review 상호 배타 규칙

**다음 4개 인자는 모두 상호 배타적** — 한 번에 하나만 사용 가능:

|  | PROMPT | --base | --uncommitted | --commit |
|---|:---:|:---:|:---:|:---:|
| **PROMPT** | — | ❌ | ❌ | ❌ |
| **--base** | ❌ | — | ❌ | ❌ |
| **--uncommitted** | ❌ | ❌ | — | ❌ |
| **--commit** | ❌ | ❌ | ❌ | — |

위반 시 에러:

```
error: the argument '[PROMPT]' cannot be used with '--base <BRANCH>'
error: the argument '--base <BRANCH>' cannot be used with '--uncommitted'
```

근본 원인과 상세 분석: [references/known-issues.md](references/known-issues.md) §1

## 입력 방법

| 방법 | 예시 |
|------|------|
| 인라인 문자열 | `codex exec --full-auto "짧은 질의"` |
| stdin 파이프 | `cat prompt.md \| codex exec --full-auto -o result.md` |
| stdin 마커 | `codex exec review - --full-auto` (stdin에서 읽음) |
| 파일 리다이렉트 | `codex exec --full-auto < prompt.md -o result.md` |
| here-doc | `codex exec --full-auto <<'EOF' ... EOF` |

## 표준 실행 절차

### 일반 exec

프롬프트를 파일로 작성하고, stdin 파이프로 전달하며, `-o`로 결과를 저장한다:

```bash
cat > /tmp/prompt.md <<'PROMPT'
이 변경의 배포 리스크를 3개 이내로 지적한다.
PROMPT

cat /tmp/prompt.md | codex exec --full-auto -o /tmp/result.md 2>&1
```

인라인 프롬프트도 가능하다 (짧은 질의에 한해):

```bash
codex exec --full-auto "git diff 기준으로 회귀 가능성 한 줄 요약"
```

### 코드 리뷰 — scope flag만 사용 (커스텀 지시 불필요)

```bash
codex exec review --base main --full-auto > /tmp/review.md 2>&1
codex exec review --uncommitted --full-auto > /tmp/review.md 2>&1
codex exec review --commit <sha> --full-auto > /tmp/review.md 2>&1
```

review 결과를 파일 저장하려면 stdout 리다이렉트(`> file 2>&1`)를 사용한다.
`-o`는 review --help에 표시되지만 upstream bug(#12502)로 빈 파일을 생성한다.

### 코드 리뷰 — 커스텀 지시 필요

PROMPT과 scope flag이 상호 배타이므로, 두 가지 대안 중 선택한다:

**방법 A — AGENTS.md 활용 (영구 지시, review diff 스코핑 유지)**

프로젝트 `AGENTS.md` 또는 `~/.codex/AGENTS.override.md`에 리뷰 정책을 배치한 뒤,
scope flag으로 review를 실행하면 지시가 자동 적용된다.
(지시 파일 우선순위: [references/patterns.md](references/patterns.md) 패턴 3 참조)

**방법 B — exec 우회 (1회성 지시, 최대 유연성)**

`codex exec` (review 미사용)에 `git diff` 출력과 커스텀 지시를 프롬프트로 직접 전달한다.
`-o`로 결과 저장이 가능하고, 프롬프트 내용을 자유롭게 구성할 수 있다.

상세 명령과 예제: [references/patterns.md](references/patterns.md) 패턴 3, 4

### 세션 재개

```bash
codex exec resume --last          # 마지막 세션 재개
codex exec resume <session-id>    # 특정 세션 재개
codex exec resume --last --all    # cwd 필터 해제하여 전체 세션 중 최신 재개
```

⚠️ `--ephemeral` 세션은 파일이 저장되지 않으므로 resume 불가. `No saved session found` 에러 발생.

## Gotchas

1. **`--search`는 exec에서 미동작**: `error: unexpected argument '--search' found`. 대안: `-c web_search=live`
2. **`--full-auto`는 `--sandbox`를 묵묵히 override**: `-s read-only` 명시해도 `workspace-write`로 강제됨
3. **CODEX_API_KEY는 exec 전용**: interactive TUI와 VS Code extension에서는 무시됨. OPENAI_API_KEY는 auth 체인에 미참여 (TUI prefill 전용). 우선순위: CODEX_API_KEY > ephemeral tokens > auth.json (상세: [known-issues.md](references/known-issues.md) 워크트리 참고)
4. **ephemeral 세션 resume 불가**: `--ephemeral`으로 실행한 세션은 파일 미저장되어 `No saved session found` 에러 발생
5. **`codex review` (top-level) vs `codex exec review`**: 전자는 `-m`, `--full-auto`, `--json`, `-o` 등 미지원. 비대화형 자동화에는 반드시 `codex exec review` 사용

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
| review에서 `-o` 결과 저장 의존 | 빈 파일 생성 (upstream bug #12502) | stdout 리다이렉트 `> file 2>&1` |
| review에서 PROMPT + scope flag | `'[PROMPT]' cannot be used with '--base'` | 의사결정 트리의 방법 A 또는 B |
| exec 전용 플래그를 review에 전달 | `unexpected argument` | exec 전용/공통 매트릭스 확인 |
| `-m o3` / `-m o4-mini` 등 비Codex 모델 지정 | "Model metadata not found" + "model is not supported" | `-m` 생략, config.toml 기본 모델 사용 |
| `-m` 플래그로 매번 다른 모델 지정 | 불일치/에러 위험 | config.toml 기본값 사용 원칙 |
| 실패 원인 미확인 후 반복 재시도 | 동일 에러 반복 | known-issues.md 진단 절차 |
| 긴 루프에서 결과 파일 저장 생략 | 결과 유실 | `-o` 또는 리다이렉트 필수 사용 |

## 참조

- **상황별 실행 패턴**: [references/patterns.md](references/patterns.md)
- **제한사항/트러블슈팅**: [references/known-issues.md](references/known-issues.md)

문서와 CLI 동작이 다를 때는 CLAUDE.md의 "스킬 문서 불일치 시 행동 원칙"을 따른다.
`codex exec --help` / `codex exec review --help` 출력이 이 문서보다 항상 우선하는 진실 원천이다.
