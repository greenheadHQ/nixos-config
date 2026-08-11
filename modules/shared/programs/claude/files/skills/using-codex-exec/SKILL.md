---
name: using-codex-exec
description: >-
  Run Codex CLI subprocesses for explicit codex exec requests, Claude Code or headless automation,
  and non-interactive code review. Use when requests mention `codex exec` or `비대화형 codex`.
  Use using-claude-p for Claude headless execution.
---

# Codex Exec 사용

이 문서는 `codex exec` / `codex exec review` subprocess의 라우팅과 성공 계약을 다룬다.
상세 명령·제약의 SSOT는 [patterns.md](references/patterns.md)와
[known-issues.md](references/known-issues.md)이며, 본문은 선택 기준과 필수 절차만 요약한다.

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
│           ⚠️ --ephemeral 원본은 0.144.1에서 새 세션으로 silent fallback 가능
│           → stderr/session id와 응답 context로 실제 재개 여부 검증
│
└─ 일반 실행 → 위 실행 경로 게이트로 raw/supervised 선택
               → references/patterns.md 패턴 1 참조
```

## 명령 alias

| 명령 | 설명 |
|------|------|
| `codex e` | `codex exec`의 단축 alias |
| `codex review` | top-level alias (⚠️ `codex exec review`와 다름 — 아래 gotcha §5 참조) |
| `--yolo` | `--dangerously-bypass-approvals-and-sandbox`의 숨은 alias |

대화형 zsh의 `codex` alias가 bypass 플래그를 자동 부착할 수 있다. 예제는 alias를 거치지 않는
`command codex` 또는 `env CODEX_PROGRAMMATIC=1 codex` 형태만 사용한다.

## 호환성 매트릭스

### exec 전용 플래그 (review/resume 미지원)

| 플래그 | 설명 |
|--------|------|
| `-s, --sandbox <SANDBOX_MODE>` | 샌드박스 정책 (read-only, workspace-write, danger-full-access) — review/resume은 미지원 |
| `-C, --cd <DIR>` | 작업 디렉토리 지정 |
| `--add-dir <DIR>` | 추가 쓰기 가능 디렉토리 |
| `--oss` | 오픈소스 프로바이더 |
| `--local-provider <OSS_PROVIDER>` | 로컬 프로바이더 (lmstudio/ollama) |
| `-p, --profile <CONFIG_PROFILE_V2>` | `$CODEX_HOME/<name>.config.toml`을 기본 유저 config 위에 레이어 |
| `--color <COLOR>` | 색상 설정 (always/never/auto) |

### exec · resume image 플래그

| 명령 | 플래그 | 설명 |
|------|--------|------|
| exec | `-i, --image <FILE>...` | 이미지 여러 개 첨부 가능 |
| resume | `-i, --image <FILE>` | 재개 turn에 이미지 한 개 첨부 가능 (0.144.1 help 재확인) |

review에는 image 플래그가 없다.

별도 `codex sandbox` subcommand의 공개 permission-profile 표기는
`-P, --permission-profile <NAME>`이다. `codex exec -s`의 대체 표기가 아니며
`--sandbox-permission-profile`은 0.144.1에서 `unexpected argument`로 거부된다.

### review 전용 플래그

| 플래그 | 설명 |
|--------|------|
| `--uncommitted` | 미커밋 변경 리뷰 |
| `--base <BRANCH>` | 베이스 브랜치 대비 리뷰 |
| `--commit <SHA>` | 특정 커밋 리뷰 |
| `--title <TITLE>` | 리뷰 요약 제목 (scope flag와 조합 가능, 상호 배타 규칙에 미참여. 단독 사용 시 `--commit <SHA>` 필요 — 재확인: 2026-07-10, 0.144.1) |

### exec · review · resume 공통 플래그

| 플래그 | 설명 |
|--------|------|
| `-c, --config <key=value>` | config 오버라이드 |
| `--enable <FEATURE>` | 피처 활성화 |
| `--disable <FEATURE>` | 피처 비활성화 |
| `--strict-config` | 전달한 `-c`뿐 아니라 로드된 config 전체의 미인식 필드를 오류로 처리. capability probe는 `--ignore-user-config --strict-config`로 user config drift를 격리 |
| `-m, --model <MODEL>` | 모델 선택 (생략 권장 — config.toml 기본값 사용) |
| `--output-schema <FILE>` | JSON Schema 출력 형식 — 0.142.5부터 review/resume도 지원 (이전에는 exec 전용) |
| `--dangerously-bypass-approvals-and-sandbox` | 샌드박스 우회 (`--yolo` 숨은 alias) |
| `--dangerously-bypass-hook-trust` | 영속 hook trust 없이 활성 hook 실행 허용 (신규, 0.142.5 — 자동화 전용, 위험) |
| `--skip-git-repo-check` | Git 저장소 체크 건너뜀 |
| `--ephemeral` | 세션 파일 미저장 |
| `--ignore-user-config` | `$CODEX_HOME/config.toml` 로드 차단 (auth만 유지) |
| `--ignore-rules` | user/project execpolicy `.rules` 파일 로드 차단 |
| `--json` | JSONL 이벤트 출력 |
| `-o, --output-last-message <FILE>` | 마지막 메시지 파일 저장. review에서 `-o`·stdout 모두 정상 (0.144.1 실측); upstream #12502의 open 상태와 로컬 동작은 분리 — known-issues.md §2 참조 |

⚠️ 승인(approval) 관련 공개 CLI 플래그는 존재하지 않는다. `exec`/`review`/`resume`은 headless 실행이므로 승인 프롬프트 자체가 불가능하고, approval은 항상 `never`로 고정된다 (재검증 미수행: 0.142.5 기준 서술 유지). 과거 단축 플래그 `--full-auto`는 0.144.1 help에는 없지만 hidden parser가 수용하고 `--sandbox workspace-write` 사용을 안내하는 deprecation warning을 낸다. 새 문서·스크립트에서는 아래 공개 surface를 사용한다:

- `exec`: `-s workspace-write`로 sandbox tier만 지정한다
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

재확인: 2026-07-10, 0.144.1에서 여섯 pairwise 조합 모두 상호 배타 유지. upstream #7825는 closed-as-not-planned이며, 이슈 상태와 runtime 제약을 분리한다.

근본 원인과 상세 분석: [references/known-issues.md](references/known-issues.md) §1

## 입력 방법

programmatic 호출에는 `CODEX_PROGRAMMATIC=1`을 Codex 프로세스에 적용한다. 이 값은 CLI가
자동 주입하지 않는 caller 계약이다 (재확인: 2026-07-10, 0.144.1 환경변수 부재 실측).

| 방법 | 예시 |
|------|------|
| 인라인 문자열 (raw 수동) | `env CODEX_PROGRAMMATIC=1 codex exec -s workspace-write "짧은 질의"` |
| stdin 파이프 (programmatic) | `cat prompt.md \| env CODEX_PROGRAMMATIC=1 codex-exec-supervised -s workspace-write -o result.md -` |
| stdin 마커 (raw review) | `cat prompt.md \| env CODEX_PROGRAMMATIC=1 codex exec review -` |
| 파일 리다이렉트 (raw 수동) | `env CODEX_PROGRAMMATIC=1 codex exec -s workspace-write -o result.md < prompt.md` |
| here-doc (raw 수동) | `env CODEX_PROGRAMMATIC=1 codex exec -s workspace-write <<'EOF' ... EOF` |

PROMPT 인자와 piped stdin을 함께 주면 stdin 내용이 `<stdin>` 블록으로 append된다
(재확인: 2026-07-10, 0.144.1). `-` 마커는 PROMPT 인자의 대체재이므로 다른 PROMPT 인자와
동시에 쓰면 `error: unexpected argument '-' found`로 실패한다.

## 셸 transport 계약

- stdout, stderr, `-o` 결과를 서로 다른 파일에 저장한다. JSON/JSONL parser 앞에서 `2>&1`로
  stderr를 합치면 파싱이 깨진다.
- pipeline에는 `set -o pipefail`을 적용한다. zsh에서 Codex 자체 exit가 필요하면 pipeline 직후
  `codex_rc=$pipestatus[2]`로 보존한다.
- 좌측 명령(`cat` 등)의 실패까지 판정에 포함하려면 pipeline 직후 배열을 먼저 스냅샷한다
  (`pipe_rcs=("${PIPESTATUS[@]}")`; zsh는 `("${pipestatus[@]}")`) — `$?`나 개별 원소를 나중에
  읽으면 그 사이 명령이 PIPESTATUS를 리셋한다.
- `| head`, `| tail`, 뒤이은 `; echo $?`는 원래 exit를 가릴 수 있으므로 판정 경로에 두지 않는다.

```zsh
set -o pipefail
cat prompt.md | env CODEX_PROGRAMMATIC=1 codex-exec-supervised \
  -s workspace-write -o result.md - >stdout.log 2>stderr.log
