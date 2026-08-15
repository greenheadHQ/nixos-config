# Data Sources

## 세션 로그 위치

| 호스트 | Claude Code | Codex |
|--------|-------------|-------|
| Mac (`/Users/greenhead`) | `~/.claude/projects/**/*.jsonl` | `~/.codex/sessions/**/rollout-*.jsonl` |
| MiniPC (`/home/greenhead`) | `~/.claude/projects/**/*.jsonl` | `~/.codex/sessions/**/rollout-*.jsonl` |

원격 호스트는 `subprocess.run(["ssh", alias, "find", "~/.claude/projects", "-name", "'*.jsonl'", "-size", "-50M", ...])` 고정 argv로 path 목록만 수집한 뒤 (`-size` cap의 계약과 제외 건수 기록은 [host-handling.md](host-handling.md)의 "corpus size cap" 참조), 검증된 목록을 우선 단일 tar batch stream으로 가져온다. tar command는 `ssh <alias> tar -C / -cf - -T -`이고 file list는 stdin으로만 전달한다. tar batch가 timeout/nonzero/empty stream/tar 해석 실패 등으로 실패하면 검증을 통과한 path에 한해 기존 per-file `ssh <alias> cat <path>` worker pool로 fallback한다. 세부 실패 조건과 budget 처리는 [host-handling.md](host-handling.md)의 "fetch 전략: tar batch 우선 + per-file cat fallback"을 따른다.

호스트당 fallback SSH cat 호출은 ControlMaster 다중화 + `concurrent.futures.ThreadPoolExecutor(max_workers=SSH_FETCH_WORKERS)`로 병렬 처리한다 (host 순차 진행, host당 K=8 fetch 병렬). ControlMaster가 비활성인 호스트는 K=1 직렬 fallback이 host budget(`SSH_HOST_FETCH_BUDGET_SECONDS`) 안에 끝나지 않으므로 fetch 자체를 skip하고 명시적 warning을 누적한다 (사용자가 ControlMaster 활성화 누락을 즉시 인지).

`/subagents/` 하위 jsonl은 분석에서 제외한다 (parent session에서 spawn된 보조 에이전트의 자체 산출물이 아닌 wrapper output이라 verdict 중복 카운트 위험).

## jsonl 스키마 (요약)

### Claude Code (`~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`)

각 line은 `{ "type": "user" | "assistant" | "tool_use_result" | ..., "uuid": "...", "timestamp": "...", "message": { ... } }` 형태의 단일 JSON object. 측정 알고리즘은 JSON parse → string payload 추출 → regex 적용 순서로 동작한다 (raw blob regex 금지). `payload_traversal_path`는 보통 `$.message.content[...]` 또는 `$.message.content` 형태다.

세션 소스 추적성은 top-level `cwd`, `gitBranch`, `sessionId`를 primary source로 사용한다.
세 필드 중 하나라도 부재하면 해당 필드만 `missing_fields`에 남기고 세션 분석은 계속한다.

### Codex (`~/.codex/sessions/<YYYY>/<MM>/<DD>/rollout-<ISO>-<id>.jsonl`)

Codex CLI rollout 형식. 각 line은 별도 JSON object이며, `payload` 필드 또는 `content` 배열 안에 모델 출력 텍스트가 포함된다. `payload_traversal_path`는 Codex wrapper 경계를 보존하기 위해 `$.payload.*` 형태를 그대로 기록한다.

세션 소스 추적성은 `payload.cwd`, `payload.git.branch`, `payload.id`를 primary source로
사용한다. `payload.id`가 부재하면 rollout 파일명(`rollout-<ISO>-<id>.jsonl`)에서
`session_id`를 best-effort로 보강하고, 디렉터리 `/<YYYY>/<MM>/<DD>/`에서 `rollout_date`를
보강한다. primary `payload.id`가 뒤늦게 발견되면 파일명 fallback보다 우선한다.

### unknown / partial format

Claude top-level 필드도 Codex payload 필드도 없고 rollout 파일명도 아닌 세션은
`format: "unknown"`으로 남긴다. 이는 오류가 아니며 `traceability.coverage`의
`unknown_format_sessions`와 `missing_fields` 카운트로만 표시한다. PR/issue 번호 grep은
본문 string payload에서 best-effort로 수행하며, 실패 시 빈 배열이다.

## 소스 추적성 필드 계약

`analyze.py`는 세션별 `session_meta`를 `traceability.sessions[]`에 그대로 보존하고,
aggregate coverage를 `traceability.coverage`에 둔다.

