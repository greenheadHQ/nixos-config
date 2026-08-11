# using-codex-exec 제한사항 및 트러블슈팅

Codex CLI의 알려진 제한사항, 미해결 이슈, 실행 실패 대응 절차를 통합 관리한다.
이 문서는 `codex exec` / `codex exec review` subprocess 경로만 다룬다.
Codex 세션에서 `spawn_agent` / `wait_agent`(capability profile에 따라 legacy 한정 `close_agent` — [`run-da/references/runtime-mapping.md`](../../run-da/references/runtime-mapping.md#codex-native-lifecycle-capability-profile) SSOT)로 오케스트레이션하는 native subagent 경로에는
여기의 stdin 경쟁, heredoc hang, 결과 파일 회수 제약을 기본 가정으로 적용하지 않는다.

## 0. 공통 진단

실패 시 아래 명령으로 환경을 먼저 확인한다:

```bash
command -v codex
command codex --version
command codex exec --help
command codex exec review --help
pwd
git rev-parse --show-toplevel
```

- CLI 버전/옵션 존재 여부 확인
- 저장소 루트 밖에서 실행 중인지 확인
- 워크트리(worktree) 환경이면 `git rev-parse --git-dir`로 git 디렉토리 경로 확인
- 비대화형 PATH에서 `command -v codex`가 실패하면 곧바로 미설치로 단정하지 않는다.
  wrapper exit 127은 PATH/의존성 외에 invalid env 값·정본 `CODEX_EXEC_*` 변수명
  near-miss(§15)도 포함하므로 stderr를 먼저 읽는다. 이후 programmatic 경로는
  `command -v codex-exec-supervised` → `codex-exec-supervised --check` →
  확인된 Codex 절대경로 순으로 진단한다.

오류 기록은 stdout, stderr, `-o` 결과, exit code를 분리한다. JSON/JSONL parser 앞에
`2>&1`를 두지 않고, pipeline은 `set -o pipefail`과 zsh `pipestatus`로 Codex exit를 보존한다.
`| head`, `| tail`, 뒤이은 `; echo $?`는 원래 exit를 가릴 수 있다.

| 오류 분류 | 재시도 정책 | 관측 출처 |
|----------|-------------|----------|
| wrapper 사전 검증 실패(invalid env·near-miss 포함)/PATH exit 127 | stderr로 사유 확인 → 경로·wrapper `--check` 후에만 재실행 | 실전 재발 사례 7건 + wrapper smoke |
| 부모 sandbox denial | 소유권 변경 금지, §18 분기 | 실전 재발 사례 6건 |
| timeout exit 124/137 | 자식 정리 확인 후 fresh retry 최대 1회 | 실전 재발 사례 |
| usage limit | fail-fast. 신규 세션 재시도 금지 | 실전 재발 사례; 2026-07-10 재확인 |
| unsupported model | `-m` 제거 후 fresh retry 최대 1회 | 통제 smoke에서 관측 |
| exit 0 + `-o` 미생성 | 실패 처리, stderr·라우팅·session id 조사 | 실전 재발 사례 5건 |

SSH/원격 장기 실행은 약 10분 무출력 뒤 완료된 실측이 있으므로 무출력만으로 중단이라 단정하지
않는다. 반대로 프로세스 생존만으로 정상이라 단정하지도 않는다. outer timeout을 두고 종료 후
`test -s "$RESULT"`로 산출물을 검증한다.

---

## 알려진 제한사항 (Known Limitations)

### 1. review에서 PROMPT과 scope flag 동시 사용 불가

심각도: 치명적 — 스킬 사용 시 가장 빈번하게 부딪히는 제약

증상:

```
error: the argument '[PROMPT]' cannot be used with '--base <BRANCH>'
error: the argument '[PROMPT]' cannot be used with '--uncommitted'
error: the argument '[PROMPT]' cannot be used with '--commit <SHA>'
```

근본 원인 — 소스코드 레벨 분석:

Codex CLI의 `codex-rs/protocol/src/protocol.rs`에서 `ReviewTarget`이 enum으로 정의되어 있다:

```rust
pub enum ReviewTarget {
    UncommittedChanges,
    BaseBranch { branch: String },
    Commit { sha: String, title: Option<String> },
    Custom { instructions: String },
}
```

4개 변형(variant)이 상호 배타적이며, `ReviewRequest` 구조체에 `additional_instructions` 필드가 존재하지 않는다. 따라서 `Custom` variant(사용자 PROMPT)와 나머지 preset variant(`BaseBranch`, `UncommittedChanges`, `Commit`)를 동시에 선택할 수 없다.

CLI 인자 파서(`codex-rs/exec/src/cli.rs`)에서 `ReviewArgs` 구조체가 clap의 `conflicts_with_all`로 이 배타성을 강제한다:

```rust
#[arg(
    long = "uncommitted",
    conflicts_with_all = ["base", "commit", "prompt"]
)]
pub uncommitted: bool,

#[arg(
    long = "base",
    conflicts_with_all = ["uncommitted", "commit", "prompt"]
)]
pub base: Option<String>,

#[arg(
    long = "commit",
    conflicts_with_all = ["uncommitted", "base", "prompt"]
)]
pub commit: Option<String>,
```

각 preset의 리뷰 프롬프트는 `codex-rs/core/src/review_prompts.rs`에 하드코딩되어 있다:

- `UNCOMMITTED_PROMPT`: "Review the current code changes (staged, unstaged, and untracked files)..."
- `BASE_BRANCH_PROMPT`: "Review the code changes against the base branch '{baseBranch}'..."
- `COMMIT_PROMPT`: "Review the code changes introduced by commit {sha}..."

이슈 추적:

| 이슈/PR | 상태 | 설명 |
|---------|------|------|
| [#7825](https://github.com/openai/codex/issues/7825) | CLOSED AS NOT PLANNED (2026-03-29) | 이슈는 종결됐지만 0.144.1 runtime 제약은 유지. |
| [#11903](https://github.com/openai/codex/pull/11903) | CLOSED (미머지, 2026-02-16) | `additional_instructions: Option<String>`을 `ReviewRequest`에 추가하는 PR. `ReviewTarget` 해석 후 비어있지 않은 추가 지시를 append하는 구현. invitation-only 기여 정책으로 close됨. |
| [#6432](https://github.com/openai/codex/issues/6432) | OPEN (2025-11-09~) | headless review 전체 제안. `custom [PROMPT\|-]` preset 포함. 부분 구현 상태. |

커뮤니티 프로토타입:
- @agisilaos의 포크: https://github.com/agisilaos/codex/compare/main...feat/review-optional-comments-clean
- 3개 커밋으로 `additional_instructions`를 protocol/core/TUI/app-server/exec 전체에 전파하는 구현.

대안:
- SKILL.md 의사결정 트리의 "방법 A" (AGENTS.md) 또는 "방법 B" (exec 우회) 참조.
- 향후 CLI 업데이트로 이 제약이 해소될 수 있으므로, `codex exec review --help` 출력을 주기적으로 재확인한다.

재검증 방법: 아래 명령이 에러 없이 실행되면 제약이 해소된 것이다:

```zsh
set -o pipefail
printf 'test\n' | env CODEX_PROGRAMMATIC=1 codex exec review - --base main \
  > /tmp/review-conflict.stdout 2> /tmp/review-conflict.stderr
codex_rc=$pipestatus[2]
```

재확인: 2026-07-10, codex-cli 0.144.1 — 여섯 pairwise 조합이 모두 clap exit 2로
실패했다. 이슈 상태와 runtime 제약을 분리한다. 관측 출처: 통제 smoke.

### 2. review `-o` upstream bug — 빈 파일 생성 (0.142.5에서 해소됨)

심각도: 높음 (해소 전 기준 — 버전 하한 판단 근거로 보존)

0.144.1에서 `-o`와 stdout 모두 정상이다 (재확인: 2026-07-10). 실제 버그가 있는 diff에
`review --uncommitted -o`를 실행해 두 채널에 동일 review가 기록되고 `-o` 파일이 non-empty임을
확인했다. stderr에는 진행 로그와 사본이 있었으며, upstream [#12502](https://github.com/openai/codex/issues/12502)는
여전히 open이지만 보고 내용은 “review가 stdout 대신 stderr로 감”이다. 로컬 0.144.1에서는 그 회귀도
재현되지 않았다. upstream 상태와 로컬 판정을 분리한다. 관측 출처: 통제 smoke.

해소 전 역사: v0.104.0~v0.115.0-alpha에서는 `Warning: no last agent message; wrote empty content`와
0바이트 `-o` 파일을 직접 재현했다. 이 기록은 버전 하한 판단용으로만 보존한다.

재검증 방법: 실제 diff가 있는 저장소에서 stdout/stderr/result를 분리한 뒤 두 결과를 확인한다.

```bash
env CODEX_PROGRAMMATIC=1 codex exec review --uncommitted \
  -o /tmp/review-result.md \
  > /tmp/review.stdout 2> /tmp/review.stderr
rc=$?
test "$rc" -eq 0 && test -s /tmp/review-result.md && test -s /tmp/review.stdout
```

### 3. review가 working-tree 변경을 잘못 포함

심각도: 중간

이슈: [#8404](https://github.com/openai/codex/issues/8404) (OPEN)

증상: `--base` 리뷰 시 현재 브랜치의 커밋된 변경뿐 아니라, 워킹트리의 미커밋 변경까지 리뷰 대상에 포함되는 경우가 있다. 실제 diff에 없는 내용에 대한 hallucinated finding이 나타날 수 있다.

대안:
- 리뷰 전 워킹트리를 깨끗한 상태로 만든다 (`git stash`).
- 리뷰 결과를 실제 diff와 대조하여 검증한다.

재검증 미수행 (codex-cli 0.142.5 기준 서술 유지): `--base`의 working-tree 포함 여부.

### 4. exec review가 공식 CLI reference에 미문서화

심각도: 정보

`codex exec review`는 부분적으로 구현되어 작동하지만, OpenAI의 공식 CLI reference (https://developers.openai.com/codex/cli/reference/) 에는 문서화되어 있지 않다. 공식 문서가 권장하는 headless code review 방식은:

1. `codex exec "Review my pull request!"` + `--output-schema` (구조화 출력)
2. `openai/codex-action@v1` GitHub Action

이 스킬에서는 현실적으로 작동하는 `codex exec review`를 다루되, 공식 지원 상태가 변할 수 있음을 인지한다.

---

## 트러블슈팅

### 5. `unexpected argument '--approval-mode' found`

원인: `codex exec`는 `--approval-mode` 플래그를 받지 않는다. exec/review/resume의 공개
surface에 승인 관련 CLI 플래그가 없다. approval `never` 고정 동작은 재검증 미수행
(0.142.5 기준 서술 유지).

해결: 세밀한 샌드박스 조정이 필요하면 exec에서 `-s, --sandbox <MODE>`를 사용한다 (review/resume은 `-s` 미지원 — config.toml의 `sandbox_mode`를 따른다). 그 외 조정은 `-c key=value`로 처리한다.

과거 승인 자동화 + workspace-write 단축 플래그 `--full-auto`는 0.144.1 help에 없지만 hidden parser가
수용하며 deprecation warning을 낸다. 새 문서/스크립트는 `-s workspace-write`를 사용한다.

### 6. 결과 파일이 비어 있음 (`-o` 사용 시)

증상: `-o /tmp/result.md` 파일은 생성되지만 내용이 비어 있거나 기대보다 짧다.

원인:
- 실행이 중간 실패하여 마지막 에이전트 메시지가 없을 수 있다.
- `Warning: no last agent message; wrote empty content` 경고가 stderr에 출력된다.
- exit 0이어도 업무 산출물이 생성되지 않은 실전 사례가 있다.
- review `-o`의 과거 빈 파일 증상은 0.144.1에서 해소됨. §2 참조.

해결:
1. stdout, stderr, `-o` 결과를 별도 파일로 캡처한다.
2. `test -s "$RESULT"`를 통과하지 못하면 exit 0이어도 실패로 처리한다.
3. 프롬프트 파일 내용이 비어 있지 않은지 확인한다.
4. 상위 오류(`model is not supported` 등)를 먼저 해결한다.
5. 최소 프롬프트(패턴 8 스모크 테스트)로 재현 범위를 줄인다.

관측 출처: exit 0 + 산출물 누락은 실전 재발 사례 5건. review `-o` 해소는 통제 smoke.

### 7. stdin 입력이 멈춘 것처럼 보임

원인:
- stdin 파이프가 실제로 입력을 전달하지 못했을 수 있다.
- 파이프 앞 명령이 실패했는데 종료 코드 확인 없이 진행했을 수 있다.

해결:
1. 먼저 입력 파일을 출력하여 내용 존재를 확인한다:
   ```bash
   cat /tmp/prompt.md
   ```
2. 인라인 프롬프트로 비교 실행한다:
   ```bash
   command codex exec -s workspace-write "짧은 스모크 테스트"
   ```

`Reading additional input from stdin...` banner 자체는 stdin append 경로 진입 표시다. hang은 banner,
무진척, 결과 미생성이 함께 나타날 때 판정한다. PROMPT와 piped stdin 병용은 0.144.1에서
`<stdin>` 블록 append로 정상 완료될 수 있다.

### 8. Git 저장소 체크 실패

원인: `codex exec` 기본 동작은 git 저장소 컨텍스트를 기대한다.

해결:
1. 저장소 루트로 이동하여 실행한다 (권장):
   ```bash
   cd "$(git rev-parse --show-toplevel)"
   ```
2. 저장소 외 실행이 꼭 필요하면 `--skip-git-repo-check`를 사용한다.

### 9. `model is not supported` 오류

증상:

```
ERROR: {"detail":"The '<model>' model is not supported when using Codex with a ChatGPT account."}
```

원인: Codex 모델 라인업에 포함되지 않은 모델(`o3`, `o4-mini`, `gpt-4.1` 등)을 `-m`으로 지정했다. ChatGPT 계정에서만 발생하며, "Model metadata not found" 경고(§10)가 선행한다.

해결:
1. `-m`을 제거하고 기본 모델(`~/.codex/config.toml`)로 재시도한다.
2. 동일 오류 반복 시 `codex exec --help`와 계정 모델 접근 정책을 확인한다.

재검증 미수행 (codex-cli 0.142.5 기준 서술 유지): unsupported-model runtime response.

### 10. `Model metadata ... not found` 경고

증상:

```
warning: Model metadata for `<model>` not found. Defaulting to fallback metadata; this can degrade performance and cause issues.
```

원인: 지정한 모델이 CLI의 내장 모델 레지스트리에 없다. Codex 라인업 외 모델(`o3`, `o4-mini`, `gpt-4.1` 등) 지정 시 항상 발생하며, §9 에러와 함께 나타난다.

해결: `-m`을 제거하거나 `config.toml`의 기본 모델로 되돌린다.

재검증 미수행 (codex-cli 0.142.5 기준 서술 유지): model metadata warning runtime response.

---

## 워크트리(Worktree) 환경 참고사항

git worktree 환경에서 `codex exec`를 실행할 때:

- codex exec 자체는 정상 동작한다: worktree도 완전한 git working directory이므로, `git diff`, `git merge-base` 등이 동일하게 작동한다.
- `--base` 동작은 동일하다: worktree에서도 `origin/main...HEAD` diff가 정상 계산된다.
- detached HEAD 주의: worktree가 detached HEAD 상태이면 브랜치 기반 비교가 실패할 수 있다. `git branch --show-current`로 브랜치 상태를 확인한다.
- Codex App의 worktree 버그는 codex exec와 무관하다: Codex App(GUI)에는 다수의 worktree 관련 버그(cross-worktree writes, UI freeze 등)가 보고되어 있으나, 이는 CLI exec 실행에 영향을 주지 않는다.

재검증 미수행 (codex-cli 0.142.5 기준 서술 유지): worktree/`--base`/detached HEAD runtime.

---

## 재현 가능한 최소 실행으로 복구

실패가 반복될 때 아래 명령으로 기본 동작을 확인한다:

```bash
cat > /tmp/smoke.md <<'PROMPT'
현재 작업 디렉토리에서 가장 중요한 리스크 1개만 한 줄로 답한 뒤, 마지막 줄에 SMOKE_DONE만 출력한다.
PROMPT
```

⚠️ `run_in_background` 환경: 여기서 Bash tool 호출을 종료하고, 아래를 별도 호출로 실행한다 (§11 하위 항목).

```bash
rm -f /tmp/smoke-result.md   # 이전 실행의 non-empty 잔존 결과로 인한 오판 방지
set -o pipefail
cat /tmp/smoke.md | env CODEX_PROGRAMMATIC=1 codex-exec-supervised \
  -s workspace-write -o /tmp/smoke-result.md - \
  > /tmp/smoke.stdout 2> /tmp/smoke.stderr
# PIPESTATUS는 다음 명령에서 리셋되므로 배열을 먼저 스냅샷한다 (cat 실패도 판정에 포함).
pipe_rcs=("${PIPESTATUS[@]}")   # zsh는 ("${pipestatus[@]}") — 인덱스가 1부터
[ "${pipe_rcs[0]}" -eq 0 ] && [ "${pipe_rcs[1]}" -eq 0 ] \
  && test -s /tmp/smoke-result.md && grep -q "SMOKE_DONE" /tmp/smoke-result.md
```

wrapper exit 0, non-empty 결과, 기대한 완료 표식이 모두 확인되면 통과다. fan-out은 이 스모크를
한 번 통과한 뒤 시작한다. 통과하면 기존 복잡한 프롬프트로 단계적으로 복귀한다.
실패하면 §0 공통 진단부터 다시 시작한다.

---

### 11. Claude Code Bash tool sandbox 제약

심각도: 치명적 — Bash tool에서 codex exec 병렬 실행 시 반드시 적용

현재 재검증 미수행 (codex-cli 0.142.5 기준 서술 유지). 아래 날짜·버전별 관측을 역사적
실전 사례로 보존한다.

관찰된 동작 (2026-03-29 재현):

| 방식 | 결과 | 원인 |
|------|------|------|
| `&` + `$!` (background PID) | BROKEN | `$!` → 리터럴 문자열, PID 미캡처 |
| `cat file \| env CODEX_PROGRAMMATIC=1 codex exec ... -` (stdin pipe) 별도 Bash tool 호출 | OK | 각 호출이 독립 shell — pipe EOF가 stdin을 닫음 |
| `env CODEX_PROGRAMMATIC=1 codex exec "$(cat file)"` (인라인 인자) | OK | shell 확장 후 인자 전달 |
| `env CODEX_PROGRAMMATIC=1 codex exec < file` (file redirect) | OK | 정상 작동 |
| 병렬 Bash tool 호출 (foreground) | OK | tool-level 병렬화, 전부 완료까지 대기 |
| Bash tool `run_in_background: true` | OK | background 실행, 각 완료 시 자동 알림 |

(programmatic codex 호출은 모두 `env CODEX_PROGRAMMATIC=1`을 codex 프로세스에 적용한다 — issue #585.)

영향 범위: Claude Code Bash tool sandbox에서 `codex exec` subprocess를 돌리는 경우에만 적용.
Codex 세션의 native subagent 경로와 일반 터미널에는 이 제약을 기본 전제로 적용하지 않는다.

근본 원인:
- Bash tool은 각 호출을 격리된 shell에서 실행하며, background process와 job control이 제한됨.
- `$!`가 변수 확장되지 않고 리터럴로 처리됨.
- 같은 Bash tool 호출 안에서 `&`로 다수 stdin pipe를 병렬 실행하면 경합 발생 가능. 별도 Bash tool 호출(`run_in_background: true`)에서는 각각 독립 shell이므로 경합 없음.

#### literal 재사용 시 random suffix 환각 금지 (issue #632)

`mktemp`/`mktemp -d`/`mktemp -t` 결과 경로의 random suffix는 opaque high-entropy literal이므로 LLM token prediction에서 다른 suffix와 혼선될 수 있다. stdout에 출력된 정확한 경로를 byte-level 그대로 재사용하고, suffix를 검증 없이 변형·재생성하거나 `/tmp/da-*` 같은 wildcard glob로 대체하지 않는다. 호출 직전 디렉토리는 `[ -d "$DIR" ]`, 파일은 `[ -f "$FILE" ]` guard로 fail-fast한다. 단일 exec 흐름은 발사 방식과 무관하게 prompt 작성, codex exec, result check를 같은 shell call 안에서 완료한다 (background 발사도 블록 전체가 한 셸 호출이다). 구조적으로 multi-call이 필요한 flow는 분리 구조를 유지하되 출력된 literal 경로와 guard를 사용한다.

올바른 패턴 — codex exec 병렬 실행:

1. 프롬프트 파일을 1개 Bash call로 생성:
   ```bash
   DA_DIR=$(mktemp -d /tmp/da-XXXXXX)
   [ -d "$DA_DIR" ] || { echo "missing DA_DIR=$DA_DIR"; exit 1; }
   cat > "$DA_DIR/domain.md" <<'PROMPT'
   ...프롬프트 내용...
   PROMPT
   printf 'DA_DIR=%s\n' "$DA_DIR"
   # 예시 stdout: DA_DIR=/tmp/da-a1b2c3
   ```

   > literal 재사용 환각 주의 (issue #632): split-call examples에서 `DA_DIR`/`TDIR` 같은 mktemp 경로를 다음 호출에 넘길 때 stdout에 출력된 리터럴 경로를 byte-level 그대로 사용하고, 호출 직전 `[ -d "$DIR" ]` guard로 fail-fast한다. full rule은 위 [`literal 재사용 시 random suffix 환각 금지`](#literal-재사용-시-random-suffix-환각-금지-issue-632)를 따른다.

2. 각 codex exec를 별도 Bash tool 호출로 병렬 실행 (필요 수만큼 동시) — programmatic 호출은 §15 supervised wrapper(Layer 1) 사용:
   ```bash
   # 직전 stdout이 정확히 `DA_DIR=/tmp/da-a1b2c3`였을 때만 이 값을 사용.
   DA_DIR=/tmp/da-a1b2c3
   [ -d "$DA_DIR" ] || { echo "missing DA_DIR=$DA_DIR"; exit 1; }
   [ -f "$DA_DIR/domain.md" ] || { echo "missing prompt=$DA_DIR/domain.md"; exit 1; }
   # marker must apply to `codex`, not `cat` (issue #585): Codex 0.124+ user-level hooks의 early-exit 신호.
   cat "$DA_DIR/domain.md" | env CODEX_PROGRAMMATIC=1 codex-exec-supervised \
     --sandbox read-only --ignore-user-config --ignore-rules --ephemeral \
     -c model_reasoning_effort="medium" \
     -o "$DA_DIR/domain-result.md" \
     - \
     2>"$DA_DIR/domain-stderr.log"
   ```

3. 모든 Bash tool 호출 완료 후 결과 수집.

Background 대안 — 다수 병렬 실행 시 LLM 블로킹 방지:

2b. 각 codex exec를 Bash tool `run_in_background: true`로 실행 — programmatic 호출은 §15 supervised wrapper(Layer 1) 사용 (foreground 예시와 동일 명령):
    ```bash
    # 직전 stdout이 정확히 `DA_DIR=/tmp/da-a1b2c3`였을 때만 이 값을 사용.
    DA_DIR=/tmp/da-a1b2c3
    [ -d "$DA_DIR" ] || { echo "missing DA_DIR=$DA_DIR"; exit 1; }
    [ -f "$DA_DIR/domain.md" ] || { echo "missing prompt=$DA_DIR/domain.md"; exit 1; }
    # Bash tool 호출 시 run_in_background: true 파라미터 사용
    cat "$DA_DIR/domain.md" | env CODEX_PROGRAMMATIC=1 codex-exec-supervised \
      --sandbox read-only --ignore-user-config --ignore-rules --ephemeral \
      -c model_reasoning_effort="medium" \
      -o "$DA_DIR/domain-result.md" \
      - \
      2>"$DA_DIR/domain-stderr.log"
    ```
    - LLM이 즉시 반환받아 사용자와 대화 가능
    - 각 완료 시 자동 알림 수신 (sleep/poll 금지)
    - 모든 완료 알림 수신 후 결과 파일 일괄 수집

3b. foreground와 동일하게 결과 파일로 수집. `-o` 결과 파일은 프로세스 종료 시 생성됨.

금지 패턴:
- `&` + `wait` + `$!` (shell-level background)
- 같은 Bash tool 호출 안에서 `&`로 다수 stdin pipe 병렬 (`cat f1 | codex exec & cat f2 | codex exec &`)
- here-doc + pipe 조합의 다수 병렬
- heredoc + codex exec 체이닝 (같은 Bash 호출에서 `run_in_background` 사용 시 — 하위 항목 참조)
- Bash tool `run_in_background: true` 사용 후 sleep/poll로 완료 확인 (알림이 자동으로 옴)

재검증 방법:
```bash
sleep 0.1 &
echo "PID: $!"
# "PID: $!" (리터럴) → sandbox 제약 유효
# "PID: 12345" (숫자) → sandbox 제약 해소
```

#### heredoc + codex exec 체이닝 시 hang (run_in_background 환경)

심각도: 높음 — `run_in_background: true`에서 heredoc으로 파일 생성 후 같은 Bash 호출에서 codex exec를 이어 실행하는 경우에 적용

증상: `run_in_background: true`로 실행한 Bash 호출에서 heredoc으로 파일을 생성한 뒤 같은 호출에서 codex exec를 실행하면, codex가 무한 대기.

관찰된 동작: 특정 Bash tool sandbox 구성에서 heredoc과 codex exec를 같은 호출에 체이닝하면 hang이 발생한다. 정확한 메커니즘은 미확정이나, heredoc이 stdin 상태에 영향을 주어 후속 codex exec가 추가 입력을 기다리는 것으로 추정된다. `run_in_background` 환경에서만 발생하며, 일반 터미널에서는 재현되지 않는다.

재현 (codex-cli v0.118.0, 2026-04-01 확인. 원 재현에는 당시 자동실행 단축 플래그를
사용했으나 현재 공개 surface에서는 숨겨지고 deprecated되었으므로 아래는 `-s workspace-write`로
치환한 등가 명령이다 — 버그는 stdin/heredoc 상호작용이 원인이라 재현 조건은 바뀌지 않는다):

HANG — heredoc 체이닝 (같은 Bash 호출):
```bash
(umask 077; TDIR=$(mktemp -d /tmp/test-XXXXXX) && cat > "$TDIR/prompt.md" <<'EOF'
테스트 프롬프트
EOF
command codex exec -s workspace-write --ephemeral -o "$TDIR/result.md" "$(cat "$TDIR/prompt.md")")
# → 무한 대기
```

OK — 별도 Bash 호출로 분리:

1. Bash tool 호출 1: 프롬프트 파일 생성 (경로 출력)
```bash
TDIR=$(mktemp -d /tmp/test-XXXXXX)
[ -d "$TDIR" ] || { echo "missing TDIR=$TDIR"; exit 1; }
cat > "$TDIR/prompt.md" <<'EOF'
테스트 프롬프트
EOF
printf 'TDIR=%s\n' "$TDIR"
# 예시 stdout: TDIR=/tmp/test-a1b2c3
```

2. Bash tool 호출 2: codex exec 실행 (경로 직접 지정)
```bash
# 직전 stdout이 정확히 `TDIR=/tmp/test-a1b2c3`였을 때만 이 값을 사용.
TDIR=/tmp/test-a1b2c3
[ -d "$TDIR" ] || { echo "missing TDIR=$TDIR"; exit 1; }
[ -f "$TDIR/prompt.md" ] || { echo "missing prompt=$TDIR/prompt.md"; exit 1; }
cat "$TDIR/prompt.md" | env CODEX_PROGRAMMATIC=1 codex-exec-supervised \
  --sandbox read-only --ignore-user-config --ignore-rules --ephemeral \
  -c model_reasoning_effort="medium" \
  -o "$TDIR/result.md" \
  - \
  2>"$TDIR/stderr.log"
```

올바른 패턴: 프롬프트 파일 생성과 codex exec를 별도 Bash tool 호출로 분리한다. §11 본문의 "올바른 패턴"과 동일 원리. 호출 간 상태 공유는 파일 경로를 통해서만 한다 (셸 변수는 호출 간 유지되지 않으므로, 1단계에서 출력한 경로를 2단계에서 리터럴 값으로 재설정하고 guard한다).

§11 본문과의 관계: §11은 `& + wait` shell-level 병렬과 다수 stdin pipe 경합의 제약이고, 이 항목은 heredoc 체이닝의 stdin 관련 문제이다. 원인은 다르지만 해결 패턴(별도 Bash tool 호출 분리)은 동일하다.

### 12. 동시 다중 세션 간 /tmp/da-* 경쟁 상태

심각도: 높음 — 동시에 여러 Claude Code 세션이 DA를 실행할 때 발생

증상: 한 세션의 cleanup glob(`rm -rf /tmp/da-pr-*`)이 다른 세션의 결과 파일을 삭제. codex exec가 결과 파일 누락으로 실패하거나, 다른 세션의 결과를 잘못 읽음.

근본 원인: cleanup glob이 세션을 구분하지 않아, 다른 워크트리/세션의 임시 파일까지 삭제.

해결: run-da/references/runtime-mapping.md의 `codex exec 경로 위생 규칙` 세션 네임스페이스(`$_DA_SID`) 규칙에 따라 `$CODEX_COMPANION_SESSION_ID` 앞 8자 (또는 `$PWD` 해시 fallback)를 모든 임시 디렉토리 prefix에 포함한다.

참고: Codex 공식 플러그인은 Session ID 기반 필터링(`state.jobs.filter(job => job.sessionId === sessionId)`)으로 동일 문제를 해결한다 (glob 대신 명시적 참조 추적).

### 13. 병렬 Bash 호출 시 codex exec background 전환 → stdin hang

> 대체됨: 이 항목의 `< /dev/null` 해결 패턴은 §14의 stdin pipe 패턴으로 대체되었다. 새 코드에서는 §14를 따른다. 이 항목은 역사적 기록으로 보존한다.

심각도: 높음 — Claude Code에서 병렬 Bash tool 호출 시 발생

증상: foreground로 실행한 codex exec가 Claude Code에 의해 background로 자동 전환됨. background 전환 후 `Reading additional input from stdin...`에서 무한 대기. 결과 파일(`-o`)이 생성되지 않고 프로세스가 Ss(sleeping) 상태로 남음.

재현: 2개 이상의 Bash tool 호출을 동시에 보내면, 하나가 완료된 후 나머지가 background로 전환될 수 있음. 단독 실행에서는 발생하지 않음.

근본 원인: Claude Code Bash tool이 병렬 실행 시 background 전환하면서 stdin이 적절히 닫히지 않음. codex exec는 인자로 프롬프트를 받아도 stdin이 열려있으면 추가 입력을 기다림.

해결: 모든 codex exec 호출에 `< /dev/null`을 추가하여 stdin을 즉시 EOF로 만든다. (아래 명령의
샌드박스 플래그는 §13 최초 기록 당시의 자동실행 단축 플래그를 현재 공개 표기인
`-s workspace-write`로 치환한 것 — stdin EOF 해결 패턴 자체와는 무관하다.)
```bash
command codex exec -s workspace-write --ephemeral -o "$DIR/result.md" "$(cat prompt.md)" < /dev/null
```

참고: Codex 공식 플러그인의 background 작업은 `stdio: "ignore"`로 stdin/stdout/stderr를 모두 /dev/null로 리다이렉트한다 (동일 효과).

관련 upstream: [#20919](https://github.com/openai/codex/issues/20919) (non-TTY stdin hang),
[#19945](https://github.com/openai/codex/issues/19945) (TTY 분리 + 긴 prompt silent crash, 0.124 회귀).
관측 출처: 실전 재발 사례. 현재 semantic 재검증 미수행 (v0.142.5 기준 서술 유지).

### 14. stdin pipe로 §13의 stdin hang을 구조적 해결

심각도: 해결 패턴 — §13의 `< /dev/null` 패턴을 대체하는 더 구조적인 접근

배경: §13은 "모든 codex exec 호출에 `< /dev/null`을 추가"하여 stdin hang을 해결했다. 그러나 `< /dev/null`이 있어도 비결정적으로 hang이 발생하는 사례가 보고되었다 (#443 DA for_pr R4, 2026-04-11). stdin pipe(`cat file | codex exec ... -`)는 pipe EOF 메커니즘으로 stdin을 닫아 동일 문제를 더 확실히 해결한다.

근본 원인 정정: 이슈 #453의 원래 가설인 "`"$(cat file)"`에서 diff의 shell 메타문자가 재해석된다"는 PoC로 반증됨. `"$(cat file)"` 패턴에서 파일 내용의 `$()`, backtick, `<`, `>` 등은 shell이 재해석하지 않는다 (따옴표 안의 명령 치환 결과는 리터럴로 전달됨). 실제 원인은 §13과 동일한 "background 전환 시 stdin 미닫힘"이다.

해결: stdin pipe로 프롬프트를 전달한다. pipe EOF가 codex exec의 stdin을 구조적으로 닫는다.

```bash
# §13의 < /dev/null 패턴을 대체:
# marker must apply to `codex`, not `cat` (issue #585): Codex 0.124+ user-level hooks의 early-exit 신호.
cat "$DIR/prompt.md" | env CODEX_PROGRAMMATIC=1 codex-exec-supervised -s workspace-write --ephemeral \
  -o "$DIR/result.md" \
  - \
  2>"$DIR/stderr.log"
# pipe EOF가 stdin을 닫으므로 < /dev/null 불필요
```

§11과의 관계: §11은 "같은 Bash tool 호출 안에서 `&`로 다수 stdin pipe를 병렬 실행"하면 경합이 발생한다고 기록한다. 그러나 별도 Bash tool 호출(`run_in_background: true`)에서 각각 독립적으로 stdin pipe를 사용하는 것은 안전하다 — 각 호출이 독립 shell에서 실행되므로 stdin 경합이 없다.

§13과의 관계: §13의 `< /dev/null` 해결 패턴은 여전히 유효하지만, stdin pipe가 더 구조적인 대안이다. pipe는 (1) 프롬프트 전달과 (2) stdin EOF를 하나의 메커니즘으로 통합한다.

실증: 다수 codex exec를 `cat file | env CODEX_PROGRAMMATIC=1 codex exec ... - (run_in_background: true)`로 병렬 실행 → 모두 `-o` 결과 파일 정상 생성 (codex v0.120.0, 2026-04-11; marker는 issue #585에서 도입).

발견 세션: #443 PR 작업 중 DA for_pr R4 (2026-04-11). Correctness reviewer가 대규모 diff 포함 프롬프트에서 hang.

관련 upstream: [#20919](https://github.com/openai/codex/issues/20919) (non-TTY stdin hang),
[#19945](https://github.com/openai/codex/issues/19945) (TTY 분리 + 긴 prompt silent crash, 0.124 회귀).
관측 출처: 실전 재발 사례. 현재 semantic 재검증 미수행 (v0.142.5 기준 서술 유지).

### 15. `codex-exec-supervised` wrapper로 §14 위에 timeout budget 한계 보강 (issue #593)

심각도: 보강 패턴 — §14 stdin pipe + supervised wrapper로 inline TOML override 등 잔존 hang 축의 폭발 반경을 timeout으로 유한화

배경 (issue #593): §14의 stdin pipe 패턴을 따른 호출도 다음 추가 요인이 결합되면 silent hang 가능:

1. `-c hooks.<event>='[...]'` inline TOML override — Mac codex 0.128 8 PoC variant 중 vH(host HOME + no override + stdin pipe + read-only)만 OK, override 포함 vA-G + vJ 모두 hang. Agent D source 분석은 `-c` parse/merge 정상이지만 override shape가 hook engine MatcherGroup 등록 실패 가능성을 시사 (정밀 위치 [UNVERIFIED]).
2. (역사 각주 — 현행 소멸) 도입 당시(2026-05) npm wrapper(@openai/codex) 패키징은 `codex-cli/bin/codex.js`의 `spawn(binaryPath, args, {stdio:"inherit", env})`이 detach/process group 생성 없이 native를 호출해, `timeout` 단독으로는 wrapper PID만 죽고 native binary가 잔존할 수 있었다. 현행 패키징(`modules/shared/programs/codex/` — upstream tarball의 native binary 직핀)에는 중간 npm 프로세스가 없어 이 실패 모드는 재현 불가다 (2026-08 실측: `timeout --kill-after` 단독 감독에서 exit 124 직후 codex 프로세스 잔존 0).

후속 5-variant 실측에서도 `-c hooks.*` inline override 제거 시 12초 안에 성공하고 override
포함 시 hang했다. `Reading additional input...` banner만으로 hang을 판정하지 말고 banner + 무진척 +
`-o` 결과 미생성을 함께 확인한다. 관측 출처: 통제 smoke.

외부 evidence:
- [gstack#1034](https://github.com/garrytan/gstack/issues/1034) — Claude Code Bash 비대화형 세션에서 argv prompt + 열린 stdin → EOF 대기. macOS, codex v0.121. fix: `</dev/null`.
- [gstack#1045](https://github.com/garrytan/gstack/issues/1045) — 최소 재현: `codex exec "Reply PONG" -s read-only` hang, `</dev/null` 즉시 반환. codex-cli v0.118. fix: `codex exec/review/resume` 호출에 `</dev/null`.
- [oh-my-codex#1449](https://github.com/Yeachan-Heo/oh-my-codex/issues/1449) — Codex worker prompt-mode에서 stdin pipe가 열린 채 남으면 EOF 대기. fix: initial prompt write 후 stdin close, non-git cwd는 `--skip-git-repo-check`.
- [codex_sdk README](https://github.com/nshkrdotcom/codex_sdk) — SDK가 one-shot argv-prompt 실행 시 upstream CLI가 EOF 대기하지 않게 stdin을 닫는다고 명시.
- 본 repo와 동일 증상 OpenAI upstream issue는 미발견 (정확 매치는 외부 wrapper/skill repo에서만 반복).

해결: programmatic codex exec 호출은 supervised wrapper(`codex-exec-supervised`)를 사용한다. wrapper는 absolute store path 우선 + capability-probe fallback으로 `timeout`/`gtimeout`(SIGTERM 후 `--kill-after` SIGKILL 승급)을 적용한다 — 2026-08 실측상 setsid는 종료 보장에 기여하지 않으며 제거는 후속 PR 범위다 (실측 상세·제거 게이트는 아래 "실증 갱신" 블록이 정본; 그 전까지 wrapper는 setsid도 요구한다). stdin EOF는 pipe(`cat file | ... -`) 또는 file redirect(`< file`) 둘 다 허용 — 둘 다 §14의 stdin EOF 보장 패턴이다. Layer 1 호출에서는 pipe 형태가 일반적이다.

```bash
# §14 stdin pipe + §15 supervised wrapper 결합 (Layer 1 — 모든 programmatic 호출 공통)
cat "$DIR/prompt.md" | env CODEX_PROGRAMMATIC=1 codex-exec-supervised \
  --sandbox read-only --ignore-user-config --ignore-rules --ephemeral \
  -c model_reasoning_effort="medium" \
  -o "$DIR/result.md" \
  - \
  2>"$DIR/stderr.log"
```

capability probe 동작 ([`modules/shared/scripts/codex-exec-supervised.sh`](../../../../../../scripts/codex-exec-supervised.sh)):
- `setsid` 부재 → BLOCKED, exit 127. 주의: setsid는 종료 보장에 기여하지 않음이 실측 확인됐고 제거는 후속 PR 범위다 (정본: 아래 "실증 갱신" 블록) — 그 전까지 fail-closed 동작이 유지된다. 진단 목적 timeout-only는 wrapper를 우회해 `timeout` + `codex`를 직접 호출한다.
- `timeout`/`gtimeout` 부재 → BLOCKED, exit 127. Mac BSD에는 둘 다 없으므로 Nix wrapper가 binary 가용성을 보장한다.
- `codex` 부재 → exit 127.
- 정본 4개 변수(`CODEX_EXEC_TIMEOUT_SECONDS`, `CODEX_EXEC_KILL_AFTER_SECONDS`, `CODEX_EXEC_TIMEOUT_BIN`, `CODEX_EXEC_SETSID_BIN`)의 계열 이름(TIMEOUT/KILL_AFTER/SETSID 접두)이면서 정확 불일치인 `CODEX_EXEC_*` 발견 → exit 127 (near-miss fail-fast). 정본 변수명 오타(예: `CODEX_EXEC_TIMEOUT=1500` — `_SECONDS` 누락)가 침묵으로 무시되어 호출 의도가 소실되는 사고 방지. 계열 밖 `CODEX_EXEC_*`(upstream codex가 예약한 `CODEX_EXEC_SERVER_*` 등)는 wrapper 소관이 아니므로 통과한다.

Nix wiring ([`modules/shared/programs/shell/default.nix`](../../../../../shell/default.nix)): home.file로 `~/.local/bin/codex-exec-supervised`를 `pkgs.writeShellScript` wrapper에 link한다. wrapper가 `CODEX_EXEC_TIMEOUT_BIN`/`CODEX_EXEC_SETSID_BIN`에 `pkgs.coreutils`/`pkgs.util-linux`의 absolute store path를 export한 뒤 raw script(`modules/shared/scripts/codex-exec-supervised.sh`)를 exec한다. wrapper는 PATH를 변경하지 않으므로 사용자 PATH의 BSD coreutils가 보존된다 (mac `stat -f %m` 같은 BSD 호출 의미 보존).

오케스트레이션 vs 자문 (Layer 2 — `-C scratch` 추가): consult 전용 호출(외부 LLM에 옵션을 자문하는 비-repo 작업)은 Layer 1 위에 `-C <non-repo-scratch-dir>` + `--skip-git-repo-check`를 추가한다. reviewer/auditor (run-da)는 repo cwd가 필요하므로 Layer 2를 적용하지 않는다.

variant legend (issue #593 PoC 8 variant + wrapper 적용 분류):

| 시나리오 | HOME | CODEX_HOME | hooks 등록 | sandbox | stdin | 결과 (Mac 0.128, supervised wrapper 미적용) | wrapper 적용 후 기대 |
|----------|------|-----------|-----------|---------|-------|--------|--------|
| `host_home_no_override_stdin_pipe_pass` | host | host | 없음 (host config inline) | read-only | `</dev/null` 또는 pipe | OK 12s, hook fired, "PONG" | OK (wrapper grace 무관 — 이미 정상) |
| `raw_override_inline_toml_hang` | host/sandbox | host/sandbox | `-c hooks.<event>` override | workspace-write(당시 자동실행 플래그)/read-only | host inherited 또는 pipe | HANG (timeout 못 죽임) | wrapper의 timeout budget + `--kill-after` SIGKILL 승급으로 정리되어 PASS (2026-08 분리 실측: setsid 유무 무관하게 동일 결과 — 구원자는 `--kill-after`) |
| `isolated_codex_home_overrideless_retired_self_injection` | sandbox | sandbox | ephemeral config.toml | read-only | inherited | HANG/marker unset in retired PR #595 self-injection assertion | Retired historical context (#634) — local fixture now validates caller-supplied `CODEX_PROGRAMMATIC=1` inheritance with supervised wrapper + stdin pipe EOF |

Retired historical context (#634): `tests/test-codex-hook-fixtures.sh`의 기존 PR #595 self-injection assertion은 `CODEX_HOME=$sandbox/codex-home` + ephemeral config.toml + inherited stdin + raw `codex exec`에서 mac 0.128 marker unset/hang 계열 실패를 보였다. #634에서 fixture 계약을 local supported path로 정렬했다: programmatic caller가 `CODEX_PROGRAMMATIC=1`을 codex 프로세스에 붙이고, live fixture는 `codex-exec-supervised` + stdin pipe EOF + sandbox `CODEX_HOME` hook config로 이 marker가 hook subprocess까지 상속되는지만 검증한다. managed hook early-exit 자체는 deterministic noise-guard fixture가 검증한다.

§14와의 관계: §14는 stdin EOF 보장을 stdin pipe로 구조적으로 제공한다. §15는 그 위에 timeout budget + SIGKILL 승급을 추가해, stdin 규약이 깨지거나 override 결합 hang이 발생해도 폭발 반경을 유한하게 만든다. 두 패턴은 결합 사용한다.

실증 (도입 시점 — Mac codex 0.128, npm 패키징): `read_prompt_from_stdin(StdinPromptBehavior::OptionalAppend)` source line + npm wrapper spawn 시 detach 부재 직접 검증. 외부 보고 4종(gstack #1034/#1045, codex_sdk, oh-my-codex #1449)이 stdin EOF fix path를 일관되게 제시.

실증 갱신 (2026-08-10 — codex 0.147.0, native 직핀; setsid 실측 서술의 정본 블록 — 다른 위치의 언급은 이 블록을 참조한다): ① stdin optional-append hang은 여전히 재현된다 (`sleep 300 | codex exec … "prompt"` → `Reading additional input from stdin...` 후 무진행; upstream [#20919](https://github.com/openai/codex/issues/20919)·[#27019](https://github.com/openai/codex/issues/27019) OPEN, opt-out 플래그 없음). ② npm wrapper 잔존 축은 소멸 — `timeout --kill-after` 단독 감독으로 codex 본체 정리 확인. ③ mac+Linux hazard 분리 실험에서 process group은 GNU timeout 자신이 생성하고(비-foreground 모드) SIGTERM 무시 hang의 유일한 구제는 `--kill-after`(SIGKILL 승급)이며 setsid는 결과를 바꾸지 않는다. setsid 의존 제거는 real-codex Linux 매트릭스 재확인(계정 quota 리셋 2026-08-16 이후; 그 전까지는 합성 hazard 실험 대체)을 게이트로 하는 후속 PR 범위다. ④ codex가 자체 process group으로 분리해 띄운 exec-tool 자식은 wrapper로도 회수되지 않는다 (supervisor 레벨에서 원리적 커버 불가 — upstream 영역).

발견 세션: PR #588 Phase 4 머지 후 retry hang (issue #593, 2026-04-29 발생).

### 16. NixOS bwrap 의존

심각도: 높음 — Linux `read-only` / `workspace-write` sandbox의 구조적 강제 전제

증상:

NixOS에서 system `bwrap`이 PATH에 없으면 `codex exec -s read-only` / `-s workspace-write`가
bubblewrap 의존 경로를 밟는다. 보고된 즉시 panic 문구:

```
bubblewrap is unavailable: no system bwrap was found on PATH
```

재확인: 2026-07-06, codex-cli 0.142.5, 현재 MiniPC PATH에 system `bwrap` 없음.
이 환경에서는 위 panic 대신 다음 warning 후 bundled bubblewrap fallback으로 진행됨을 확인했다:

```
warning: Codex could not find bubblewrap on PATH. Install bubblewrap with your OS package manager. See the sandbox prerequisites: https://developers.openai.com/codex/concepts/sandboxing#prerequisites. Codex will use the bundled bubblewrap in the meantime.
```

해결: NixOS 공통 시스템 패키지에 `bubblewrap`을 설치한다. 배포 전 임시 실측은 아래처럼
`nix shell`로 PATH에 bwrap을 주입해 수행한다:

```bash
nix shell nixpkgs#bubblewrap --command env CODEX_PROGRAMMATIC=1 codex exec -s workspace-write "짧은 sandbox smoke test"
```

배포 전 실측 매트릭스 (2026-07-06, codex-cli 0.142.5, `nixpkgs#bubblewrap` = 0.11.2):

| tier | 읽기 (`modules/nixos/configuration.nix`) | 워크트리 쓰기 | 워크트리 밖 `/tmp` 쓰기 | 네트워크 (`curl -I --max-time 5 https://example.com`) | stderr sandbox 표기 |
|------|------|------|------|------|------|
| `read-only` | OK | BLOCKED | BLOCKED | BLOCKED | `sandbox: read-only` |
| `workspace-write` | OK | OK | OK | BLOCKED | `sandbox: workspace-write [workdir, /tmp, $TMPDIR]` |
| `danger-full-access` | OK | OK | OK | OK | `sandbox: danger-full-access` |
| config 기본값 (`-s` 생략) | OK | OK | OK | OK | `sandbox: danger-full-access` |

주의:
- `workspace-write`는 이름과 달리 `/tmp`와 `$TMPDIR`도 writable root로 열었다. 일반 `$HOME` 경로
  쓰기 차단은 이 세션의 "워크트리 밖 쓰기 시도는 `/tmp` 또는 워크트리 내부만 사용" 제한 때문에
  직접 시도하지 않았다.
- `read-only` / `workspace-write`에서는 네트워크가 차단되었고, `danger-full-access` 및 config 기본값에서는 허용되었다.
- `~/.codex/config.toml`의 `sandbox_mode = "danger-full-access"` 기본값은 이 이슈에서 변경하지 않는다.
- bwrap 안에서 Codex를 다시 실행하는 nested bwrap 우회는 초기화 실패로 기각됨
  (2026-07-09 실측). fan-out 전에 패턴 8 스모크를 1회 통과시킨다.

### 17. exec auth chain 우선순위와 login status 한계

심각도: 정보 — scratch `CODEX_HOME`이나 `--ignore-user-config`를 쓰는 자동화에서 auth 경계를 오해하면 `Not logged in` 또는 의도치 않은 계정 사용으로 실패한다.

운영 계약: `codex exec` 경로의 auth 우선순위는 `CODEX_API_KEY > ephemeral tokens > auth.json`이다. `OPENAI_API_KEY`는 exec auth chain에 참여하지 않으며, interactive TUI에서 API key 입력을 보조하는 prefill로만 취급한다.

전체 credential matrix는 재검증 미수행 (codex-cli 0.142.5 기준 서술 유지).

현재 CLI에서 실측 가능한 경계:
- `codex exec --help` (codex-cli 0.142.5, 2026-07-07)는 `--ignore-user-config`를 "`$CODEX_HOME/config.toml`은 로드하지 않지만 auth는 `CODEX_HOME`을 계속 사용"하는 플래그로 설명한다. 따라서 이 플래그는 MCP/config 표면 차단용이지 auth 차단용이 아니다.
- 빈 scratch `CODEX_HOME`에서 `codex login status`는 `Not logged in`을 반환했고, 같은 조건에 더미 `OPENAI_API_KEY`를 추가해도 결과는 바뀌지 않았다. host `CODEX_HOME`에서는 `Logged in using ChatGPT`가 반환되어, `auth.json`/저장된 ChatGPT token 계열은 `CODEX_HOME`에 묶여 있음을 확인했다.
- `CODEX_API_KEY`는 exec 전용 경로이므로 `codex login status`만으로 우선순위 전체를 검증하지 않는다. scratch `CODEX_HOME`을 쓰는 automation은 `CODEX_API_KEY`를 명시적으로 전달하거나, 필요한 경우 기존 `auth.json`을 scratch `CODEX_HOME`으로 복사한 뒤 `codex login status`로 저장 auth 존재만 확인한다.

재검증:

```bash
command codex exec --help | rg -- '--ignore-user-config|auth still uses'
tmp=$(mktemp -d /tmp/codex-auth-check-XXXXXX)
env CODEX_HOME="$tmp" codex login status
env CODEX_HOME="$tmp" OPENAI_API_KEY=sk-dummy codex login status
rm -rf "$tmp"
```

### 18. 중첩 Codex session 파일 쓰기 거부와 `sudo chown` 오진

심각도: 높음 — nested `codex exec`가 부모 sandbox 안에서 session 파일을 만들 때 발생

증상: CLI가 session 디렉토리 쓰기 실패 뒤 `sudo chown` 계열 소유권 수정을 제안할 수 있다.
중첩 실행 6회 실측에서는 실제 소유권 문제가 아니라 부모 Codex sandbox의 write denial이었다.
관측 출처: 실전 재발 사례.

진단 분기:

1. `id`와 `ls -ld "$CODEX_HOME" "$CODEX_HOME/sessions"`로 실제 owner/mode를 기록한다.
2. Direct Codex 세션 안의 nested 호출인지, 대상 경로가 부모 sandbox writable root 밖인지 확인한다.
3. 동일 사용자·동일 경로가 부모 sandbox 밖의 허용된 수동 진단에서 쓰기 가능하면 sandbox denial로
   판정하고 native subagent 또는 승인된 supervised 경로로 라우팅한다.
4. 실제 owner 불일치가 독립적으로 확인될 때만 사용자에게 별도 복구 작업을 보고한다.

CLI 제안만 보고 `sudo chown`을 실행하지 않는다. 소유권 변경은 host mutation이며 부모 sandbox
denial을 해결하지 못하고 정상 파일의 owner를 훼손할 수 있다.

### 19. codex exec `--json`이 multi-agent spawn/child 이벤트를 노출하지 않음 (관측성 한계)

심각도: 중간 — 공개 `--json`만 보면 spawn이 실패한 것으로 오판해, 이미 실행된 child 작업을 중복 실행할 수 있다

- 확인: 2026-07-11, codex-cli 0.144.1 (아래 모델·child 이름 등 관측값은 실행마다 다를 수 있다)
- 재검증: 아래 probe. 공개 `--json`의 `receiver_thread_ids`가 `[]`여도 persisted rollout에는
  `spawn_agent` 호출이 기록됨을 확인한다.

사실 vs 한계: `codex exec`에서 multi-agent(`collaboration.spawn_agent`)는 정상 작동한다 — reasoning effort와
무관하게, 모델이 `spawn_agent`를 호출하면 child agent가 실제로 생성·실행되고 부모에게 결과를 전달한다(실측에서
child 2개가 생성돼 각자 응답을 부모에 전달, `wait_agent`가 `timed_out:false`로 종료). 그러나 `codex exec --json`
이벤트 stream(공개 stdout)은 이 spawn/child 이벤트를 노출하지 않는다. 공개 `--json`에는 최종 `collab_tool_call`
(event label `tool:"wait"`)과 `agent_message`만 보이고, 그 wait 이벤트의 `receiver_thread_ids`는 `[]`다. 이 빈
값은 wait 이벤트에 붙은 필드일 뿐 spawn 성공/실패와 무관하다.

오판 주의: 공개 `--json`의 빈 `receiver_thread_ids`를 "spawn 실패"로 해석하지 마라. child가 이미 실행됐을 수
있으므로 재시도하면 작업이 중복 실행된다. 반대로 모델의 "spawned" 자기보고는 실제 spawn과 일치할 수 있고, 공개
`--json`의 빈 필드가 그 반증이 되지 않는다. 실제 spawn 여부는 아래 persisted rollout으로만 판정한다.

실제 확인 경로 — persisted rollout session: codex는 `--ephemeral`이 아니면 세션마다
`~/.codex/sessions/<YYYY>/<MM>/<DD>/rollout-*.jsonl`에 전체 이벤트를 저장한다. 여기엔 공개 `--json`에 없는
`spawn_agent` `function_call`, `sub_agent_activity`, `inter_agent_communication_metadata`, `wait_agent`
output이 기록된다. 이름은 세 층위로 다르다: 모델-facing tool 이름은 `collaboration.spawn_agent`(다른 협업 tool도
같은 `collaboration.*` namespace), 공개 `--json` event label은 축약된 `tool:"wait"`, persisted rollout JSONL의
`function_call`은 `name`이 `collaboration.` prefix 없이 `spawn_agent`이고 `namespace`가 별도로 `collaboration`이다.
아래 probe는 이 세 번째 형태를 jq로 파싱한다(`.payload.name == "spawn_agent"`를 세고, 공개 `--json`은 `.item.receiver_thread_ids`를
추출) — grep 리터럴은 JSON 공백/직렬화 차이에 취약하므로 쓰지 않는다. 비대화형에서 spawn/진행을 판정하려면
공개 `--json`이 아니라 이 rollout을 파싱하거나 최종 산출물로 판정한다.

재검증 (stdout/stderr/exit 분리, persisted rollout 대조):

```zsh
set -o pipefail
TMP=$(mktemp -d "${TMPDIR:-/tmp}/codex-spawn-probe-XXXXXX")   # 공유 /tmp symlink 회피
command codex features list | grep -E '^multi_agent[[:space:]]'   # 예: "multi_agent  stable  true" 한 줄이 나와야 전제 성립
printf 'Spawn two subagents in parallel: agent1 replies ALPHA, agent2 replies BRAVO. Report both.\n' > "$TMP/prompt.md"
for eff in ultra high; do   # 두 effort 모두 같은 관측성 한계를 보이는지 확인
  cat "$TMP/prompt.md" | env CODEX_PROGRAMMATIC=1 codex exec -s read-only --json \
    -c model_reasoning_effort="$eff" - > "$TMP/$eff.jsonl" 2> "$TMP/$eff.err"
  rc=$pipestatus[2]   # zsh 파이프 2번째(codex). bash에서는 이 펜스를 bash로 바꾸고 ${PIPESTATUS[1]} 사용
  tid=$(head -1 "$TMP/$eff.jsonl" | jq -r '.thread_id')
  pub=$(jq -R 'fromjson? | select(.item.receiver_thread_ids != null) | .item.receiver_thread_ids' "$TMP/$eff.jsonl" 2>/dev/null | head -1)   # 공개 --json: wait 이벤트의 배열(빈 값 기대)
  roll=$(find "$HOME/.codex/sessions" -name "*$tid*" 2>/dev/null | head -1)
  if [ -z "$roll" ]; then roll=notfound; spawns=0
  else spawns=$(jq -R 'fromjson? | select(.payload.type=="function_call" and .payload.name=="spawn_agent")' "$roll" 2>/dev/null | jq -s 'length'); : "${spawns:=0}"; fi
  printf '%s: rc=%s public_receiver=%s roll=%s persisted_spawn_agent_calls=%s\n' \
    "$eff" "$rc" "${pub:-none}" "$roll" "$spawns"
done
```

기대: 각 effort에서 `rc=0`, `public_receiver`는 빈 배열 `[]`, `roll`은 실제 경로,
`persisted_spawn_agent_calls`가 1 이상 — 공개 필드가 비어도 persisted에 `spawn_agent` 호출이 있으면 이 한계가
재현된 것이다. 진단: `features list`에 `multi_agent`가 `stable`/`true`로 나오지 않으면 probe 전제가 깨진 것이고,
`roll=notfound`면 `tid` 추출/`find` 경로 문제(probe 인프라 실패)이며, `roll`은 있는데 `spawns=0`이면 이 한계가
아닌 별개 실패이므로 `$TMP/$eff.err`를 확인한다.

대안: 비대화형에서 spawn 진행을 프로그램적으로 관측·판정해야 하면 공개 `--json`에 의존하지 말고 persisted
rollout을 파싱한다. 또는 세션 내 오케스트레이션 대신, [`run-da`의 fallback 계약](../../run-da/references/hardening-contract.md)에 따라
사용자 승인 후 `codex-exec-supervised --sandbox read-only`로 별도 `codex exec` 프로세스를 독립 실행해 관측 가능한 병렬화를 쓴다.
Direct Codex가 라우팅·승인·쓰기 경계를 우회하는 raw 또는 임의 병렬 `codex exec` 실행을 해서는 안 된다.