codex_rc=$pipestatus[2]
```

## 표준 실행 절차

NixOS에서 `-s read-only` / `-s workspace-write`는 bubblewrap 경로를 사용한다. system bwrap 부재 시
bundled fallback과 nested bwrap 기각 결과는 [known-issues.md §16](references/known-issues.md#16-nixos-bwrap-의존)을 참조한다.

### 일반 exec — Claude Code·headless 자동화

프롬프트를 파일로 작성하고, stdin 파이프로 전달하며, `-o`로 결과를 저장한다.
아래 고정 `/tmp` 경로는 단일 수동 실행 데모다 — 동시/병렬 실행은 결과·로그를 서로 덮어쓰므로
세션별 네임스페이스 디렉토리로 격리한다 ([known-issues.md §12](references/known-issues.md#12-동시-다중-세션-간-tmpda--경쟁-상태);
경로 격리 시 임의 suffix의 literal 재사용 규칙은 [#632 절](references/known-issues.md#literal-재사용-시-random-suffix-환각-금지-issue-632)을 따른다):

```bash
cat > /tmp/prompt.md <<'PROMPT'
이 변경의 배포 리스크를 3개 이내로 지적한다.
PROMPT
```

⚠️ `run_in_background` 환경: 여기서 Bash tool 호출을 종료하고, 아래를 별도 호출로 실행한다 ([§11](references/known-issues.md) 하위 항목).

```bash
# marker must apply to `codex`, not `cat` (issue #585): Codex 0.124+ user-level hooks의 early-exit 신호.
rm -f /tmp/result.md   # 이전 실행의 non-empty 잔존 결과로 인한 오판 방지
set -o pipefail
cat /tmp/prompt.md | env CODEX_PROGRAMMATIC=1 codex-exec-supervised \
  -s workspace-write -o /tmp/result.md - \
  > /tmp/stdout.log 2> /tmp/stderr.log
