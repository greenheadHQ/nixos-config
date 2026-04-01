# using-codex-exec 제한사항 및 트러블슈팅

Codex CLI의 알려진 제한사항, 미해결 이슈, 실행 실패 대응 절차를 통합 관리한다.

## 0. 공통 진단

실패 시 아래 명령으로 환경을 먼저 확인한다:

```bash
codex --version
codex exec --help
codex exec review --help
pwd
git rev-parse --show-toplevel
```

- CLI 버전/옵션 존재 여부 확인
- 저장소 루트 밖에서 실행 중인지 확인
- 워크트리(worktree) 환경이면 `git rev-parse --git-dir`로 git 디렉토리 경로 확인

---

## 알려진 제한사항 (Known Limitations)

### 1. review에서 PROMPT과 scope flag 동시 사용 불가

**심각도**: 치명적 — 스킬 사용 시 가장 빈번하게 부딪히는 제약

**증상**:

```
error: the argument '[PROMPT]' cannot be used with '--base <BRANCH>'
error: the argument '[PROMPT]' cannot be used with '--uncommitted'
error: the argument '[PROMPT]' cannot be used with '--commit <SHA>'
```

**근본 원인 — 소스코드 레벨 분석**:

Codex CLI의 `codex-rs/protocol/src/protocol.rs`에서 `ReviewTarget`이 **enum**으로 정의되어 있다:

```rust
pub enum ReviewTarget {
    UncommittedChanges,
    BaseBranch { branch: String },
    Commit { sha: String, title: Option<String> },
    Custom { instructions: String },
}
```

4개 변형(variant)이 상호 배타적이며, `ReviewRequest` 구조체에 `additional_instructions` 필드가 **존재하지 않는다**. 따라서 `Custom` variant(사용자 PROMPT)와 나머지 preset variant(`BaseBranch`, `UncommittedChanges`, `Commit`)를 동시에 선택할 수 없다.

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

**이슈 추적**:

