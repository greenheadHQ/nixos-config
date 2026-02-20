# using-codex-exec 트러블슈팅

`codex exec` 실행 실패 시, 아래 순서로 원인을 좁힌다.

## 0. 공통 진단

```bash
codex --version
codex exec --help
codex exec review --help
pwd
git rev-parse --show-toplevel
```

- CLI 버전/옵션 존재 여부를 먼저 확인한다.
- 저장소 루트 밖에서 실행 중인지 확인한다.

## 1. `unexpected argument '--approval-mode' found`

### 증상

```text
error: unexpected argument '--approval-mode' found
```

### 원인

- `codex exec`는 `--approval-mode` 플래그를 받지 않는다.

### 해결

- 자동 실행이 필요하면 `--full-auto`를 사용한다.
- 승인/샌드박스 조정은 `-c key=value` 또는 config 파일에서 처리한다.

예시:

```bash
cat /tmp/prompt.md | codex exec --full-auto -o /tmp/result.md 2>&1
```

## 2. 결과 파일이 비어 있음 (`-o` 사용 시)

### 증상

- `-o /tmp/result.md` 파일은 생성되지만 내용이 비어 있거나 기대보다 짧다.

### 원인

- 실행이 중간 실패해 마지막 에이전트 메시지가 없을 수 있다.
- 프롬프트 입력이 비어 있거나 명령 자체가 조기 종료되었을 수 있다.

### 해결

1. `2>&1`로 stderr를 함께 캡처한다.
2. 프롬프트 파일 내용이 비어 있지 않은지 확인한다.
3. 성공 최소 케이스로 재검증한다.

```bash
cat /tmp/prompt.md
cat /tmp/prompt.md | codex exec --full-auto -o /tmp/result.md 2>&1
```

## 3. stdin 입력이 멈춘 것처럼 보임

### 증상

- 실행이 시작되지만 응답 없이 대기 상태처럼 보인다.

### 원인

- stdin 파이프가 실제로 입력을 전달하지 못했을 수 있다.
- 파이프 앞 명령이 실패했는데 종료 코드 확인 없이 진행했을 수 있다.

### 해결

- 먼저 입력 파일을 출력해 내용 존재를 확인한다.
- 필요 시 `PROMPT` 인자를 직접 전달해 비교 실행한다.

```bash
cat /tmp/prompt.md
cat /tmp/prompt.md | codex exec --full-auto
codex exec --full-auto "짧은 스모크 테스트"
```

## 4. Git 저장소 체크 실패

### 증상

- 저장소 바깥 디렉토리에서 실행 시 git 관련 검사 오류가 발생한다.

### 원인

- `codex exec` 기본 동작은 git 저장소 컨텍스트를 기대한다.

### 해결

1. 저장소 루트로 이동해 실행한다 (권장).
2. 저장소 외 실행이 꼭 필요하면 `--skip-git-repo-check`를 사용한다.

```bash
cd "$(git rev-parse --show-toplevel)"
cat /tmp/prompt.md | codex exec --full-auto
```

## 5. `codex exec review` 결과가 기대와 다름

### 증상

- 리뷰 대상이 너무 넓거나 너무 좁게 잡힌다.

### 원인

- 리뷰 기준 옵션(`--base`, `--uncommitted`, `--commit`) 선택이 부정확하다.

### 해결

- PR 리뷰: `--base main`
- 로컬 변경 리뷰: `--uncommitted`
- 특정 커밋 리뷰: `--commit <sha>`

```bash
codex exec review --base main --full-auto
codex exec review --uncommitted --full-auto
codex exec review --commit <sha> --full-auto
```

## 6. `model is not supported` 오류

### 증상

```text
ERROR: {"detail":"The '<model>' model is not supported when using Codex with a ChatGPT account."}
```

### 원인

- 현재 계정에서 접근할 수 없는 모델을 `-m`으로 지정했다.
- 모델명을 오타로 지정했거나, 사용 가능한 모델 정책이 바뀌었을 수 있다.

### 해결

1. 우선 `-m`을 제거하고 기본 모델(`~/.codex/config.toml`)로 재시도한다.
2. 팀 표준 모델(`gpt-5.3-codex`)로 고정해 재실행한다.
3. 동일 오류가 반복되면 `codex exec --help`와 계정 측 모델 접근 정책을 확인한다.

```bash
cat /tmp/prompt.md | codex exec --full-auto -o /tmp/result.md 2>&1
cat /tmp/prompt.md | codex exec --full-auto -m gpt-5.3-codex -o /tmp/result.md 2>&1
```

## 7. `Warning: no last agent message` 경고

### 증상

```text
Warning: no last agent message; wrote empty content to /tmp/result.md
```

### 의미

- 실행이 실패/중단되어 마지막 에이전트 메시지가 생성되지 않았다.
- `-o` 파일이 비어 있어도 성공으로 오해하기 쉬운 유형이다.

### 해결

1. 반드시 `2>&1`로 stderr를 함께 저장해 실패 원인을 먼저 확인한다.
2. 상위 오류(`model is not supported` 등)를 해결한 뒤 재실행한다.
3. 최소 프롬프트(문서 하단 스모크)로 재현 범위를 줄인다.

## 8. `Model metadata ... not found` 경고

### 증상

```text
warning: Model metadata for `<model>` not found. Defaulting to fallback metadata; this can degrade performance and cause issues.
```

### 원인

- 지정한 모델의 메타데이터를 CLI가 찾지 못했다.
- 흔히 미지원/오타 모델 지정과 함께 나타난다.

### 해결

1. `-m`을 제거하거나 표준 모델(`gpt-5.3-codex`)로 바꾼다.
2. 모델명을 강제할 필요가 없다면 기본 모델 정책으로 되돌린다.
3. stdin/파이프 입력 관련 이상 징후가 있으면 **3번 섹션**을 함께 점검한다.

## 9. 재현 가능한 최소 실행으로 복구

실패가 반복될 때는 아래 최소 명령으로 상태를 리셋한다.

```bash
cat > /tmp/codex-smoke.md <<'PROMPT'
현재 작업 디렉토리에서 가장 중요한 리스크 1개만 한 줄로 답한다.
PROMPT

cat /tmp/codex-smoke.md | codex exec --full-auto -o /tmp/codex-smoke-result.md 2>&1
cat /tmp/codex-smoke-result.md
```

이 스모크가 통과하면, 기존 복잡한 프롬프트로 단계적으로 복귀한다.