# PIPESTATUS는 다음 명령에서 리셋되므로 배열을 먼저 스냅샷한다. cat 실패(프롬프트 파일 부재)도 판정에 포함.
pipe_rcs=("${PIPESTATUS[@]}")   # zsh는 ("${pipestatus[@]}") — 인덱스가 1부터
[ "${pipe_rcs[0]}" -eq 0 ] && [ "${pipe_rcs[1]}" -eq 0 ] && test -s /tmp/result.md \
  && ! grep -q "ERROR:" /tmp/stderr.log   # 성공 계약 조건 2 (CLI 오류의 ERROR: prefix 검사)
```

사용자가 literal raw 실행을 요청한 1회성 수동 진단에서는 인라인 프롬프트도 가능하다:

```bash
env CODEX_PROGRAMMATIC=1 codex exec -s workspace-write "git diff 기준으로 회귀 가능성 한 줄 요약"
```

### 코드 리뷰 — scope flag만 사용 (Claude Code·headless 자동화)

아래 세 명령은 순차 실행하는 파이프라인이 아니라 scope별 택일 대안이다.
선택한 하나만 실행하고, 실행 전 결과 파일을 초기화하며, 종료 후 성공 계약을 검증한다:

```bash
rm -f /tmp/review.md   # 이전 실행의 잔존 결과로 인한 오판 방지

