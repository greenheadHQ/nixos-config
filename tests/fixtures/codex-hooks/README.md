# codex-hooks fixtures

Codex 0.124+ stable hook 회귀 차단을 위한 deterministic fixture.
runner: `tests/test-codex-hook-fixtures.sh`.

## 디렉토리

| 경로 | 의도 | 소비처 |
|------|------|--------|
| `stdin/` | hook stdin fixture 공용 디렉터리. Codex 0.124+ payload(`record-prompt-submit.sh`/`record-last-stop.sh`/`stop-notification.sh` 등)와 pinning-alert behavioral fixture(Claude+Codex hook 입력/출력 박제, `*.expected` sidecar 포함)가 함께 위치. 카테고리별 파일 표는 아래 카테고리 6/7 절 참조. | `test_stdin_payloads_create_expected_hook_artifacts_codex_0_124`, `test_stop_notification_codex_transcript_fallback`, `test_stop_notification_secret_redaction`, `test_pinning_alert_behavioral` |
| `sync-preservation/` | `sync-codex-config.py`가 `~/.codex/config.toml`을 merge할 때 user-owned 영역을 어떻게 보존/덮어쓰는지 검증할 user 측 입력 TOML. | `test_sync_preservation_scenarios` |
| `transcripts/` | Codex 0.124+ session JSONL transcript 샘플. stop-notification.sh의 `extract_last_assistant_text` fallback 경로 검증용. | `test_stop_notification_codex_transcript_fallback` (6.1) |

### stdin/ 카테고리 6 fixture

| 파일 | 카테고리 | placeholder 규약 |
|------|----------|------------------|
| `stop-no-last-message-codex-transcript.json` | 6.1 | `transcript_path` 값의 `__SANDBOX_TRANSCRIPT_PATH__`를 runner가 sandbox 내부 transcript 경로로 sed 치환 |
| `stop-with-secret-reply.json` | 6.2 | `last_assistant_message`에 7 token family 패턴(`sk-ant`/`sk-openai`/`gh-classic`/`github-pat`/`jwt`/`aws-akia`/`aws-asia`)이 함께 포함된 통합 fixture |

### stdin/ 카테고리 7 fixture (pinning-alert behavioral, #606)

각 `pinning-*.json` 옆에 동일 basename의 `*.expected`가 있어 hook stderr 출력을
`diff -u`로 비교한다. `pinning-claude-*`은 Claude hook을, `pinning-codex-*`은 Codex hook을
호출 대상으로 삼는다 (runner가 prefix로 분기). exit code는 모두 0(warn-only contract).

