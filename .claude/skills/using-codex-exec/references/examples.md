# using-codex-exec 실전 예제

아래 예제는 Claude Code 세션 안팎에서 동일하게 재현 가능한 순수 셸 명령으로 작성한다.

## 1. Devil's Advocate 피드백 루프

프롬프트 파일을 만들고, stdin 파이프로 전달해 결과를 파일로 저장한다.

```bash
cat > /tmp/codex-da-round1.md <<'PROMPT'
You are a Devil's Advocate reviewer.
Find only real risks in this diff and rank by severity.
PROMPT

cat /tmp/codex-da-round1.md | codex exec --full-auto -o /tmp/codex-da-round1-result.md 2>&1
cat /tmp/codex-da-round1-result.md
```

다음 라운드 패턴:
1. 결과에서 유효 지적만 추린다.
2. 코드/문서를 수정한다.
3. 새 프롬프트 파일(`round2.md`)로 같은 명령을 반복한다.

## 2. heredoc 기반 즉시 실행

짧은 감사 요청은 heredoc으로 임시 파일을 생성해 바로 실행한다.

```bash
cat > /tmp/codex-audit.md <<'PROMPT'
다음 변경에서 운영 리스크를 3개 이내로 지적하고,
각 항목마다 재현 조건을 한 줄씩 적는다.
PROMPT

cat /tmp/codex-audit.md | codex exec --full-auto -o /tmp/codex-audit-result.md 2>&1
```

## 3. 브랜치 기준 코드 리뷰

`main` 대비 현재 브랜치 변경을 리뷰한다.

```bash
codex exec review --base main --full-auto
```

리뷰 기준을 강하게 제어하고 싶으면 stdin 지시를 추가한다.

```bash
cat > /tmp/review-policy.md <<'PROMPT'
Focus on regressions, missing tests, and deployment risks.
Ignore style-only comments.
PROMPT

cat /tmp/review-policy.md | codex exec review - --base main --full-auto
```

## 4. 워킹트리(미커밋) 리뷰

커밋 전 self-review에 사용한다.

```bash
codex exec review --uncommitted --full-auto
```

변경이 많을 때는 먼저 `git status --short`로 범위를 확인하고 실행한다.

## 5. JSONL 출력 파이프라인

자동화 파서와 연결할 때는 `--json`을 사용한다.

```bash
cat /tmp/codex-audit.md | codex exec --full-auto --json > /tmp/codex-events.jsonl
```

주의:
- `--json`은 이벤트 스트림 용도다.
- 최종 요약문을 파일로 보존하려면 `-o`를 별도로 함께 사용한다.

## 6. 경량 스모크 테스트

실행 환경 점검용 최소 예제:

```bash
cat > /tmp/codex-smoke.md <<'PROMPT'
현재 디렉토리 기준으로 다음 작업 1가지만 제안한다.
PROMPT

cat /tmp/codex-smoke.md | codex exec --full-auto -o /tmp/codex-smoke-result.md 2>&1
cat /tmp/codex-smoke-result.md
```

성공 기준:
- 명령이 비정상 종료되지 않는다.
- 결과 파일이 생성되고 비어 있지 않다.
