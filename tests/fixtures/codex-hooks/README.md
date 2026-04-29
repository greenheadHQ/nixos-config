# codex-hooks fixtures

Codex 0.124+ stable hook 회귀 차단을 위한 deterministic fixture.
runner: `tests/test-codex-hook-fixtures.sh`.

## 디렉토리

| 경로 | 의도 | 소비처 |
|------|------|--------|
| `stdin/` | Codex 0.124+ stdin payload (실측 schema). `record-prompt-submit.sh`, `record-last-stop.sh`, `stop-notification.sh` 등 hook이 stdin으로 받는 JSON. | `test_stdin_payloads_create_expected_hook_artifacts_codex_0_124`, `test_stop_notification_codex_transcript_fallback`, `test_stop_notification_secret_redaction` |
| `sync-preservation/` | `sync-codex-config.py`가 `~/.codex/config.toml`을 merge할 때 user-owned 영역을 어떻게 보존/덮어쓰는지 검증할 user 측 입력 TOML. | `test_sync_preservation_scenarios` |
| `transcripts/` | Codex 0.124+ session JSONL transcript 샘플. stop-notification.sh의 `extract_last_assistant_text` fallback 경로 검증용. | `test_stop_notification_codex_transcript_fallback` (6.1) |

### stdin/ 카테고리 6 fixture

| 파일 | 카테고리 | placeholder 규약 |
|------|----------|------------------|
| `stop-no-last-message-codex-transcript.json` | 6.1 | `transcript_path` 값의 `__SANDBOX_TRANSCRIPT_PATH__`를 runner가 sandbox 내부 transcript 경로로 sed 치환 |
| `stop-with-secret-reply.json` | 6.2 | `last_assistant_message`에 7 token family 패턴(`sk-ant`/`sk-openai`/`gh-classic`/`github-pat`/`jwt`/`aws-akia`/`aws-asia`)이 함께 포함된 통합 fixture |

## 외부 contract만 디렉토리로 노출

dispatcher ordering / noise-guard / env-propagation 시나리오는 runner 내부 helper가
sandbox 안에서 동적으로 mock script를 작성한다. 디렉토리에 빈 placeholder를 두지 않는다.

## 실행

```bash
# deterministic 모드 (기본)
tests/test-codex-hook-fixtures.sh

# verify-ai-compat가 호출하는 형태와 동일
tests/test-codex-hook-fixtures.sh --no-live

# live opt-in (codex exec 호출 — 환경 결함 시 WARN skip)
tests/test-codex-hook-fixtures.sh --live
# 또는
CODEX_HOOK_LIVE=1 tests/test-codex-hook-fixtures.sh
```

## stdin schema 기준

`CODEX_HOOK_SCHEMA_BASELINE="0.124"` ([`tests/lib/codex-hook-expectations.sh`](../../lib/codex-hook-expectations.sh) oracle 상수).
agent_id 키는 0.124 schema에 없으며 hook은 graceful fallback에 의존한다.

## sync-preservation 시나리오 표

| 파일 | 의도 | 검증 내용 |
|------|------|-----------|
| `scenario-A-template-event.toml` | template이 선언한 이벤트는 template 값이 유지 | hooks.UserPromptSubmit이 template과 일치 |
| `scenario-B-user-added-same-event.toml` | template이 선언한 이벤트에 사용자가 entry 추가 시 sync-codex-config.py가 template 값으로 덮어씀 | 사용자 추가 marker가 사라짐 |
| `scenario-C-user-different-event.toml` | template 미선언 이벤트는 user-owned로 보존 | hooks.SessionStart 등이 그대로 유지 |
| `scenario-D-mcp-servers-coexist.toml` | mcp_servers와 hooks 인접 ownership view | 사용자 mcp_servers entry 보존 + hooks template 적용 |
