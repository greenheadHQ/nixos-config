# Data Sources

## 세션 로그 위치

| 호스트 | Claude Code | Codex |
|--------|-------------|-------|
| Mac (`/Users/green`) | `~/.claude/projects/**/*.jsonl` | `~/.codex/sessions/**/rollout-*.jsonl` |
| MiniPC (`/home/greenhead`) | `~/.claude/projects/**/*.jsonl` | `~/.codex/sessions/**/rollout-*.jsonl` |

원격 호스트는 `subprocess.run(["ssh", alias, "find", "...", "-name", "*.jsonl", ...])` 고정 argv로 path 목록만 수집한 뒤, 실제 파일 내용은 `subprocess.run(["ssh", alias, "cat", path])`로 한 번에 가져온다 (large repo는 batch).

`/subagents/` 하위 jsonl은 분석에서 제외한다 (parent session에서 spawn된 보조 에이전트의 자체 산출물이 아닌 wrapper output이라 verdict 중복 카운트 위험).

## jsonl 스키마 (요약)

### Claude Code (`~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`)

각 line은 `{ "type": "user" | "assistant" | "tool_use_result" | ..., "uuid": "...", "timestamp": "...", "message": { ... } }` 형태의 단일 JSON object. 측정 알고리즘은 **JSON parse → string payload 추출 → regex 적용** 순서로 동작한다 (raw blob regex 금지).

### Codex (`~/.codex/sessions/<YYYY>/<MM>/<DD>/rollout-<ISO>-<id>.jsonl`)

Codex CLI rollout 형식. 각 line은 별도 JSON object이며, `payload` 필드 또는 `content` 배열 안에 모델 출력 텍스트가 포함된다.

## arbiter marker

verdict 분포의 분모는 **Arbiter dir marker** 출현 세션이다:

```python
ARBITER_DIR_MARKER = re.compile(
    r'/tmp/da-[a-fA-F0-9]+-arbiter-(?!XXXXXX\b)[A-Za-z0-9]+'
)
```

- `XXXXXX` 템플릿 placeholder는 부정 lookahead로 제외 (코드 예시 false positive 차단).
- keyword `arbiter` 단독 출현은 분모로 사용하지 않는다 (skill 문서 LLM context 로드 시 false positive 다수).

## intensity marker

검토 강도 verdict 분포(M-1)의 분모는 **Intensity dir marker** 출현 세션이다 (Review Intensity 인라인 체크리스트 도입 이후로는 marker가 없을 수 있어, 인라인 체크리스트 출력 grep도 보조 source로 사용):

```python
INTENSITY_DIR_MARKER = re.compile(
    r'/tmp/da-[a-fA-F0-9]+-intensity-(?!XXXXXX\b)[A-Za-z0-9]+'
)
```

## manifest.json 스키마 (PR #670 baseline 등 pinned corpus)

`--corpus <path>` 인자로 측정 대상을 pinned 파일 목록으로 한정할 때 사용한다.

```json
{
  "snapshot_id": "pr-670-baseline",
  "captured_at": "2026-05-04T15:00:00Z",
  "files": [
    "/Users/green/.claude/projects/.../<sessionId>.jsonl",
    "/home/greenhead/.codex/sessions/.../rollout-<id>.jsonl",
    "..."
  ],
  "host_count": { "mac": 487, "minipc": 312 },
  "captured_metric_summary": {
    "intensity_full_pct": 80.3,
    "arbiter_confirmed_pct": 84.6
  }
}
```

- `files`는 절대 경로 list. 호출 시 host 매핑은 path prefix로 자동 분류. **v1 `analyze.py --corpus`는 `files` + `snapshot_id`만 소비한다.**
- `captured_metric_summary`는 baseline 값 — 향후 ±5% 비교 도구가 `--corpus` 결과와 함께 비교할 때 사용. v1 `analyze.py`는 이 필드를 직접 비교하지 않으므로 manifest 안에 보존만 된다.
- manifest.json 생성 (capture)은 v1 `analyze.py`의 책임 범위가 아니다 — 별도 capture step (외부 스크립트 또는 follow-up 모드)에서 생성한 후 본 Skill 호출 시 `--corpus`로 입력한다.

## subagent 폴더 제외 사유

`~/.claude/projects/<sessionId>/subagents/agent-<id>.jsonl` 파일은 parent session에서 spawn된 보조 에이전트의 wrapper output이다. 이 wrapper output에는 parent의 finding이 다시 인용되어 중복 카운트가 발생한다. 따라서 분석 시 `/subagents/` 경로 segment를 포함하는 파일은 제외한다.
