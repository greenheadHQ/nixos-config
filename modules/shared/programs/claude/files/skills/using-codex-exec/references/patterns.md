# using-codex-exec 상황별 실행 패턴

각 패턴은 Claude Code/headless programmatic 경로를 기본으로 하며 Layer 1
`codex-exec-supervised`를 사용한다. Direct Codex fan-out은 native subagent가 기본이고, 사용자가
literal raw 실행을 요청한 경우에만 `env ... codex exec`로 wrapper를 대체한다.

> ⚠️ Bash tool은 zsh에서 실행됨. bash 전용 문법(간접 확장, case modification 등) 사용 금지 — 상세 규칙은 repo 루트 `CLAUDE.md` "Bash tool 환경" 섹션 참조.

모든 예제는 stdout, stderr, `-o` 결과를 분리한다. JSON/JSONL parser 앞 `2>&1`, 판정 pipeline의
`head`/`tail`, 원 exit를 가리는 후속 `echo $?`를 금지한다. pipeline은 `set -o pipefail`과 zsh
`pipestatus`로 Codex exit를 보존한다.

## 패턴 1: 기본 exec — 파일 프롬프트 → 결과 저장

가장 기본적인 실행 패턴. 프롬프트를 파일로 작성하고 stdin 파이프로 전달한다.

```bash
cat > /tmp/codex-prompt.md <<'PROMPT'
이 저장소의 현재 변경에서 운영 리스크를 3개 이내로 지적하고,
각 항목마다 재현 조건을 한 줄씩 적는다.
PROMPT
```

⚠️ `run_in_background` 환경: 여기서 Bash tool 호출을 종료하고, 아래를 별도 호출로 실행한다 ([known-issues.md §11](known-issues.md) 하위 항목).

```zsh
# marker must apply to `codex`, not `cat` (issue #585): Codex 0.124+ user-level hooks의 early-exit 신호.
set -o pipefail
cat /tmp/codex-prompt.md | env CODEX_PROGRAMMATIC=1 codex-exec-supervised \
  -s workspace-write -o /tmp/codex-result.md - \
  > /tmp/codex.stdout 2> /tmp/codex.stderr
codex_rc=$pipestatus[2]
test "$codex_rc" -eq 0 && test -s /tmp/codex-result.md
```

