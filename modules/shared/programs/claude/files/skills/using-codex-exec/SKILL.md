---
name: using-codex-exec
description: |
  This skill should be used when the user needs reliable Codex CLI
  non-interactive execution in Claude Code sessions. Triggers: "codex exec",
  "codex 실행", "codex CLI", "비대화형 codex", "non-interactive codex",
  "codex review", "codex 리뷰", "코드 리뷰 피드백".
---

# Codex Exec 사용

Claude Code 세션 내부에서 `codex exec`를 정확하고 반복 가능하게 실행하는 절차를 다룬다.

## 작성 기준

- 확인 날짜: **2026-02-26**
- 확인 버전: **codex-cli 0.104.0**
- 재검증: `codex --version && codex exec --help && codex exec review --help`

CLI 버전이 바뀌면 플래그/동작이 달라질 수 있으므로, 실행 전 도움말로 확인한다.

## 범위

| 포함 | 제외 |
|------|------|
| `codex exec` 비대화형 실행 | 대화형 TUI 사용법 |
| `codex exec review` 코드 리뷰 | Codex 설정 파일 전체 관리 → `configuring-codex` |
| stdin/파일 기반 프롬프트 전달 | Claude 하네스 투영 → `syncing-codex-harness` |
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
└─ 일반 실행 → codex exec --full-auto [-o result.md]
               → references/patterns.md 패턴 1 참조
```

## 호환성 매트릭스

### exec 전용 플래그 (review 미지원)

| 플래그 | 설명 |
|--------|------|
| `-o <FILE>` | 마지막 에이전트 메시지 저장 |
| `--output-schema <FILE>` | 구조화 JSON 출력 |
| `-i <FILE>` | 이미지 첨부 |
| `-s <MODE>` | 샌드박스 정책 |
| `-C <DIR>` | 작업 디렉토리 지정 |
| `--add-dir <DIR>` | 추가 쓰기 가능 디렉토리 |

### exec · review 공통 플래그

| 플래그 | 설명 |
|--------|------|
| `--full-auto` | 자동 실행 편의 별칭 (기본 사용값) |
| `-m <MODEL>` | 모델 지정 (생략 시 config.toml 기본값) |
| `--ephemeral` | 세션 파일 미저장 |
| `--json` | JSONL 이벤트 출력 |
| `--skip-git-repo-check` | Git 저장소 체크 건너뜀 |
| `-c <key=value>` | config 값 오버라이드 |

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
`-o`는 review에서 지원하지 않는다.

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
| review에 `-o` 사용 | `unexpected argument '-o' found` | stdout 리다이렉트 `> file 2>&1` |
| review에서 PROMPT + scope flag | `'[PROMPT]' cannot be used with '--base'` | 의사결정 트리의 방법 A 또는 B |
| exec 전용 플래그를 review에 전달 | `unexpected argument` | exec 전용/공통 매트릭스 확인 |
| 실패 원인 미확인 후 반복 재시도 | 동일 에러 반복 | known-issues.md 진단 절차 |
| 긴 루프에서 결과 파일 저장 생략 | 결과 유실 | `-o` 또는 리다이렉트 필수 사용 |

## 참조

- **상황별 실행 패턴**: [references/patterns.md](references/patterns.md)
- **제한사항/트러블슈팅**: [references/known-issues.md](references/known-issues.md)

문서와 CLI 동작이 다를 때는 CLAUDE.md의 "스킬 문서 불일치 시 행동 원칙"을 따른다.
`codex exec --help` / `codex exec review --help` 출력이 이 문서보다 항상 우선하는 진실 원천이다.
