# codex-hooks fixtures

Codex 0.124+ stable hook 회귀 차단을 위한 deterministic fixture.
runner: `tests/test-codex-hook-fixtures.sh`.

## 디렉토리

| 경로 | 의도 | 소비처 |
|------|------|--------|
| `stdin/` | hook stdin fixture 공용 디렉터리. Codex 0.124+ payload(`record-prompt-submit.sh`/`record-last-stop.sh` 등), PostToolUse pinning-alert warn-only fixture, PreToolUse pinning-guard hard-fail fixture(`*.expected` sidecar 포함)가 함께 위치. 카테고리별 파일 표는 아래 카테고리 7/7b 절 참조. | `test_stdin_payloads_create_expected_hook_artifacts_codex_0_124`, `test_pinning_alert_behavioral`, `test_pretooluse_pinning_guard_behavioral` |
| `commit-msg/` | commit-msg-pinning.sh 입력 메시지와 stderr expected sidecar. shared pinning helper가 commit message 경로에서도 hook 경로와 같은 결과를 내는지 검증한다. | `test_commit_msg_pinning_behavioral` |
| `sync-preservation/` | `sync-codex-config.py`가 `~/.codex/config.toml`을 merge할 때 user-owned 영역을 어떻게 보존/덮어쓰는지 검증할 user 측 입력 TOML. | `test_sync_preservation_scenarios` |

(이전에는 `transcripts/` 디렉터리와 카테고리 6 stop-notification reliability/security fixture가 있었으나, native push 도입으로 stop-notification hook과 함께 제거되었다.)

### stdin/ 카테고리 7 fixture (pinning-alert behavioral, #606)

각 `pinning-*.json` 옆에 동일 basename의 `*.expected`가 있어 hook stderr 출력을
`diff -u`로 비교한다. `pinning-claude-*`은 Claude hook을, `pinning-codex-*`은 Codex hook을
호출 대상으로 삼는다 (runner가 prefix로 분기). exit code는 모두 0(warn-only contract).

| 파일 | hook | 입력 의도 | expected stderr |
|------|------|----------|-----------------|
| `pinning-claude-edit-positive-3patterns.json` | Claude Edit | 3 패턴 동시 매치 (Round/Bundle/DA keyword) on `.md` | `Edit on …` 헤더 + 3 finding 라인 |
| `pinning-claude-write-clean.json` | Claude Write | 정상 텍스트 | 빈 파일 (false positive 회피) |
| `pinning-claude-self-exclude.json` | Claude Edit | path가 `…/scripts/ai/commit-msg-pinning.sh` (self-exclude) | 빈 파일 |
| `pinning-codex-applypatch-md-positive.json` | Codex apply_patch | 단일 `.md` Update + Round | `apply_patch on …` 헤더 + Round 라인 |
| `pinning-codex-applypatch-moveto.json` | Codex apply_patch | `*** Move to:` (`.txt` → `.md`) + Round | Move 후 `.md` path로 보고 (R3 분기) |
| `pinning-codex-applypatch-multifile.json` | Codex apply_patch | `.ts` 정상 + `.md` 박제 | `.md` path만 보고 (multi-file attribution) |
| `pinning-codex-applypatch-removeonly.json` | Codex apply_patch | 박제 패턴이 `^-` 라인에만 (제거 patch) | 빈 파일 (added line만 검사) |
| `pinning-codex-bash-out-of-scope.json` | Codex Bash | `tool_name=Bash` (사전 분기 대상) | 빈 파일 |

Issue #686 path-aware PATTERN_A fixtures add PRD/plan-path coverage:

- `pinning-claude-write-{prds,plans}-pattern-a-clean.*` and `pinning-codex-applypatch-{prds,plans}-pattern-a-clean.*` prove PATTERN_A-only content is clean under `.claude/prds/` and `.claude/plans/`.
- `pinning-claude-write-prds-pattern-b-positive.*`, `pinning-claude-write-plans-pattern-c-positive.*`, `pinning-codex-applypatch-prds-pattern-b-positive.*`, and `pinning-codex-applypatch-plans-pattern-c-positive.*` prove non-A categories still warn inside PRD/plan paths.
- `pinning-codex-applypatch-{moveto,multifile,update}-prds-pattern-a-clean.*` and `pinning-codex-applypatch-mixed-prds-outside-pattern-a-positive.*` protect Codex `apply_patch` effective-path attribution for the narrow exception.
- `pinning-claude-write-prds-traversal-pattern-a-positive.*` and `pinning-codex-applypatch-prds-tab-traversal-pattern-a-positive.*` prove traversal-looking PRD paths do not receive the PATTERN_A exception.

### stdin/ 카테고리 7b fixture (PreToolUse pinning-guard hard-fail, #587)

