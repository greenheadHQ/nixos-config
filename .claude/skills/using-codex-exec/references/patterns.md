# using-codex-exec 상황별 실행 패턴

각 패턴은 Claude Code 세션 안팎에서 동일하게 재현 가능한 순수 셸 명령으로 작성한다.

## 패턴 1: 기본 exec — 파일 프롬프트 → 결과 저장

가장 기본적인 실행 패턴. 프롬프트를 파일로 작성하고 stdin 파이프로 전달한다.

```bash
cat > /tmp/codex-prompt.md <<'PROMPT'
이 저장소의 현재 변경에서 운영 리스크를 3개 이내로 지적하고,
각 항목마다 재현 조건을 한 줄씩 적는다.
PROMPT

cat /tmp/codex-prompt.md | codex exec --full-auto -o /tmp/codex-result.md 2>&1
cat /tmp/codex-result.md
```

핵심 요소:
- `-o`: 마지막 에이전트 메시지를 파일로 저장. 루프 연동 시 필수.
- `2>&1`: stderr도 함께 캡처하여 실패 원인 추적에 활용.
- 인라인 프롬프트(`codex exec --full-auto "..."`)는 짧은 질의에만 사용.

## 패턴 2: 코드 리뷰 — scope flag만 사용 (커스텀 지시 불필요)

리뷰 대상을 scope flag으로 지정한다. 커스텀 지시가 필요 없는 경우.

### 브랜치 비교

```bash
codex exec review --base main --full-auto > /tmp/review.md 2>&1
```

현재 브랜치를 `main`과 비교하여 리뷰한다.

### 미커밋 변경

```bash
codex exec review --uncommitted --full-auto > /tmp/review.md 2>&1
```

staged/unstaged/untracked 변경을 함께 리뷰한다. 커밋 전 self-review에 적합.

### 특정 커밋

```bash
codex exec review --commit abc1234 --full-auto > /tmp/review.md 2>&1
codex exec review --commit abc1234 --title "Fix sandbox leak" --full-auto > /tmp/review.md 2>&1
```

`--title`은 `--commit`과 함께 사용하여 리뷰 요약에 커밋 제목을 표시한다.

### 주의사항

- **`-o` 미지원**: review 결과 저장은 반드시 stdout 리다이렉트(`> file 2>&1`)로 한다.
- **PROMPT 금지**: scope flag과 PROMPT은 상호 배타. 자세한 내용은 SKILL.md 호환성 매트릭스 참조.

## 패턴 3: 커스텀 리뷰 — AGENTS.md 활용 (영구 지시)

**사용 조건**: 프로젝트 전체에 일관된 리뷰 정책을 적용하고 싶을 때.

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
codex exec review --base main --full-auto > /tmp/review.md 2>&1
```

### 전역 정책 (모든 프로젝트에 적용)

`~/.codex/AGENTS.override.md`에 작성하면 모든 Codex 작업에 적용된다.
review뿐 아니라 모든 exec 실행에도 영향을 주므로 주의한다.

### Codex 지시 파일 우선순위

```
AGENTS.override.md > AGENTS.md > TEAM_GUIDE.md > .agents.md
```

디렉토리 트리 깊은 곳의 파일이 상위를 오버라이드한다.

## 패턴 4: 커스텀 리뷰 — exec 우회 (1회성 지시)

**사용 조건**: 이번 한 번만 특정 관점으로 리뷰하고 싶을 때.

review 서브커맨드를 사용하지 않고, `codex exec`에 diff와 커스텀 지시를 직접 전달한다.

### 기본 형태

```bash
cat > /tmp/review-prompt.md <<PROMPT
아래 diff를 리뷰한다. 회귀/사이드이펙트에 집중하고, style 코멘트는 제외한다.
각 지적마다 재현 조건을 명시한다.

$(git diff main...HEAD)
PROMPT

cat /tmp/review-prompt.md | codex exec --full-auto -o /tmp/review-result.md 2>&1
cat /tmp/review-result.md
```

### 미커밋 변경 리뷰

```bash
cat > /tmp/review-prompt.md <<PROMPT
아래 diff를 리뷰한다. 보안 취약점과 회귀에 집중한다.

$(git diff)
$(git diff --cached)
PROMPT