# 셋 중 하나를 선택:
env CODEX_PROGRAMMATIC=1 codex-exec-supervised review --base main \
  -o /tmp/review.md > /tmp/review-stdout.log 2> /tmp/review-stderr.log
# env CODEX_PROGRAMMATIC=1 codex-exec-supervised review --uncommitted ... (동일 형태)
# env CODEX_PROGRAMMATIC=1 codex-exec-supervised review --commit <sha> ... (동일 형태)

review_rc=$?
[ "$review_rc" -eq 0 ] && test -s /tmp/review.md \
  && ! grep -q "ERROR:" /tmp/review-stderr.log
```

stderr 검사는 성공 계약 조건 2의 구현이다 — usage limit·sandbox panic 등 CLI 오류는
`ERROR:` prefix로 출력된다 (진행 로그·배너에는 이 prefix가 없다). stderr에는 최종 메시지
사본도 남으므로, 본문에 우연히 `ERROR:`가 포함되면 보수적으로 실패 처리하고 직접 확인한다.

review 결과 저장에는 `-o`(`--output-last-message`)와 stdout이 모두 동작한다
(재확인: 2026-07-10, 0.144.1). upstream #12502는 open이지만 로컬에서는 stderr 회귀가
재현되지 않았다. 이슈 상태와 로컬 동작은 [known-issues.md §2](references/known-issues.md)를 참조한다.

### 코드 리뷰 — 커스텀 지시 필요

PROMPT과 scope flag이 상호 배타이므로, 두 가지 대안 중 선택한다:

방법 A — AGENTS.md 활용 (영구 지시, review diff 스코핑 유지)

프로젝트 `AGENTS.md` 또는 `~/.codex/AGENTS.override.md`에 리뷰 정책을 배치한 뒤,
scope flag으로 review를 실행하면 지시가 자동 적용된다.
(지시 파일 우선순위: [references/patterns.md](references/patterns.md) 패턴 3 참조)

재검증 미수행 (0.142.5 기준 서술 유지): AGENTS instruction의 실제 적용과 우선순위.
재검증 방법: 임시 repo의 `AGENTS.md`에 고유 marker 지시(예: "리뷰 결과 첫 줄에 AGENTS_APPLIED를 출력")를 넣고
`codex exec review --uncommitted`를 실행해 결과에 marker가 반영되는지 확인한다.

방법 B — exec 우회 (1회성 지시, 최대 유연성)

`codex exec` (review 미사용)에 `git diff` 출력과 커스텀 지시를 프롬프트로 직접 전달한다.
`-o`로 결과 저장이 가능하고, 프롬프트 내용을 자유롭게 구성할 수 있다.

상세 명령과 예제: [references/patterns.md](references/patterns.md) 패턴 3, 4

### 세션 재개

Claude Code/headless의 programmatic 재개는 supervised 경로를 사용한다:

```bash
SESSION="<session-id>"   # 재개할 세션 id
rm -f /tmp/resume-result.md
env CODEX_PROGRAMMATIC=1 codex-exec-supervised resume "$SESSION" \
  -o /tmp/resume-result.md > /tmp/resume-stdout.log 2> /tmp/resume-stderr.log
resume_rc=$?

# silent fallback 검증: 반환된 session id가 요청한 세션과 일치해야 하며, 최종 판정에 연결한다.
[ "$resume_rc" -eq 0 ] \
  && grep -Fq "session id: $SESSION" /tmp/resume-stderr.log \
  && ! grep -q "ERROR:" /tmp/resume-stderr.log \
  && test -s /tmp/resume-result.md