핵심 요소:
- `-o`: 마지막 에이전트 메시지를 파일로 저장. 루프 연동 시 필수.
- stderr: 별도 파일로 캡처하여 실패 원인을 추적.
- stdin pipe 패턴: pipe EOF가 stdin을 닫아 background 전환 시 hang을 방지한다. `< /dev/null`은 불필요하고, marker는 Codex 프로세스에 적용한다 (issue #585).
- 인라인 프롬프트(`env CODEX_PROGRAMMATIC=1 codex exec ...`)는 literal raw 수동 실행의 짧은 질의에만 사용.

## 패턴 2: 코드 리뷰 — scope flag만 사용 (커스텀 지시 불필요)

리뷰 대상을 scope flag으로 지정한다. 커스텀 지시가 필요 없는 경우.

### 브랜치 비교

```bash
env CODEX_PROGRAMMATIC=1 codex-exec-supervised review --base main \
  -o /tmp/review.md > /tmp/review.stdout 2> /tmp/review.stderr
test -s /tmp/review.md
```

현재 브랜치를 `main`과 비교하여 리뷰한다.

### 미커밋 변경

```bash
env CODEX_PROGRAMMATIC=1 codex-exec-supervised review --uncommitted \
  -o /tmp/review.md > /tmp/review.stdout 2> /tmp/review.stderr
test -s /tmp/review.md
```

staged/unstaged/untracked 변경을 함께 리뷰한다. 커밋 전 self-review에 적합.

### 특정 커밋

```bash
env CODEX_PROGRAMMATIC=1 codex-exec-supervised review --commit abc1234 \
  -o /tmp/review.md > /tmp/review.stdout 2> /tmp/review.stderr
env CODEX_PROGRAMMATIC=1 codex-exec-supervised review --commit abc1234 --title "Fix sandbox leak" \
  -o /tmp/review.md > /tmp/review.stdout 2> /tmp/review.stderr
test -s /tmp/review.md
```

`--title`은 `--commit`과 함께 사용하여 리뷰 요약에 커밋 제목을 표시한다.
각 호출은 exit 0과 `test -s /tmp/review.md`를 모두 통과해야 성공이다.

### 주의사항

- `-o`와 stdout 모두 정상: 0.144.1 로컬 실측에서 두 채널에 review가 기록됐다. upstream #12502는 open이지만 로컬 미재현 (재확인: 2026-07-10, known-issues.md §2).
- PROMPT 금지: scope flag과 PROMPT은 상호 배타. 자세한 내용은 SKILL.md 호환성 매트릭스 참조.

## 패턴 2b: stdin PROMPT로 review

scope flag 없이 PROMPT을 stdin으로 전달하여 review를 실행한다.

```bash
cat prompt.md | env CODEX_PROGRAMMATIC=1 codex-exec-supervised review \
  -o /tmp/result.md - > /tmp/result.stdout 2> /tmp/result.stderr
test -s /tmp/result.md
```

> ⚠️ scope flag 미사용: PROMPT 사용 시 scope flag(`--uncommitted`/`--base`/`--commit`)와
> 상호 배타이므로 내장 scope flag의 정밀한 diff 스코핑이 적용되지 않는다.
> review 세션이 자체적으로 diff를 참조할 수 있지만, 어떤 diff가 대상인지는 보장되지 않는다.
> 정밀한 브랜치/커밋 기준 리뷰가 필요하면 패턴 2 (scope flag) 또는 패턴 4 (exec 우회)를 사용한다.

## 패턴 3: 커스텀 리뷰 — AGENTS.md 활용 (영구 지시)

사용 조건: 프로젝트 전체에 일관된 리뷰 정책을 적용하고 싶을 때.

AGENTS.md에 리뷰 지시를 배치하면, review 실행 시 Codex가 자동으로 읽어서 적용한다.
scope flag의 diff 스코핑 기능을 그대로 유지할 수 있다.

### 단계

1. 프로젝트 루트에 리뷰 정책을 작성한다:

```bash
cat >> AGENTS.md <<'EOF'

## Code Review Policy
- 회귀/사이드이펙트 발생 여부를 최우선으로 검토한다.
- style 코멘트는 제외한다.
- 각 지적마다 재현 조건과 영향 범위를 명시한다.
- 기존 코드의 버그가 아닌, 이번 변경으로 도입된 문제만 지적한다.
EOF
```

2. scope flag으로 리뷰를 실행한다:

```bash
env CODEX_PROGRAMMATIC=1 codex-exec-supervised review --base main \
  -o /tmp/review.md > /tmp/review.stdout 2> /tmp/review.stderr
test -s /tmp/review.md
```

### 전역 정책 (모든 프로젝트에 적용)

`~/.codex/AGENTS.override.md`에 작성하면 모든 Codex 작업에 적용된다.
review뿐 아니라 모든 exec 실행에도 영향을 주므로 주의한다.

### Codex 지시 파일 우선순위

```
AGENTS.override.md > AGENTS.md > TEAM_GUIDE.md > .agents.md
```

디렉토리 트리 깊은 곳의 파일이 상위를 오버라이드한다.

재검증 미수행 (0.142.5 기준 서술 유지): AGENTS instruction의 실제 적용과 깊이별 우선순위.

## 패턴 4: 커스텀 리뷰 — exec 우회 (1회성 지시)

사용 조건: 이번 한 번만 특정 관점으로 리뷰하고 싶을 때.

review 서브커맨드를 사용하지 않고, `codex exec`에 diff와 커스텀 지시를 직접 전달한다.

### 기본 형태

```bash
cat > /tmp/review-prompt.md <<PROMPT
아래 diff를 리뷰한다. 회귀/사이드이펙트에 집중하고, style 코멘트는 제외한다.
각 지적마다 재현 조건을 명시한다.

$(git diff main...HEAD)
PROMPT
```

⚠️ `run_in_background` 환경: 여기서 Bash tool 호출을 종료하고, 아래를 별도 호출로 실행한다. diff가 클 수 있으므로 stdin pipe를 사용한다.

```bash
cat /tmp/review-prompt.md | env CODEX_PROGRAMMATIC=1 codex-exec-supervised \
  -s workspace-write -o /tmp/review-result.md - \
  > /tmp/review.stdout 2> /tmp/review.stderr
test -s /tmp/review-result.md
```

### 미커밋 변경 리뷰

```bash
cat > /tmp/review-prompt.md <<PROMPT
아래 diff를 리뷰한다. 보안 취약점과 회귀에 집중한다.

$(git diff)
$(git diff --cached)
PROMPT
```

```bash
cat /tmp/review-prompt.md | env CODEX_PROGRAMMATIC=1 codex-exec-supervised \
  -s workspace-write -o /tmp/review-result.md - \
  > /tmp/review.stdout 2> /tmp/review.stderr
test -s /tmp/review-result.md
```

### 장점

- `-o`로 결과 저장 가능 (0.144.1에서는 review 서브커맨드도 정상 — 패턴 2 참조).
- 프롬프트 내용을 완전히 자유롭게 구성 가능.
- `--output-schema`와 조합하여 구조화된 JSON 출력도 가능.

### heredoc 따옴표 주의 + 코드 블록 분리

이 패턴에서는 `<<PROMPT` (따옴표 없음)를 사용하여 `$(git diff ...)` 명령 치환이 실행되도록 한다.
리터럴 텍스트만 전달할 때는 `<<'PROMPT'` (따옴표 포함)를 사용한다.
패턴 1, 5, 8은 명령 치환이 불필요하므로 `<<'PROMPT'`를 사용한다.

코드 블록 분리: `run_in_background` 환경에서 heredoc과 codex exec를 같은 Bash 호출에 넣으면 stdin hang이 발생한다 ([known-issues.md §11](known-issues.md) 하위 항목 참조). 모든 패턴에서 heredoc(프롬프트 생성)과 codex exec(실행)를 별도 코드 블록으로 분리한다. 실행 블록에서는 supervised stdin pipe를 사용한다.

### 단점

- review 서브커맨드의 내장 diff 스코핑/프롬프트 템플릿을 사용하지 못한다.
- diff가 큰 경우 프롬프트 크기 제한에 걸릴 수 있다.

## 패턴 5: Devil's Advocate 피드백 루프

프롬프트 → 실행 → 결과 분석 → 수정 → 재실행을 반복하는 루프 패턴.

### 1라운드

```bash
cat > /tmp/da-round1.md <<'PROMPT'
You are a Devil's Advocate reviewer.
Find only real risks in the current changes and rank by severity.
Ignore style-only issues.
PROMPT
```

⚠️ `run_in_background` 환경: 여기서 Bash tool 호출을 종료하고, 아래를 별도 호출로 실행한다. DA 루프에서는 supervised stdin pipe를 사용한다.

```bash
cat /tmp/da-round1.md | env CODEX_PROGRAMMATIC=1 codex-exec-supervised -s workspace-write -o /tmp/da-round1-result.md \
  - > /tmp/da-round1-stdout.log 2>/tmp/da-round1-stderr.log
test -s /tmp/da-round1-result.md && cat /tmp/da-round1-result.md
```

### 후속 라운드

1. 결과를 Arbiter 에이전트에 전달하여 독립 판정을 받는다 (run-da 스킬의 Arbiter 절차 참조).
   이 패턴은 codex exec 실행 기계만 제공한다. 유효성 판정은 Arbiter의 책임이다.
   기본 `run-da` 경로는 4 reviewer bundle을 쓰며, Arbiter/다음 라운드에는
   unique findings, conflicting findings, high-severity findings, user decision required findings만 selective propagation한다.
2. Arbiter가 CONFIRMED_ISSUE로 판정한 항목만 수정한다.
3. 새 프롬프트 파일(`round2.md`)로 동일 구조를 반복한다:

```bash
cat > /tmp/da-round2.md <<'PROMPT'
현재 변경사항을 독립적으로 리뷰한다.
이전 라운드의 판정 결과를 참조하지 마라.
PROMPT
```

```bash
cat /tmp/da-round2.md | env CODEX_PROGRAMMATIC=1 codex-exec-supervised -s workspace-write -o /tmp/da-round2-result.md \
  - > /tmp/da-round2-stdout.log 2>/tmp/da-round2-stderr.log
test -s /tmp/da-round2-result.md
```

핵심: 매 라운드마다 `-o`로 결과를 파일 저장하여 이력을 보존한다.
이전 라운드 결과를 후속 프롬프트에 포함하지 않는다 (프롬프트 조향 금지).
각 라운드는 `test -s`와 직전 라운드 대비 진척 delta를 확인한다. 진척 없는 pass가 연속되면
circuit breaker로 중단하며 child가 같은 collector를 다시 생성하게 하지 않는다.

## 패턴 6: 구조화 출력 — --output-schema

JSON Schema를 지정하여 구조화된 리뷰 결과를 받는다. CI/CD 파이프라인 연동에 적합.

```bash
cat > /tmp/review-schema.json <<'SCHEMA'
{
  "type": "object",
  "properties": {
    "findings": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "title": { "type": "string" },
          "body": { "type": "string" },
          "severity": { "type": "string", "enum": ["critical", "high", "medium", "low"] },
          "file_path": { "type": "string" },
          "line_range": { "type": "string" }
        },
        "required": ["title", "body", "severity"]
      }
    },
    "summary": { "type": "string" }
  },
  "required": ["findings", "summary"]
}
SCHEMA
```

```bash
cat > /tmp/review-prompt.md <<PROMPT
아래 diff를 리뷰하고, 결과를 지정된 스키마에 맞춰 출력한다.

$(git diff main...HEAD)
PROMPT
```

⚠️ `run_in_background` 환경: 여기서 Bash tool 호출을 종료하고, 아래를 별도 호출로 실행한다. diff가 클 수 있으므로 stdin pipe를 사용한다.

```bash
rm -f /tmp/review-structured.json   # 이전 실행의 유효 JSON 잔존이 성공 오판을 만든다
set -o pipefail
cat /tmp/review-prompt.md | env CODEX_PROGRAMMATIC=1 codex-exec-supervised -s workspace-write --output-schema /tmp/review-schema.json \
  -o /tmp/review-structured.json - > /tmp/schema.stdout 2> /tmp/schema.stderr
pipe_rcs=("${pipestatus[@]}")   # zsh 1-base. bash는 ("${PIPESTATUS[@]}") + 0-base
[ "${pipe_rcs[1]}" -eq 0 ] && [ "${pipe_rcs[2]}" -eq 0 ] \
  && test -s /tmp/review-structured.json \
  && jq -e '.findings and .summary' /tmp/review-structured.json > /dev/null
# rc가 정본이고 내용 검사는 그다음이다 — non-empty만으로는 부족하다(코드 펜스 혼입·스키마
# 정의($schema)가 인스턴스 대신 반환된 실측). 실행 전 결과 파일 초기화까지 해야 이전 실행의
# 산출물로 이번 실패가 성공으로 뒤집히지 않는다 (SKILL.md 성공 계약 조건 1·2).
```

주의: `--output-schema`는 exec/review/resume help에 모두 있다 (재확인: 2026-07-10,
0.144.1). 실제 schema-conforming output은 재검증 미수행 (0.142.5 기준 서술 유지).

## 패턴 7: JSONL 이벤트 스트림

자동화 파서와 연결하거나 실행 과정을 기록할 때 사용한다.

```bash
cat /tmp/prompt.md | env CODEX_PROGRAMMATIC=1 codex-exec-supervised \
  -s workspace-write --json - > /tmp/events.jsonl 2> /tmp/events.stderr
```

주요 이벤트 타입:
- `thread.started` / `turn.started` / `turn.completed` / `turn.failed`
- `item.completed` (에이전트 메시지)

이 event 종류와 `--json + -o` 병용 결과는 재검증 미수행 (0.142.5 기준 서술 유지).

최종 요약문을 파일로도 보존하려면 `-o`를 별도로 함께 사용한다:

```bash
cat /tmp/prompt.md | env CODEX_PROGRAMMATIC=1 codex-exec-supervised \
  -s workspace-write --json -o /tmp/result.md - \
  > /tmp/events.jsonl 2> /tmp/events.stderr
test -s /tmp/result.md
```

## 패턴 8: 스모크 테스트

실행 환경 점검용 최소 예제. 실패가 반복될 때 이 명령으로 기본 동작을 먼저 확인한다.

```bash
cat > /tmp/smoke.md <<'PROMPT'
현재 디렉토리 기준으로 가장 중요한 리스크 1개만 한 줄로 답하고,
마지막 줄에 SMOKE_COMPLETE를 출력한다.
PROMPT
```

⚠️ `run_in_background` 환경: 여기서 Bash tool 호출을 종료하고, 아래를 별도 호출로 실행한다 ([known-issues.md §11](known-issues.md) 하위 항목).

```zsh
rm -f /tmp/smoke-result.md /tmp/smoke.stdout /tmp/smoke.stderr
set -o pipefail
cat /tmp/smoke.md | env CODEX_PROGRAMMATIC=1 codex-exec-supervised \
  -s workspace-write -o /tmp/smoke-result.md - \
  > /tmp/smoke.stdout 2> /tmp/smoke.stderr
codex_rc=$pipestatus[2]
test "$codex_rc" -eq 0 && test -s /tmp/smoke-result.md
rg -q '^SMOKE_COMPLETE$' /tmp/smoke-result.md
```

성공 기준:
- wrapper/CLI exit가 0이다.
- 결과 파일이 생성되고 비어 있지 않다 (`test -s`).
- 요청한 완료 표식이 결과에 있다 (`rg -q '^SMOKE_COMPLETE$'`).
- 위 판정이 실패했을 때만 stderr를 원인 분류에 사용한다
  ([known-issues.md §0-1](known-issues.md#0-1-stderr-원인-분류-절차) — `ERROR:` grep은 판정이 아니다).

fan-out 전에 이 패턴을 1회 필수 실행한다. 통과하면 기존 복잡한 프롬프트로 단계적으로 복귀한다.

## 패턴 9: 임시 cwd 격리 실행

repo 밖 scratch 디렉토리에서 실행할 때의 표준 세트. 넷 중 하나라도 빠지면 각기 다른 실패가 난다
(`--skip-git-repo-check` 누락 시 rc 1 즉사 — SKILL.md gotcha 10):

```bash
# 프리플라이트: 게이트와 동일한 판별식. -C를 쓰면 판정 대상은 셸 cwd가 아니라 -C 값이다.
git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || SKIP_FLAG=--skip-git-repo-check

cat "$PROMPT" | env CODEX_PROGRAMMATIC=1 codex-exec-supervised \
  --sandbox read-only --ignore-user-config --ignore-rules --ephemeral ${SKIP_FLAG:-} \
  -C "$DIR" -c model_reasoning_effort="medium" -o "$OUT" -
```

- `--ignore-user-config`와 `--ignore-rules`는 항상 쌍으로 쓴다 (user config·execpolicy 격리).
- `--ignore-user-config`는 config 유래 기본값(effort 등)도 차단하므로 `-c`로 명시한다
  (known-issues §17 인접 서술 참조).
- `--skip-git-repo-check` 과부착(이미 git repo인 곳)은 무해하다 — 게이트만 꺼진다.
- review에는 `-C`가 없다 (exec 전용).

## 패턴 10: in-progress 판정 (예외적 진단 수단)

기본 원칙은 그대로다 — background 실행 후 sleep/poll로 완료를 확인하지 않는다 (완료 알림이
자동으로 온다). 아래 폴링 지표는 알림 부재·사용자 질의·foreground timeout 등 예외적 진단
상황에서만 쓴다:

- `-o` 결과 파일은 프로세스 종료 직전에야 최초 생성된다 (known-issues §11 3b) —
  실행 중 부재는 실패 신호가 아니다.
- liveness 양성 신호: 두 시점 샘플에서 stderr 파일 크기·mtime이 전진하면 살아 있는 것이다.
- 역은 성립하지 않는다 — 무전진 단독으로 사망 판정 금지 (정상 실행 중 수 분 정체 실측).
  사망 판정은 프로세스 생존 확인과 결합한다: 경로 sentinel 전체 매칭
  (`pgrep -f "$DIR"` 또는 `ps -eo pid,etime,command | grep -F "$DIR"`)을 쓰고,
  `pgrep -f 'codex exec'` 같은 명령어 패턴 매칭은 쓰지 않는다 (Bash tool 자신의 래퍼가
  매치되거나 패턴 미스로 오판한 실측 사례).
- stderr tail의 마지막 줄로 완료·진척을 추론하지 않는다 (원인 분류 목적의 내용 검사는 유효).
- "result 부재 + stderr 존재"가 항상 진행 중을 뜻하지도 않는다 — detach 실패·stream 오류
  전멸에서도 같은 외형이 난다. 최종 판정은 완료 알림 또는 `.rc` 마커로만 한다.
- `2>` stderr 분리를 항상 유지하는 이유: timeout으로 죽으면 stderr가 유일한 포렌식 산출물이다.

## exec vs review 비교표

| 항목 | `codex exec` | `codex exec review` |
|------|-------------|---------------------|
| 프롬프트 | 완전 자유 제어 | diff 컨텍스트 내장 |
| 대상 | 범용 작업 | 코드 리뷰 특화 |
| diff 스코핑 | 수동 (heredoc 등) | 자동 (--uncommitted/--base/--commit) |
| `-o` 동작 | 정상 | 정상 (0.144.1 로컬 실측; upstream #12502 open이나 미재현, 2026-07-10) |

## 빠른 참조 표

모든 programmatic 호출에는 `env CODEX_PROGRAMMATIC=1`을 wrapper 프로세스에 적용한다. wrapper가
Codex 자식으로 환경을 전달하며 CLI 자체는 이 값을 자동 주입하지 않는다.

| 상황 | 패턴 | 명령 요약 |
|------|------|-----------|
| 일반 실행 | 1 | `cat prompt \| env CODEX_PROGRAMMATIC=1 codex-exec-supervised -s workspace-write -o result -` |
| 리뷰 (기본) | 2 | `env CODEX_PROGRAMMATIC=1 codex-exec-supervised review --base main -o result` |
| 리뷰 (stdin PROMPT) | 2b | `cat prompt \| env CODEX_PROGRAMMATIC=1 codex-exec-supervised review -o result -` |
| 리뷰 + 커스텀 지시 (영구) | 3 | AGENTS.md 작성 후 `env CODEX_PROGRAMMATIC=1 codex-exec-supervised review --base` |
| 리뷰 + 커스텀 지시 (1회) | 4 | `cat diff+지시 \| env CODEX_PROGRAMMATIC=1 codex-exec-supervised -s workspace-write -o result -` |
| 피드백 루프 | 5 | 라운드별 prompt → supervised `-o` → 진척 검증 → 반복 |
| 구조화 출력 | 6 | supervised `--output-schema schema.json -o result` |
| JSONL 스트림 | 7 | supervised `--json` + stdout/stderr 분리 |
| 환경 점검 | 8 | fan-out 전 supervised 최소 스모크 |
| 임시 cwd 격리 | 9 | `--ignore-user-config --ignore-rules --ephemeral --skip-git-repo-check` + effort `-c` 명시 |
| 진행 중 진단 | 10 | stderr 전진=생존, `-o` 부재≠실패, 사망 판정은 프로세스 생존 확인 결합 |
