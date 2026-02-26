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

### 2. review에서 -o (--output-last-message) 미지원

**심각도**: 높음

**증상**:

```
error: unexpected argument '-o' found
```

**원인**: `-o`(`--output-last-message`)는 `codex exec` 전용 플래그이며 `review` 서브커맨드의 인자 목록에 포함되지 않는다. `codex exec review --help` 출력에 `-o`가 없음으로 확인 가능.

**대안**: stdout 리다이렉트로 대체한다:

```bash
codex exec review --base main --full-auto > /tmp/review-result.md 2>&1
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

**해결**:
1. `2>&1`로 stderr를 함께 캡처한다.
2. 프롬프트 파일 내용이 비어 있지 않은지 확인한다.
3. 상위 오류(`model is not supported` 등)를 먼저 해결한다.
4. 최소 프롬프트(패턴 8 스모크 테스트)로 재현 범위를 줄인다.

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

**원인**: 현재 계정에서 접근할 수 없는 모델을 `-m`으로 지정했다.

**해결**:
1. `-m`을 제거하고 기본 모델(`~/.codex/config.toml`)로 재시도한다.
2. 동일 오류 반복 시 `codex exec --help`와 계정 모델 접근 정책을 확인한다.

### 10. `Model metadata ... not found` 경고

**증상**:

```
warning: Model metadata for `<model>` not found. Defaulting to fallback metadata; this can degrade performance and cause issues.
```

**원인**: 지정한 모델의 메타데이터를 CLI가 찾지 못했다. 미지원/오타 모델 지정과 함께 나타난다.

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

cat /tmp/smoke.md | codex exec --full-auto -o /tmp/smoke-result.md 2>&1
cat /tmp/smoke-result.md
```

통과하면 기존 복잡한 프롬프트로 단계적으로 복귀한다.
실패하면 §0 공통 진단부터 다시 시작한다.