| 필드 | 계약 |
|------|------|
| `path` | 분석한 logical session path. 원격 파일은 원격 absolute path를 유지한다. |
| `host` | `HOST_PATH_MAP` base prefix로 추론한 host. 미분류는 `null`/`unknown` coverage로 남긴다. |
| `format` | `claude`, `codex`, `unknown` 중 하나. rollout filename fallback이 매치되면 `codex`. |
| `cwd` | Claude top-level `cwd` 또는 Codex `payload.cwd`. |
| `git_branch` | Claude `gitBranch` 또는 Codex `payload.git.branch`. |
| `session_id` | Claude `sessionId`, Codex `payload.id`, fallback `rollout-<ISO>-<id>.jsonl`의 `<id>`. |
| `rollout_date` | Codex rollout directory `/<YYYY>/<MM>/<DD>/` fallback. |
| `source_fields` | primary extraction에 성공한 원천 필드 목록. |
| `fallback_fields` | filename/date fallback으로 보강한 필드 목록. |
| `missing_fields` | `cwd`, `git_branch`, `session_id` 중 최종 부재 필드. |
| `complete` | 필수 3필드가 있고 format이 `unknown`이 아니면 true. |
| `references` | PR/issue/bare number best-effort grep 결과. |

`traceability.coverage`는 `sessions_total`, `complete_sessions`,
`unknown_format_sessions`, `format_distribution`, `host_distribution`,
`field_presence`, `missing_fields`, `fallback_fields`를 포함한다.

## payload traversal path

`analyze.py`는 path-aware walker만 string payload 추출 경계의 SoT로 사용한다. legacy string-only helper는 제거됐으며 새 추출 경로는 traversal path를 항상 보존한다.

| JSON node | path 표기 |
|-----------|-----------|
| root | `$` |
| dict key | `.key` |
| list item | `[index]` |

예:

| 세션 형식 | payload path 예 |
|-----------|-----------------|
| Claude Code | `$.message.content[0].text` |
| Codex rollout | `$.payload.content[0].text` |

이 path는 pre-parse skip key와 `VerdictRecord` dedupe key의 일부다. 같은 payload hash라도 서로 다른 traversal path에서 나온 record는 별도 provenance로 남긴다.

## arbiter marker

verdict 분포의 분모는 Arbiter dir marker 출현 세션이다:

```python
ARBITER_DIR_MARKER = re.compile(
    r'/tmp/da-[a-fA-F0-9]+-arbiter-(?!XXXXXX\b)[A-Za-z0-9]+'
)
```

- `XXXXXX` 템플릿 placeholder는 부정 lookahead로 제외 (코드 예시 false positive 차단).
- keyword `arbiter` 단독 출현은 분모로 사용하지 않는다 (skill 문서 LLM context 로드 시 false positive 다수).

## intensity marker

검토 강도 verdict 분포(M-1)의 분모는 Intensity dir marker 출현 세션이다 (Review Intensity 인라인 체크리스트 도입 이후로는 marker가 없을 수 있어, 인라인 체크리스트 출력 grep도 보조 source로 사용):

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
    "/Users/greenhead/.claude/projects/.../<sessionId>.jsonl",
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

- `files`는 절대 경로 list. 호출 시 host 매핑은 path prefix로 자동 분류. v1 `analyze.py --corpus`는 `files` + `snapshot_id`만 소비한다.
- `captured_metric_summary`는 baseline 값 — 향후 ±5% 비교 도구가 `--corpus` 결과와 함께 비교할 때 사용. v1 `analyze.py`는 이 필드를 직접 비교하지 않으므로 manifest 안에 보존만 된다.
- manifest.json 생성 (capture)은 v1 `analyze.py`의 책임 범위가 아니다 — 별도 capture step (외부 스크립트 또는 follow-up 모드)에서 생성한 후 본 Skill 호출 시 `--corpus`로 입력한다.
- host별 home prefix가 기본값과 다른 corpus는 `--host-home host=/abs/home`으로 `HOST_PATH_MAP` base를 override할 수 있다. 이 override는 validation/corpus prefix 계산에만 쓰이며 SSH command path는 계속 `~/.claude/projects`, `~/.codex/sessions`를 사용한다.
- 주간 리포트 cron/systemd 호출부는 username에서 `mac=/Users/<username>,minipc=/home/<username>`을 유도해 `--host-home`을 명시 전달한다. 기본값은 현재 배포값(`greenhead`)과의 하위호환용이다.

## `HOST_PATH_MAP` override 계약

`--host-home host=/abs/home[,host=/abs/home]`은 `HOST_PATH_MAP`의 absolute home prefix만
재계산한다:

```text
HOST_PATH_MAP[host]["claude"] = /abs/home/.claude/projects
HOST_PATH_MAP[host]["codex"] = /abs/home/.codex/sessions
```

적용 범위는 validation/corpus host inference/traceability host inference다. 원격 SSH command
path는 계속 `~/.claude/projects`, `~/.codex/sessions`를 사용한다. 따라서 username migration
환경에서도 command construction은 host-neutral이고, 보안 boundary만 배포 사용자 홈으로
파라미터화된다.

## subagent 폴더 제외 사유

`~/.claude/projects/<sessionId>/subagents/agent-<id>.jsonl` 파일은 parent session에서 spawn된 보조 에이전트의 wrapper output이다. 이 wrapper output에는 parent의 finding이 다시 인용되어 중복 카운트가 발생한다. 따라서 분석 시 `/subagents/` 경로 segment를 포함하는 파일은 제외한다.
