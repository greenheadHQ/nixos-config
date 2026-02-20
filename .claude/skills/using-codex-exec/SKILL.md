---
name: using-codex-exec
description: |
  This skill should be used when the user needs reliable Codex CLI
  non-interactive execution in Claude Code sessions. Triggers: "codex exec",
  "codex 실행", "codex CLI", "비대화형 codex", "non-interactive codex",
  "codex review".
---

# Codex Exec 사용

Claude Code 세션 내부에서 `codex exec`를 정확하고 반복 가능하게 실행하는 절차를 다룬다.

## 목적과 범위

- `codex exec` 비대화형 실행 명령을 안정적으로 구성한다.
- 표준 입력(stdin) 기반 프롬프트 전달 패턴을 사용한다.
- 결과 파일 저장(`-o`)과 자동화(JSONL) 출력(`--json`)을 분리해 관리한다.
- 코드 리뷰 서브커맨드(`codex exec review`)의 기본 사용법을 제공한다.

대화형 TUI 사용법, Codex 설정 파일의 전체 관리, Claude 하네스 투영은 이 스킬의 범위를 벗어난다.
해당 주제는 `configuring-codex`, `syncing-codex-harness`를 사용한다.

## 작성 기준

- 확인 날짜: **2026-02-20**
- 확인 버전: **`codex-cli 0.104.0`**
- 재검증 명령:

```bash
codex --version
codex exec --help
codex exec review --help
```

CLI 버전이 바뀌면 플래그/동작이 달라질 수 있으므로, 실행 전 도움말을 다시 확인한다.

## 빠른 참조

| 상황 | 권장 명령 |
|------|-----------|
| 프롬프트 파일을 stdin으로 전달 | `cat /tmp/prompt.md \| codex exec --full-auto -o /tmp/result.md 2>&1` |
| 즉시 한 줄 프롬프트 실행 | `codex exec --full-auto "변경사항 위험 요인 3개만 정리"` |
| 세션 파일 없이 1회성 실행 | `codex exec --full-auto --ephemeral "..."` |
| 이벤트 스트림 자동화(JSONL) | `codex exec --full-auto --json "..."` |
| 브랜치 비교 코드 리뷰 | `codex exec review --base main --full-auto` |
| 워킹트리 리뷰 | `codex exec review --uncommitted --full-auto` |

## 핵심 플래그

| 플래그 | 의미 | 운영 원칙 |
|--------|------|-----------|
| `--full-auto` | 자동 실행 편의 별칭 | 기본 실행값으로 사용 |
| `-m <MODEL>` | 모델 지정 | 기본적으로 생략하고 기본 모델 사용 |
| `-o <FILE>` | 마지막 에이전트 메시지 저장 | 결과 보존이 필요하면 항상 지정 |
| `--ephemeral` | 세션 파일 미저장 | 일회성/민감 프롬프트에서 사용 |
| `--json` | JSONL 이벤트 출력 | 파이프라인 연동 시만 사용 |
| `-` (PROMPT 위치) | stdin에서 프롬프트 읽기 | 파이프 입력 시 명시 가능 |
| `--skip-git-repo-check` | git 저장소 체크 건너뜀 | 저장소 외 실행이 필요한 경우에만 사용 |

## 모델 사용 원칙

- 기본 모델은 `~/.codex/config.toml`의 `model` 값을 따른다.
- 이 저장소 기본값은 `gpt-5.3-codex`다.
- 실무 기본 원칙:
  1. 우선 `-m`을 생략한다.
  2. 공통 기준이 필요한 경우에만 `-m gpt-5.3-codex`를 명시한다.
  3. 팀 문서/스크립트에는 모델명을 혼합 표기하지 않는다.

### 모델 호환성 주의사항

- 계정/구독 조건에 따라 일부 모델은 실행 불가할 수 있다.
- 실행 불가 모델 지정 시 `"model is not supported"` 오류가 발생한다.
- 해당 오류가 나면 `-m`을 제거해 기본 모델로 재시도한다.
- 상세 복구 절차는 [references/troubleshooting.md](references/troubleshooting.md)를 따른다.

## 표준 실행 절차