cat /tmp/review-prompt.md | codex exec --full-auto -o /tmp/review-result.md 2>&1
```

### 장점

- `-o`로 결과 저장 가능 (review 서브커맨드에서는 불가).
- 프롬프트 내용을 완전히 자유롭게 구성 가능.
- `--output-schema`와 조합하여 구조화된 JSON 출력도 가능.

### heredoc 따옴표 주의

이 패턴에서는 `<<PROMPT` (따옴표 없음)를 사용하여 `$(git diff ...)` 명령 치환이 실행되도록 한다.
리터럴 텍스트만 전달할 때는 `<<'PROMPT'` (따옴표 포함)를 사용한다.
패턴 1, 5, 8은 명령 치환이 불필요하므로 `<<'PROMPT'`를 사용한다.

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

cat /tmp/da-round1.md | codex exec --full-auto -o /tmp/da-round1-result.md 2>&1
cat /tmp/da-round1-result.md
```

### 후속 라운드

1. 결과에서 유효한 지적만 추린다.
2. 코드/문서를 수정한다.
3. 새 프롬프트 파일(`round2.md`)로 동일 구조를 반복한다:

```bash
cat > /tmp/da-round2.md <<'PROMPT'
이전 라운드에서 지적된 항목 중 아래를 수정했다:
- [수정 항목 나열]

남은 리스크가 있는지 재검토한다.
PROMPT

cat /tmp/da-round2.md | codex exec --full-auto -o /tmp/da-round2-result.md 2>&1
```

핵심: 매 라운드마다 `-o`로 결과를 파일 저장하여 이력을 보존한다.

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

cat > /tmp/review-prompt.md <<PROMPT
아래 diff를 리뷰하고, 결과를 지정된 스키마에 맞춰 출력한다.

$(git diff main...HEAD)
PROMPT

cat /tmp/review-prompt.md | codex exec --full-auto --output-schema /tmp/review-schema.json -o /tmp/review-structured.json 2>&1
```

주의: `--output-schema`는 exec 전용. review 서브커맨드에서 사용 불가.

## 패턴 7: JSONL 이벤트 스트림

자동화 파서와 연결하거나 실행 과정을 기록할 때 사용한다.

```bash
cat /tmp/prompt.md | codex exec --full-auto --json > /tmp/events.jsonl
```

주요 이벤트 타입:
- `thread.started` / `turn.started` / `turn.completed` / `turn.failed`
- `item.completed` (에이전트 메시지)

최종 요약문을 파일로도 보존하려면 `-o`를 별도로 함께 사용한다:

```bash
cat /tmp/prompt.md | codex exec --full-auto --json -o /tmp/result.md > /tmp/events.jsonl
```

## 패턴 8: 스모크 테스트

실행 환경 점검용 최소 예제. 실패가 반복될 때 이 명령으로 기본 동작을 먼저 확인한다.

```bash
cat > /tmp/smoke.md <<'PROMPT'
현재 디렉토리 기준으로 가장 중요한 리스크 1개만 한 줄로 답한다.
PROMPT

cat /tmp/smoke.md | codex exec --full-auto -o /tmp/smoke-result.md 2>&1
cat /tmp/smoke-result.md
```

성공 기준:
- 명령이 비정상 종료되지 않는다.
- 결과 파일이 생성되고 비어 있지 않다.

통과하면, 기존 복잡한 프롬프트로 단계적으로 복귀한다.

## 빠른 참조 표

| 상황 | 패턴 | 명령 요약 |
|------|------|-----------|
| 일반 실행 | 1 | `cat prompt \| codex exec --full-auto -o result` |
| 리뷰 (기본) | 2 | `codex exec review --base main --full-auto > result` |
| 리뷰 + 커스텀 지시 (영구) | 3 | AGENTS.md 작성 후 review --base |
| 리뷰 + 커스텀 지시 (1회) | 4 | `cat diff+지시 \| codex exec --full-auto -o result` |
| 피드백 루프 | 5 | 라운드별 prompt → exec -o → 분석 → 반복 |
| 구조화 출력 | 6 | `exec --output-schema schema.json -o result` |
| JSONL 스트림 | 7 | `exec --full-auto --json > events.jsonl` |
| 환경 점검 | 8 | 최소 프롬프트로 exec 스모크 테스트 |