# 위 판정 실패, 또는 응답(/tmp/resume-result.md)이 원 세션의 context를 잇지 않으면 재개 실패로 처리한다.
```

변형: `resume --last` (같은 cwd의 마지막 세션), `resume --last --all` (cwd 필터 해제).
사용자가 요청한 1회성 수동 진단은 alias를 피하도록 raw `command codex exec resume --last`를 사용할 수 있다.

`--ephemeral` 세션은 저장되지 않는다. 0.144.1에서 저장 세션이 없는 cwd의
`resume --last`는 오류 대신 새 session id로 조용히 시작해 exit 0을 반환했다 — 위 예제가
session id·응답 context 확인을 포함하는 이유다. 불일치하거나 결과가 비면 재개 실패로 처리한다.

## 성공 계약

프로세스 exit만으로 업무 성공을 판정하지 않는다. 아래 네 조건을 모두 확인한다.

1. wrapper/CLI exit가 0이다.
2. stderr에 timeout, usage limit, sandbox denial, unsupported model 오류가 없다
   (구현: `! grep -q "ERROR:" <stderr>` — CLI 오류는 `ERROR:` prefix로 출력되고 진행 로그·배너에는 없다).
3. 기대 산출물이 존재하고 비어 있지 않다: `test -s "$RESULT"`.
4. 반복 라운드라면 직전 결과 대비 새 finding·수정·판정 같은 진척 delta가 있다.

완료 표식을 요구한 작업은 결과 본문에도 그 표식이 있어야 한다. 진척 없는 pass가 연속되면 circuit
breaker로 중단하고 같은 호출을 증식시키지 않는다. fan-out은 패턴 8 스모크를 한 번 통과한 뒤 시작한다.

| 분류 | 신호 | 처리 |
|------|------|------|
| wrapper 사전 검증 실패 / PATH 미해석 | `command -v codex` 실패 또는 exit 127 | wrapper 127은 PATH 외에 invalid env 값·정본 `CODEX_EXEC_*` 변수명 near-miss도 포함하므로 stderr를 먼저 읽는다. 이후 `command -v codex` → `codex-exec-supervised --check` → 확인된 절대경로 순으로 진단. 설치 부재로 단정하지 않는다. |
| 부모 sandbox denial | session/config 파일 쓰기 거부, nested 실행 | 소유권 변경 없이 [known-issues.md §18](references/known-issues.md#18-중첩-codex-session-파일-쓰기-거부와-sudo-chown-오진)로 분기 |
| timeout | wrapper exit 124/137 | stderr·프로세스 정리를 확인한 뒤 fresh retry 1회만 허용 |
| usage limit | usage/rate limit 명시 | 신규 세션 재시도는 무익하므로 fail-fast. 이미 진행 중인 세션은 계속될 수 있음 |
| unsupported model | metadata warning 또는 unsupported error | `-m`을 제거하고 config 기본 모델로 제한된 fresh retry |
| exit 0 + 산출물 없음 | `test -s` 실패 | 실패로 처리하고 stderr·라우팅·resume session id를 조사 |

### foreground/background 상한 불일치 (호출 방식 계약)

wrapper 기본 timeout 1800초는 호출 방식과 무관한 wrapper의 운영 budget이지만, Claude Code 하네스의 Bash tool을 경유하는 foreground 호출에서는 이 budget에 도달하지 못한다 — 상한은 세션 유형이 아니라 하네스 속성이라 대화형 세션과 `claude -p` headless에 공통 적용되며, Bash tool의 foreground 대기 상한이 기본 120초, `timeout` 파라미터 명시 시 최대 600초(10분)라 하네스가 먼저 프로세스를 끊는다 (`Exit code 143 / Command timed out` — 2026-07-10 실사례: Arbiter foreground 실행이 10분에 잘리고 background 재실행으로 8분 34초 만에 성공). 수 분 이상 걸릴 수 있는 programmatic 호출은 background로 실행하고, foreground가 꼭 필요하면 Bash tool `timeout` 파라미터를 반드시 명시하되 wrapper budget이 아니라 하네스 상한이 실질 상한임을 전제한다. run-da의 role별·하네스별 발사 방식은 run-da 스킬 `references/arbiter-scaling.md`의 실행 계약이 소유하며, 본 절은 그 계약이 참조하는 하네스 상한 사실의 정본이다.

## Gotchas

1. `--search`는 exec에서 미동작: `error: unexpected argument '--search' found`. 대안 config key `-c web_search=live`는 strict config 검증을 통과했으나 실제 tool 제공은 재검증 미수행 (2026-07-10, 0.144.1).
2. `--full-auto`는 0.144.1 help에서 숨겨졌지만 parser가 수용하고 deprecation warning을 낸다. 새 호출은 `-s workspace-write`를 사용한다. 명시한 `-s` 값이 `config.toml`의 `sandbox_mode`를 override한다 (2026-07-03, 0.142.5 실측: `-s read-only` 지정 시 config가 `danger-full-access`여도 read-only로 실행됨; 0.144.1 재검증 미수행).
3. CODEX_API_KEY는 exec 전용: interactive TUI와 VS Code extension에서는 무시됨. OPENAI_API_KEY는 auth 체인에 미참여 (TUI prefill 전용). 우선순위: CODEX_API_KEY > ephemeral tokens > auth.json. 재검증 미수행 (0.142.5 기준 서술 유지; 상세: [known-issues.md §17](references/known-issues.md#17-exec-auth-chain-우선순위와-login-status-한계))
4. ephemeral resume silent fallback: `--ephemeral` 원본은 저장되지 않으며, 저장 세션이 없는 cwd의 `resume --last`는 0.144.1에서 오류 대신 새 세션을 시작하고 exit 0을 반환했다. session id와 응답 context로 판정한다.
5. `codex review` (top-level) vs `codex exec review`: 전자는 `-m`, `--json`, `-o`, `--output-schema`, `--ephemeral`, `-s/--sandbox` 등 미지원 (재확인: 2026-07-10, 0.144.1 help). 비대화형 자동화에는 반드시 `codex exec review` 사용
6. Bash tool sandbox에서 `&` + `$!` 미작동: Claude Code의 Bash tool에서 background process PID 캡처(`$!`)가 리터럴 문자열로 반환됨. shell-level 병렬 대신 여러 병렬 Bash tool 호출 + supervised stdin pipe를 사용한다. 이 제약은 Codex 세션의 native subagent 경로에는 적용되지 않는다. 재검증 미수행 (0.142.5 기준 서술 유지; 상세: [known-issues.md](references/known-issues.md) §11)
7. stdin pipe로 stdin hang 방지: `cat file | env CODEX_PROGRAMMATIC=1 codex-exec-supervised ... -`로 EOF를 보장한다. `Reading additional input...` banner 하나만으로 hang이라 단정하지 말고, banner + 무진척 + 결과 미생성을 함께 확인한다. 상세: [known-issues.md](references/known-issues.md) §14
8. `-c hooks.*` inline override는 stdin과 독립적으로 hang을 유발한 실측 축이다. programmatic 호출에서 제거하고 [known-issues.md §15](references/known-issues.md#15-codex-exec-supervised-wrapper로-14-위에-timeout-budget-한계-보강-issue-593)의 supervisor·timeout 계약을 적용한다.
9. codex exec `--json`은 multi-agent spawn/child 이벤트를 노출하지 않는다 (관측성 한계, 0.144.1). `collaboration.spawn_agent`는 실제로 작동해 child를 생성·실행하지만, 공개 `--json`에는 `tool:"wait"` 이벤트만 보이고 그 `receiver_thread_ids`가 `[]`다 — 이를 spawn 실패로 오판하지 마라 (child가 이미 실행됐을 수 있어 재시도 시 중복 실행). 실제 spawn 여부는 `~/.codex/sessions`의 persisted rollout(`spawn_agent`/`sub_agent_activity`/`inter_agent_communication_metadata`)으로 확인한다. 상세·재검증 probe(버전 변화 시 재확인): [known-issues.md §19](references/known-issues.md#19-codex-exec---json이-multi-agent-spawnchild-이벤트를-노출하지-않음-관측성-한계)

## 모델 사용 원칙

- 기본 모델: `~/.codex/config.toml`의 `model` 값을 따른다.
- 리뷰 전용 모델: `review_model` 설정으로 분리 가능하다.
- 모델/review_model runtime과 unsupported-model exact response는 재검증 미수행 (0.142.5 기준 서술 유지).
- 실무 원칙:
  1. `-m`을 생략하고 기본 모델을 사용한다.
  2. `model is not supported` 오류 시 `-m`을 제거하고 재시도한다.
  3. 모델명을 매번 다르게 혼용하지 않는다.

## 운영 체크리스트

실행 전:
- `command -v codex`로 비대화형 PATH를 확인하고, programmatic 경로는 `command -v codex-exec-supervised && codex-exec-supervised --check`까지 통과
- `command codex --version`으로 기대 버전 확인
- `pwd`가 대상 저장소 루트인지 확인
- 프롬프트 파일 경로와 결과 파일 경로를 분리
- fan-out 전 패턴 8 스모크 1회 통과

실행 후:
- CLI/wrapper exit 보존 및 확인
- stderr에 `ERROR:` prefix가 없는지 확인 (성공 계약 조건 2)
- 결과 파일이 비어 있지 않은지 확인 (`test -s "$RESULT"`)
- 빈 결과 시 stderr 로그부터 확인
- 반복 작업이면 직전 결과 대비 진척 delta 확인

## 하지 말아야 할 패턴

| 금지 패턴 | 발생 에러 | 올바른 대안 |
|-----------|----------|------------|
| review에서 PROMPT + scope flag | `'[PROMPT]' cannot be used with '--base'` | 의사결정 트리의 방법 A 또는 B |
| exec 전용 플래그를 review에 전달 | `unexpected argument` | exec 전용/공통 매트릭스 확인 |
| PROMPT 인자와 `-` 마커 동시 사용 | `unexpected argument '-'` | PROMPT 또는 stdin marker 중 하나만 선택 |
| `--ephemeral` 뒤 `resume --last`의 exit 0을 재개 성공으로 간주 | 새 세션 silent fallback | session id와 응답 context 확인 |
| programmatic 호출에 raw `codex exec` 사용 | hang/자식 프로세스 잔존 | 실행 경로 게이트의 supervised wrapper 사용 |
| `-c hooks.*` inline override | stdin과 무관한 silent hang 가능 | override 제거 + §15 supervisor 적용 |
| JSON parser 앞 `2>&1` | stderr 혼입으로 JSON 파싱 실패 | stdout/stderr/result 분리 |
| 판정 pipeline 끝에 `head`/`tail`/`; echo $?` | 원 exit 은폐 | `pipefail`과 즉시 exit 보존 |
| `-m o3` / `-m o4-mini` 등 비Codex 모델 지정 | "Model metadata not found" + "model is not supported" | `-m` 생략, config.toml 기본 모델 사용 |
| `-m` 플래그로 매번 다른 모델 지정 | 불일치/에러 위험 | config.toml 기본값 사용 원칙 |
| 실패 원인 미확인 후 반복 재시도 | 동일 에러 반복 | known-issues.md 진단 절차 |
| 긴 루프에서 결과 파일 저장 생략 | 결과 유실 | `-o` 또는 리다이렉트 필수 사용 |
| child가 같은 collector/fan-out을 다시 생성 | 무한 자기증식 | 오케스트레이션은 부모 1계층에서만 수행 |
| 공개 exec `--json`의 빈 `receiver_thread_ids`를 spawn 실패로 판정 | `wait` 이벤트 필드일 뿐 — child는 실행됐을 수 있어 오판·중복 실행 | persisted rollout에서 `spawn_agent` 확인 ([known-issues.md §19](references/known-issues.md#19-codex-exec---json이-multi-agent-spawnchild-이벤트를-노출하지-않음-관측성-한계)) |

## 참조

- 상황별 실행 패턴: [references/patterns.md](references/patterns.md)
- 제한사항/트러블슈팅: [references/known-issues.md](references/known-issues.md)

문서와 CLI 동작이 다를 때는 CLAUDE.md의 "스킬 문서 불일치 시 행동 원칙"을 따른다.
help는 공개 surface의 SSOT다. help에서 사라진 hidden flag의 제거 여부는 실행 smoke로만 판정한다.
문서에서 명령 문자열을 찾을 때는 command substitution을 피하도록 `rg -F 'codex exec'`처럼
작은따옴표와 fixed-string 검색을 사용한다.