| 파일 | hook | 입력 의도 | expected stderr |
|------|------|----------|-----------------|
| `pinning-claude-edit-positive-4patterns.json` | Claude Edit | 4 패턴 동시 매치 (Round/Bundle/DA keyword/partial hash) on `.md` | `Edit on …` 헤더 + 4 finding 라인 |
| `pinning-claude-write-clean.json` | Claude Write | 정상 텍스트 | 빈 파일 (false positive 회피) |
| `pinning-claude-self-exclude.json` | Claude Edit | path가 `…/scripts/ai/commit-msg-pinning.sh` (self-exclude) | 빈 파일 |
| `pinning-codex-applypatch-md-positive.json` | Codex apply_patch | 단일 `.md` Update + Round | `apply_patch on …` 헤더 + Round 라인 |
| `pinning-codex-applypatch-moveto.json` | Codex apply_patch | `*** Move to:` (`.txt` → `.md`) + Round + hash | Move 후 `.md` path로 보고 (R3 분기) |
| `pinning-codex-applypatch-multifile.json` | Codex apply_patch | `.ts` 정상 + `.md` 박제 | `.md` path만 보고 (multi-file attribution) |
| `pinning-codex-applypatch-removeonly.json` | Codex apply_patch | 박제 패턴이 `^-` 라인에만 (제거 patch) | 빈 파일 (added line만 검사) |
| `pinning-codex-applypatch-backtick-short.json` | Codex apply_patch | `` `abcde` `` 5자 backtick (`HASH_MIN=7` 미만) | 빈 파일 (false positive 회피) |
| `pinning-codex-bash-out-of-scope.json` | Codex Bash | `tool_name=Bash` (사전 분기 대상) | 빈 파일 |

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
| `scenario-E-posttooluse-template-owned.toml` | template이 선언한 PostToolUse 이벤트(issue #603)에 사용자가 entry 추가 시 sync가 template 값으로 덮어씀 | 사용자 PostToolUse marker가 사라지고 managed pinning-alert command만 남음 |

## codex exec invocation matrix 시나리오 (live opt-in, issue #593)

`test_codex_exec_invocation_live_matrix` 카테고리는 fix 적용 후 PASS가 기대되는 시나리오만 검증한다 (must-pass-only). PR #595 fixture pattern hang은 본 matrix 제외 — known caveat: [`using-codex-exec/references/known-issues.md`](../../../modules/shared/programs/claude/files/skills/using-codex-exec/references/known-issues.md) §15 + 별도 follow-up.

| 케이스 이름 | 패턴 | 기대 동작 | 검증 의의 |
|-------------|------|----------|----------|
| `host_home_no_override_stdin_pipe_supervised_pass` | host HOME + no `-c hooks` override + stdin pipe + read-only + `codex-exec-supervised` | 정상 종료 (rc=0) + result 파일 생성 | host HOME + supervisor 정상 동작 회귀 차단 |
| `raw_override_inline_toml_hang_with_supervisor_pass` | host HOME + `-c hooks.<event>` override + stdin pipe + read-only + `codex-exec-supervised` | rc=0/124/137 모두 PASS (supervisor가 timeout 안에 정리) | issue #593 raw PoC 패턴 + supervisor 적용 시 native 잔존 차단 회귀 차단 |

환경 결함(timeout/codex/codex-exec-supervised 부재) 시 WARN skip — capability-probe 정책 ([`run-da/SKILL.md`](../../../modules/shared/programs/claude/files/skills/run-da/SKILL.md) "stdin pipe + supervised wrapper").

## issue #593 PoC variant legend

총 8 PoC variant 진단 (Mac codex 0.128, supervised wrapper 미적용 상태에서의 raw 동작):

| 시나리오 | hooks override | sandbox | stdin | wrapper 미적용 결과 | wrapper 적용 후 |
|----------|----------------|---------|-------|---------------------|-----------------|
| `raw_full_auto_override_inherited_stdin_hang*` (skip-git 유무·cwd 변형) | `-c hooks.<event>` | full-auto | inherited (TTY/pipe) | HANG (timeout 못 죽임) | known-issues.md §15 (override 그룹) |
| `standard_skip_git_ignore_user_config_override_inherited_stdin_hang` | `-c hooks.<event>` | read-only | inherited | HANG (`Reading additional input from stdin...`) | known-issues.md §15 |
| `standard_override_devnull_stdin_hang` | `-c hooks.<event>` | read-only | `</dev/null` | HANG (timeout 못 죽임) | known-issues.md §15 |
| `standard_override_stdin_pipe_hang` | `-c hooks.<event>` | read-only | pipe + `-` | HANG (timeout 못 죽임) | known-issues.md §15 |
| `host_home_no_override_stdin_pipe_pass` | 없음 | read-only | pipe + `-` 또는 `</dev/null` | OK 12s, hook fired, "PONG" | invocation matrix scenario-1 (wrapper 적용 시 `_supervised_pass`) |
| `isolated_codex_home_overrideless_known_hang` | 없음 (ephemeral config.toml로 hook 등록) | read-only | inherited | HANG (PR #595 fixture pattern) | known-issues.md §15 caveat + **follow-up: [#634](https://github.com/greenheadHQ/nixos-config/issues/634)** |

**`isolated_codex_home_overrideless_known_hang` caveat**: PR #595 fixture `test_env_propagation_live`가 mac 0.128에서 hang/CLAUDECODE 미도달 fail. 본 PR scope 외 — follow-up [#634](https://github.com/greenheadHQ/nixos-config/issues/634)에서 추적.