1. 프롬프트를 파일로 준비한다.
2. stdin 파이프로 `codex exec`에 전달한다.
3. `-o`로 결과 파일을 저장한다.
4. 결과 파일을 읽고 다음 라운드 입력을 구성한다.
5. 필요 시 `--ephemeral` 또는 `--json`을 추가한다.

기본 템플릿:

```bash
cat /tmp/prompt.md | codex exec --full-auto -o /tmp/result.md 2>&1
```

## 입력 패턴

### 패턴 A: 파일 -> stdin 파이프 (기본)

```bash
cat /tmp/prompt.md | codex exec --full-auto -o /tmp/result.md 2>&1
```

장점:
- 프롬프트 이력 파일 관리가 쉽다.
- Claude Code/터미널 환경 모두에서 재현 가능하다.
- 결과 파일(`-o`)과 분리해 루프를 구성하기 쉽다.

### 패턴 B: heredoc으로 프롬프트 생성 후 실행

```bash
cat > /tmp/prompt.md <<'PROMPT'
다음 diff를 검토하고, 실제 배포 리스크만 5개 이내로 지적한다.
PROMPT

cat /tmp/prompt.md | codex exec --full-auto -o /tmp/result.md 2>&1
```

장점:
- 임시 프롬프트를 빠르게 생성 가능하다.
- 명령 이력만으로 재현이 가능하다.

### 패턴 C: 인라인 프롬프트 (짧은 질의)

```bash
codex exec --full-auto "git diff 기준으로 회귀 가능성 한 줄 요약"
```

장점:
- 단문 질의에서 가장 빠르다.

주의:
- 긴 지시문, 구조화된 체크리스트에는 파일 기반 패턴을 우선한다.

## 출력 패턴

### 결과 메시지 파일 저장

```bash
cat /tmp/prompt.md | codex exec --full-auto -o /tmp/result.md 2>&1
```

`-o`는 마지막 에이전트 메시지를 파일로 저장한다.
장기 루프(검토 -> 수정 -> 재검토)에서는 필수로 사용한다.

### 이벤트 스트림(JSONL)

```bash
codex exec --full-auto --json "현재 변경의 배포 체크리스트 생성"
```

`--json`은 파이프라인 수집/파싱 용도로만 사용한다.
일반 수동 사용에서는 가독성 때문에 기본 출력 모드를 유지한다.

## codex exec review 기본 사용

코드 리뷰는 일반 `exec` 프롬프트보다 `review` 서브커맨드를 우선한다.

### 브랜치 기준 리뷰

```bash
codex exec review --base main --full-auto
```

현재 브랜치를 `main`과 비교해 리뷰한다.

### 워킹트리 리뷰

```bash
codex exec review --uncommitted --full-auto
```

staged/unstaged/untracked 변경을 함께 리뷰한다.

### 특정 커밋 리뷰

```bash
codex exec review --commit <sha> --full-auto
```

단일 커밋의 변경을 리뷰한다.

### 커스텀 지시 추가

```bash
cat /tmp/review-instruction.md | codex exec review - --base main --full-auto
```

`-`를 사용해 stdin 지시를 추가한다.

## 운영 체크리스트

실행 전:
- `codex --version`이 기대 버전인지 확인한다.
- 현재 디렉토리가 대상 저장소 루트인지 확인한다.
- 프롬프트 파일 경로와 결과 파일 경로를 분리한다.

실행 후:
- `-o` 결과 파일이 생성되었는지 확인한다.
- 결과가 비어 있으면 stderr 로그부터 확인한다.
- 다음 라운드 입력에 반영할 액션 항목만 추린다.

## 하지 말아야 할 패턴

- `codex exec` 일반 실행에 존재하지 않는 플래그를 임의로 추가하지 않는다.
- 모델명을 매번 다르게 혼용하지 않는다.
- 긴 검토 루프에서 결과를 콘솔에만 남기고 파일 저장을 생략하지 않는다.
- 실패 원인을 확인하기 전에 명령을 반복 재시도하지 않는다.

## 트러블슈팅/예제 참조

- 실패 대응 절차: [references/troubleshooting.md](references/troubleshooting.md)
- 실전 명령 모음: [references/examples.md](references/examples.md)

작업 도중 불일치가 보이면 현재 도움말(`codex exec --help`)을 우선 진실 원천으로 사용한다.