각 `pretooluse-pinning-guard-*.json` 옆에 동일 basename의 `*.expected`가 있다.
positive fixture의 expected 파일은 stdout JSON에서 추출한 `permissionDecisionReason` 원문이고,
clean/pass fixture의 expected 파일은 빈 파일이다. hook stderr는 항상 빈 출력이어야 하며,
exit code는 deny/pass 모두 0이다. deny 여부는 stdout JSON의 `hookSpecificOutput.permissionDecision=deny`로 검증한다.
파일명 prefix는 호출 대상 runtime을 나타내므로, 공용 tool 이름이어도 Claude hook용 fixture는
`pretooluse-pinning-guard-claude-write-clean.json`처럼 `claude` prefix를 유지한다.
runner는 파일 fixture 외에도 sandbox meta case를 생성해 host `PINNING_PATTERNS_LIB` 누수 차단과
Claude/Codex missing shared-library fail-closed 분기를 검증한다.

| 파일 | hook | 입력 의도 | expected |
|------|------|----------|----------|
| `pretooluse-pinning-guard-claude-edit-positive.json` | Claude PreToolUse | Edit delta가 새 volatile metadata를 추가 | deny reason |
| `pretooluse-pinning-guard-claude-edit-existing-no-increase.json` | Claude PreToolUse | 기존 pinned text count가 증가하지 않는 Edit | 빈 파일 |
| `pretooluse-pinning-guard-claude-write-clean.json` | Claude PreToolUse | clean Write | 빈 파일 |
| `pretooluse-pinning-guard-claude-write-positive.json` | Claude PreToolUse | Write content with volatile metadata | deny reason |
| `pretooluse-pinning-guard-claude-notebook-positive.json` | Claude PreToolUse | NotebookEdit on `.ipynb` | deny reason |
| `pretooluse-pinning-guard-claude-bash-positive.json` | Claude PreToolUse | durable `gh` command with volatile metadata | deny reason |
| `pretooluse-pinning-guard-claude-bash-git-option-commit.json` | Claude PreToolUse | `git` global-option commit command | deny reason |
| `pretooluse-pinning-guard-codex-applypatch-positive.json` | Codex PreToolUse | apply_patch adds volatile metadata to `.md` | deny reason |
| `pretooluse-pinning-guard-codex-applypatch-multifile.json` | Codex PreToolUse | apply_patch multi-file attribution | deny reason for matched `.md` |
| `pretooluse-pinning-guard-codex-applypatch-multimatch.json` | Codex PreToolUse | apply_patch has multiple matched eligible files | single deny reason for first matched path |
| `pretooluse-pinning-guard-codex-applypatch-moveto.json` | Codex PreToolUse | apply_patch `*** Move to:` effective path | deny reason for moved `.md` |
| `pretooluse-pinning-guard-codex-applypatch-removeonly.json` | Codex PreToolUse | remove-only patch | 빈 파일 |
| `pretooluse-pinning-guard-codex-applypatch-clean.json` | Codex PreToolUse | clean apply_patch | 빈 파일 |
| `pretooluse-pinning-guard-codex-applypatch-relative-self-exclude.json` | Codex PreToolUse | repo-relative fixture maintenance patch | 빈 파일 |
| `pretooluse-pinning-guard-codex-edit-existing-no-increase.json` | Codex PreToolUse | alias Edit existing-count no-increase | 빈 파일 |
| `pretooluse-pinning-guard-codex-write-positive.json` | Codex PreToolUse | alias Write content with volatile metadata | deny reason |
| `pretooluse-pinning-guard-codex-bash-positive.json` | Codex PreToolUse | durable `gh` command with volatile metadata | deny reason |
| `pretooluse-pinning-guard-codex-bash-git-option-commit.json` | Codex PreToolUse | `git` global-option commit command | deny reason |
| `pretooluse-pinning-guard-codex-bash-gh-api-comment.json` | Codex PreToolUse | `gh api` issue comment body | deny reason |
| `pretooluse-pinning-guard-codex-bash-out-of-scope.json` | Codex PreToolUse | non-durable Bash command | 빈 파일 |

Issue #686 path-aware PATTERN_A guard fixtures add the explicit matrix:

| 시나리오 | fixture |
|----------|---------|
| PATTERN_A allowed in `.claude/prds/` and `.claude/plans/` | `pretooluse-pinning-guard-claude-write-{prds,plans}-pattern-a-clean.*`, `pretooluse-pinning-guard-codex-write-prds-pattern-a-clean.*`, `pretooluse-pinning-guard-codex-applypatch-{prds,plans}-pattern-a-clean.*` |
| PATTERN_B still denied + PATTERN_C **volatile** sub-pattern still denied in `.claude/prds/` and `.claude/plans/` | `pretooluse-pinning-guard-claude-write-{prds,plans}-pattern-{b,c}-deny.*` (pattern-c-deny fixtures use volatile sub-pattern tokens after #767), `pretooluse-pinning-guard-codex-applypatch-prds-pattern-b-deny.*`, `pretooluse-pinning-guard-codex-applypatch-plans-pattern-c-deny.*` |
| Equal-count non-A replacement still denied | `pretooluse-pinning-guard-claude-write-prds-pattern-b-to-c-deny.*`, `pretooluse-pinning-guard-codex-write-plans-pattern-c-to-b-deny.*`, `pretooluse-pinning-guard-claude-edit-prds-pattern-b-token-change-deny.*` |
| Equal-count replacement outside PRD/plan keeps existing count-gate behavior | `pretooluse-pinning-guard-codex-edit-outside-equal-count-clean.*` |
| Codex `apply_patch` effective path remains correct | `pretooluse-pinning-guard-codex-applypatch-{moveto,multifile,update}-prds-pattern-a-clean.*`, `pretooluse-pinning-guard-codex-applypatch-mixed-prds-outside-pattern-a-deny.*` |
| Traversal-looking PRD paths fail closed | `pretooluse-pinning-guard-claude-write-prds-traversal-pattern-a-deny.*`, `pretooluse-pinning-guard-codex-applypatch-prds-tab-traversal-pattern-a-deny.*` |
| Edit/Notebook future-compatible PATTERN_A clean paths | `pretooluse-pinning-guard-claude-edit-prds-pattern-a-clean.*`, `pretooluse-pinning-guard-claude-notebook-plans-pattern-a-clean.*`, `pretooluse-pinning-guard-codex-edit-plans-pattern-a-clean.*`, `pretooluse-pinning-guard-codex-notebook-prds-pattern-a-clean.*` |

Issue #767 PATTERN_C workflow/volatile split fixtures (workflow sub-pattern allowed in policy categories + alias, volatile sub-pattern still denied):

| 시나리오 | fixture |
|----------|---------|
| PATTERN_C **workflow** sub-pattern allowed in `.claude/prds/` and `.claude/plans/` | `pretooluse-pinning-guard-claude-write-{prds,plans}-pattern-c-workflow-clean.*`, `pretooluse-pinning-guard-codex-applypatch-{prds,plans}-pattern-c-workflow-clean.*` |
| PATTERN_C **workflow** sub-pattern allowed in `/tmp/issue-draft/` (issue/PR body draft staging) | `pretooluse-pinning-guard-claude-write-issue-draft-pattern-c-workflow-clean.*` |
| PATTERN_C **workflow** sub-pattern allowed in body temp draft path (`/tmp/*-body*`) | `pretooluse-pinning-guard-claude-write-body-temp-pattern-c-workflow-clean.*` |
| Traversal raw path stays denied even with workflow tokens (workflow allow predicate fail-closes on traversal segment) | `pretooluse-pinning-guard-claude-write-body-temp-traversal-pattern-c-deny.*` |
| Traversal raw path under body-temp shape denies equal-count `category B → category C workflow` token replacement (D-1 token-delta) | `pretooluse-pinning-guard-claude-edit-body-temp-traversal-pattern-b-to-c-workflow-equal-count-deny.*` |

PostToolUse `pinning-alert.sh` and commit-msg-pinning.sh keep emitting both sub-patterns under category code "C" (warn-only diagnostic preserved). The PreToolUse hard-fail records API (`pinning_guard_findings_records_for_path`, `pinning_guard_findings_records_for_scan_path`) suppresses only the workflow sub-pattern on the allowed paths above.

### commit-msg/ 카테고리 7c fixture (commit-msg-pinning behavioral)

각 `*.msg` 옆에 동일 basename의 `*.expected`가 있다. 빈 expected는 clean pass.

| 파일 | 시나리오 | 기대 |
|------|----------|------|
| `clean.msg` | 박제 패턴 없는 정상 commit msg | 빈 파일 (warn 없음) |
| `line-token-a-positive.msg` | PATTERN_A (Round counter) | A 라벨 + line:token warn |
| `line-token-b-positive.msg` | PATTERN_B (Bundle finding ID) | B 라벨 + line:token warn |
| `line-token-c-positive.msg` | PATTERN_C (DA 실행 키워드) | C 라벨 + line:token warn |

## 외부 contract만 디렉토리로 노출

dispatcher ordering / noise-guard / programmatic env inheritance 시나리오는 runner 내부 helper가
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
| `scenario-F-pretooluse-template-owned.toml` | template이 선언한 PreToolUse 이벤트(issue #587)에 사용자가 entry 추가 시 sync가 template 값으로 덮어씀 | 사용자 PreToolUse marker가 사라지고 managed pinning-guard command만 남음 |

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
| `isolated_codex_home_overrideless_retired_self_injection` | 없음 (ephemeral config.toml로 hook 등록) | read-only | inherited | HANG/marker unset in retired PR #595 self-injection assertion | Retired historical context: #634 replaces this with `programmatic_env_inheritance_live` using caller-supplied `CODEX_PROGRAMMATIC=1`, supervised wrapper, and stdin pipe EOF |

**Retired historical context (#634)**: PR #595의 기존 self-injection assertion은 mac 0.128에서 marker unset fail을 보였지만, repo의 지원 계약은 Codex CLI self-injection이 아니라 caller-supplied `CODEX_PROGRAMMATIC=1`이다. 현재 live fixture는 sandbox `CODEX_HOME` hook config + `codex-exec-supervised` + stdin pipe EOF로 해당 marker가 hook subprocess까지 상속되는지만 검증한다. managed hook early-exit 동작은 deterministic noise-guard fixture가 검증한다.