| 이슈/PR | 상태 | 설명 |
|---------|------|------|
| [#7825](https://github.com/openai/codex/issues/7825) | **OPEN** (2025-12-10~) | PROMPT + scope flag 조합 기능 요청. 커뮤니티 확인됨. |
| [#11903](https://github.com/openai/codex/pull/11903) | **CLOSED** (미머지, 2026-02-16) | `additional_instructions: Option<String>`을 `ReviewRequest`에 추가하는 PR. `ReviewTarget` 해석 후 비어있지 않은 추가 지시를 append하는 구현. invitation-only 기여 정책으로 close됨. |
| [#6432](https://github.com/openai/codex/issues/6432) | **OPEN** (2025-11-09~) | headless review 전체 제안. `custom [PROMPT\|-]` preset 포함. 부분 구현 상태. |

**커뮤니티 프로토타입**:
- @agisilaos의 포크: https://github.com/agisilaos/codex/compare/main...feat/review-optional-comments-clean
- 3개 커밋으로 `additional_instructions`를 protocol/core/TUI/app-server/exec 전체에 전파하는 구현.

**대안**:
- SKILL.md 의사결정 트리의 "방법 A" (AGENTS.md) 또는 "방법 B" (exec 우회) 참조.
- 향후 CLI 업데이트로 이 제약이 해소될 수 있으므로, `codex exec review --help` 출력을 주기적으로 재확인한다.

**재검증 방법**: 아래 명령이 에러 없이 실행되면 제약이 해소된 것이다:

```bash
echo "test" | codex exec review - --base main --full-auto 2>&1 | head -5
```

### 2. review `-o` upstream bug — 빈 파일 생성

**심각도**: 높음

**관찰된 동작**: `-o` 사용 시 `Warning: no last agent message; wrote empty content` 출력, 0바이트 파일 생성 (v0.114.0에서 직접 재현)

**참고**: `-o`(`--output-last-message`)는 `codex exec review --help`에 표시되므로 CLI 파서는 인자를 수용한다. 문제는 `ReviewTask::run()`이 None을 반환하여 빈 파일이 생성되는 것이다.

**관련 GitHub Issues**:

| 이슈 | 상태 | 설명 |
|------|------|------|
| [#12502](https://github.com/openai/codex/issues/12502) | **OPEN** (2026-02-22~) | review `-o` 빈 파일 생성 보고 |
| [#14335](https://github.com/openai/codex/issues/14335) | **OPEN** (2026-03-11~) | 동일 증상 재보고 |

**영향 범위**: v0.104.0 ~ v0.115.0-alpha (직접 검증 기준)

**재현**:

```bash
echo "test" | codex exec review - --full-auto -o /tmp/test.md 2>&1
# → 0바이트 파일 + "Warning: no last agent message; wrote empty content"
```

**워크어라운드**: stdout 리다이렉트로 대체한다:

```bash
codex exec review --base main --full-auto > /tmp/review-result.md 2>&1
```

**재검증 방법**: 아래 명령으로 `-o`가 비어있지 않은 파일을 생성하면 수정된 것이다:

```bash
echo "test" | codex exec review - --full-auto -o /tmp/test.md 2>&1 && [ -s /tmp/test.md ] && echo "FIXED" || echo "STILL BROKEN"
```

### 3. review가 working-tree 변경을 잘못 포함

**심각도**: 중간

**이슈**: [#8404](https://github.com/openai/codex/issues/8404) (OPEN)

**증상**: `--base` 리뷰 시 현재 브랜치의 커밋된 변경뿐 아니라, 워킹트리의 미커밋 변경까지 리뷰 대상에 포함되는 경우가 있다. 실제 diff에 없는 내용에 대한 hallucinated finding이 나타날 수 있다.

**대안**:
- 리뷰 전 워킹트리를 깨끗한 상태로 만든다 (`git stash`).
- 리뷰 결과를 실제 diff와 대조하여 검증한다.

### 4. exec review가 공식 CLI reference에 미문서화

**심각도**: 정보

`codex exec review`는 부분적으로 구현되어 작동하지만, OpenAI의 공식 CLI reference (https://developers.openai.com/codex/cli/reference/) 에는 문서화되어 있지 않다. 공식 문서가 권장하는 headless code review 방식은:

1. `codex exec "Review my pull request!"` + `--output-schema` (구조화 출력)
2. `openai/codex-action@v1` GitHub Action

이 스킬에서는 현실적으로 작동하는 `codex exec review`를 다루되, 공식 지원 상태가 변할 수 있음을 인지한다.

---

## 트러블슈팅

### 5. `unexpected argument '--approval-mode' found`

**원인**: `codex exec`는 `--approval-mode` 플래그를 받지 않는다.

**해결**: 자동 실행이 필요하면 `--full-auto`를 사용한다. 세밀한 승인/샌드박스 조정은 `-c key=value`로 처리한다.

### 6. 결과 파일이 비어 있음 (`-o` 사용 시)

**증상**: `-o /tmp/result.md` 파일은 생성되지만 내용이 비어 있거나 기대보다 짧다.

**원인**:
- 실행이 중간 실패하여 마지막 에이전트 메시지가 없을 수 있다.
- `Warning: no last agent message; wrote empty content` 경고가 stderr에 출력된다.
- **review 서브커맨드에서 `-o` 사용 시**: upstream bug #12502로 항상 빈 파일 생성. §2 참조.

**해결**:
1. `2>&1`로 stderr를 함께 캡처한다.
2. review에서는 `-o` 대신 stdout 리다이렉트(`> file 2>&1`)를 사용한다.
3. 프롬프트 파일 내용이 비어 있지 않은지 확인한다.
4. 상위 오류(`model is not supported` 등)를 먼저 해결한다.
5. 최소 프롬프트(패턴 8 스모크 테스트)로 재현 범위를 줄인다.

### 7. stdin 입력이 멈춘 것처럼 보임

**원인**:
- stdin 파이프가 실제로 입력을 전달하지 못했을 수 있다.
- 파이프 앞 명령이 실패했는데 종료 코드 확인 없이 진행했을 수 있다.

**해결**:
1. 먼저 입력 파일을 출력하여 내용 존재를 확인한다:
   ```bash
   cat /tmp/prompt.md
   ```
2. 인라인 프롬프트로 비교 실행한다:
   ```bash
   codex exec --full-auto "짧은 스모크 테스트"
   ```

### 8. Git 저장소 체크 실패

**원인**: `codex exec` 기본 동작은 git 저장소 컨텍스트를 기대한다.

**해결**:
1. 저장소 루트로 이동하여 실행한다 (권장):
   ```bash
   cd "$(git rev-parse --show-toplevel)"
   ```
2. 저장소 외 실행이 꼭 필요하면 `--skip-git-repo-check`를 사용한다.

### 9. `model is not supported` 오류

**증상**:

```
ERROR: {"detail":"The '<model>' model is not supported when using Codex with a ChatGPT account."}
```

**원인**: Codex 모델 라인업에 포함되지 않은 모델(`o3`, `o4-mini`, `gpt-4.1` 등)을 `-m`으로 지정했다. ChatGPT 계정에서만 발생하며, "Model metadata not found" 경고(§10)가 선행한다.

**해결**:
1. `-m`을 제거하고 기본 모델(`~/.codex/config.toml`)로 재시도한다.
2. 동일 오류 반복 시 `codex exec --help`와 계정 모델 접근 정책을 확인한다.

### 10. `Model metadata ... not found` 경고

**증상**:

```
warning: Model metadata for `<model>` not found. Defaulting to fallback metadata; this can degrade performance and cause issues.
```

**원인**: 지정한 모델이 CLI의 내장 모델 레지스트리에 없다. Codex 라인업 외 모델(`o3`, `o4-mini`, `gpt-4.1` 등) 지정 시 항상 발생하며, §9 에러와 함께 나타난다.

**해결**: `-m`을 제거하거나 `config.toml`의 기본 모델로 되돌린다.

---

## 워크트리(Worktree) 환경 참고사항

git worktree 환경에서 `codex exec`를 실행할 때:

- **codex exec 자체는 정상 동작한다**: worktree도 완전한 git working directory이므로, `git diff`, `git merge-base` 등이 동일하게 작동한다.
- **`--base` 동작은 동일하다**: worktree에서도 `origin/main...HEAD` diff가 정상 계산된다.
- **detached HEAD 주의**: worktree가 detached HEAD 상태이면 브랜치 기반 비교가 실패할 수 있다. `git branch --show-current`로 브랜치 상태를 확인한다.
- **Codex App의 worktree 버그는 codex exec와 무관하다**: Codex App(GUI)에는 다수의 worktree 관련 버그(cross-worktree writes, UI freeze 등)가 보고되어 있으나, 이는 CLI exec 실행에 영향을 주지 않는다.

---

## 재현 가능한 최소 실행으로 복구

실패가 반복될 때 아래 명령으로 기본 동작을 확인한다:

```bash
cat > /tmp/smoke.md <<'PROMPT'
현재 작업 디렉토리에서 가장 중요한 리스크 1개만 한 줄로 답한다.
PROMPT
```

**⚠️ `run_in_background` 환경**: 여기서 Bash tool 호출을 종료하고, 아래를 별도 호출로 실행한다 (§11 하위 항목).

```bash
cat /tmp/smoke.md | codex exec --full-auto -o /tmp/smoke-result.md 2>&1
cat /tmp/smoke-result.md
```

통과하면 기존 복잡한 프롬프트로 단계적으로 복귀한다.
실패하면 §0 공통 진단부터 다시 시작한다.

---

### 11. Claude Code Bash tool sandbox 제약

**심각도**: 치명적 — Bash tool에서 codex exec 병렬 실행 시 반드시 적용

**관찰된 동작** (2026-03-29 재현):

| 방식 | 결과 | 원인 |
|------|------|------|
| `&` + `$!` (background PID) | **BROKEN** | `$!` → 리터럴 문자열, PID 미캡처 |
| `cat file \| codex exec` (stdin pipe) 다수 병렬 | **불안정** | stdin 경합으로 프롬프트 누락 |
| `codex exec "$(cat file)"` (인라인 인자) | **OK** | shell 확장 후 인자 전달 |
| `codex exec < file` (file redirect) | **OK** | 정상 작동 |
| 병렬 Bash tool 호출 (foreground) | **OK** | tool-level 병렬화, 전부 완료까지 대기 |
| Bash tool `run_in_background: true` | **OK** | background 실행, 각 완료 시 자동 알림 |

**영향 범위**: Claude Code Bash tool sandbox 전용. 일반 터미널에서는 모든 방식 정상 작동.

**근본 원인**:
- Bash tool은 각 호출을 격리된 shell에서 실행하며, background process와 job control이 제한됨.
- `$!`가 변수 확장되지 않고 리터럴로 처리됨.
- 다수 Bash tool 호출이 동시에 stdin pipe를 사용하면 경합 발생 가능.

**올바른 패턴** — codex exec 병렬 실행:

1. 프롬프트 파일을 1개 Bash call로 생성:
   ```bash
   DA_DIR=$(mktemp -d /tmp/da-XXXXXX)
   cat > "$DA_DIR/domain.md" <<'PROMPT'
   ...프롬프트 내용...
   PROMPT
   ```

2. 각 codex exec를 별도 Bash tool 호출로 병렬 실행 (8개 동시):
   ```bash
   codex exec --full-auto --ephemeral \
     -o "$DA_DIR/domain-result.md" \
     "$(cat "$DA_DIR/domain.md")" \
     2>"$DA_DIR/domain-stderr.log"
   ```

3. 모든 Bash tool 호출 완료 후 결과 수집.

**Background 대안** — 다수 병렬 실행 시 LLM 블로킹 방지:

2b. 각 codex exec를 Bash tool `run_in_background: true`로 실행:
    ```bash
    # Bash tool 호출 시 run_in_background: true 파라미터 사용
    codex exec --full-auto --ephemeral \
      -o "$DA_DIR/domain-result.md" \
      "$(cat "$DA_DIR/domain.md")" \
      2>"$DA_DIR/domain-stderr.log"
    ```
    - LLM이 즉시 반환받아 사용자와 대화 가능
    - 각 완료 시 자동 알림 수신 (sleep/poll 금지)
    - 모든 완료 알림 수신 후 결과 파일 일괄 수집

3b. foreground와 동일하게 결과 파일로 수집. `-o` 결과 파일은 프로세스 종료 시 생성됨.

**금지 패턴**:
- `&` + `wait` + `$!` (shell-level background)
- 8개 동시 stdin pipe (`cat file | codex exec`)
- here-doc + pipe 조합의 다수 병렬
- heredoc + codex exec 체이닝 (같은 Bash 호출에서 `run_in_background` 사용 시 — 하위 항목 참조)
- Bash tool `run_in_background: true` 사용 후 sleep/poll로 완료 확인 (알림이 자동으로 옴)

**재검증 방법**:
```bash
sleep 0.1 &
echo "PID: $!"
# "PID: $!" (리터럴) → sandbox 제약 유효
# "PID: 12345" (숫자) → sandbox 제약 해소
```

#### heredoc + codex exec 체이닝 시 hang (run_in_background 환경)

**심각도**: 높음 — `run_in_background: true`에서 heredoc으로 파일 생성 후 같은 Bash 호출에서 codex exec를 이어 실행하는 경우에 적용

**증상**: `run_in_background: true`로 실행한 Bash 호출에서 heredoc으로 파일을 생성한 뒤 같은 호출에서 codex exec를 실행하면, codex가 무한 대기.

**관찰된 동작**: 특정 Bash tool sandbox 구성에서 heredoc과 codex exec를 같은 호출에 체이닝하면 hang이 발생한다. 정확한 메커니즘은 미확정이나, heredoc이 stdin 상태에 영향을 주어 후속 codex exec가 추가 입력을 기다리는 것으로 추정된다. `run_in_background` 환경에서만 발생하며, 일반 터미널에서는 재현되지 않는다.

**재현** (codex-cli v0.118.0, 2026-04-01 확인):

HANG — heredoc 체이닝 (같은 Bash 호출):
```bash
(umask 077; TDIR=$(mktemp -d /tmp/test-XXXXXX) && cat > "$TDIR/prompt.md" <<'EOF'
테스트 프롬프트
EOF
codex exec --full-auto --ephemeral -o "$TDIR/result.md" "$(cat "$TDIR/prompt.md")")
# → 무한 대기
```

OK — 별도 Bash 호출로 분리:

**1. Bash tool 호출 1**: 프롬프트 파일 생성 (경로 출력)
```bash
TDIR=$(mktemp -d /tmp/test-XXXXXX) && cat > "$TDIR/prompt.md" <<'EOF'
테스트 프롬프트
EOF
echo "$TDIR"
# → /tmp/test-a1b2c3 (이 경로를 다음 호출에서 사용)
```

**2. Bash tool 호출 2**: codex exec 실행 (경로 직접 지정)
```bash
codex exec --full-auto --ephemeral \
  -o /tmp/test-a1b2c3/result.md \
  "$(cat /tmp/test-a1b2c3/prompt.md)"
```

**올바른 패턴**: 프롬프트 파일 생성과 codex exec를 별도 Bash tool 호출로 분리한다. §11 본문의 "올바른 패턴"과 동일 원리. 호출 간 상태 공유는 파일 경로를 통해서만 한다 (셸 변수는 호출 간 유지되지 않으므로, 1단계에서 출력한 경로를 2단계에서 직접 사용).

**§11 본문과의 관계**: §11은 `& + wait` shell-level 병렬과 다수 stdin pipe 경합의 제약이고, 이 항목은 heredoc 체이닝의 stdin 관련 문제이다. 원인은 다르지만 해결 패턴(별도 Bash tool 호출 분리)은 동일하다.
