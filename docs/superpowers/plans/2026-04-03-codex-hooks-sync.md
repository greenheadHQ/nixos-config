# Codex Hooks Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add safe, declarative Codex hooks sync for this repository by enabling the Codex hooks feature globally, compiling the Claude hook declarations into `<repo>/.codex/hooks.json`, and generating a machine-readable compatibility report for unsupported or lossy hooks.

**Architecture:** Keep responsibility boundaries strict. Nix-managed Codex `config.toml` templates only enable the experimental hooks engine, while `sync.sh` compiles repository-declared Claude hooks into project-local Codex artifacts. A dedicated Python helper owns classification, rendering, and drift detection so that `sync.sh` remains an orchestrator instead of becoming a second JSON compiler.

**Tech Stack:** Bash, Python 3, jq, JSON, TOML, Home Manager symlinked config files

---

## File Structure

### Modify

- `modules/shared/programs/codex/files/config.toml`
  - Linux/global Codex template. Add `[features] codex_hooks = true`.
- `modules/shared/programs/codex/files/config.darwin.toml`
  - Darwin/global Codex template. Add `[features] codex_hooks = true`.
- `scripts/ai/verify-ai-compat.sh`
  - Add checks for `codex_hooks = true` and optional validation of generated `.codex/hooks.json` and `.codex/hooks.compatibility.json`.
- `modules/shared/programs/claude/files/skills/syncing-codex-harness/references/sync.sh`
  - Add `hooks-config` subcommand, invoke the new compiler helper, and include hooks generation in `all`.
- `modules/shared/programs/claude/files/skills/syncing-codex-harness/SKILL.md`
  - Document hooks projection and the new `hooks-config` command.
- `modules/shared/programs/claude/files/skills/syncing-codex-harness/references/codex-structure.md`
  - Update Codex structure reference from “hooks unsupported” to “experimental partial compatibility”.
- `modules/shared/programs/claude/files/skills/syncing-codex-harness/references/agents-override-template.md`
  - Replace the stale “hooks/plugins not supported” note with the new compatibility note.
- `AGENTS.override.md`
  - Update the repo’s actual Codex supplement text to match the new reality.

### Create

- `modules/shared/programs/claude/files/skills/syncing-codex-harness/references/compile-hooks.py`
  - Single-purpose compiler for Claude `settings.json` hook declarations.
- `modules/shared/programs/claude/files/skills/syncing-codex-harness/references/test-hooks-sync.sh`
  - Deterministic regression test for compiler output and `sync.sh hooks-config`.
- `modules/shared/programs/claude/files/skills/syncing-codex-harness/references/testdata/hooks/project-settings.json`
  - Fixture covering supported, lossy, and unsupported hook groups.
- `modules/shared/programs/claude/files/skills/syncing-codex-harness/references/testdata/hooks/effective-settings-same.json`
  - Fixture for no-drift case.
- `modules/shared/programs/claude/files/skills/syncing-codex-harness/references/testdata/hooks/effective-settings-drift.json`
  - Fixture for drift-detected case.

### Generated At Runtime

- `.codex/hooks.json`
  - Project-local Codex hook output.
- `.codex/hooks.compatibility.json`
  - Project-local compatibility report with classification details.

## Task 1: Enable Global Codex Hooks Feature And Fail Fast In Verification

**Files:**
- Modify: `scripts/ai/verify-ai-compat.sh`
- Modify: `modules/shared/programs/codex/files/config.toml`
- Modify: `modules/shared/programs/codex/files/config.darwin.toml`

- [ ] **Step 1: Add a failing verification check for `codex_hooks = true`**

Insert this block into `scripts/ai/verify-ai-compat.sh` right after the existing `sandbox_mode` check:

```bash
  if grep -Eq '^[[:space:]]*codex_hooks[[:space:]]*=[[:space:]]*true' "$CODEX_CONFIG"; then
    pass "codex_hooks = true"
  else
    fail "codex_hooks = true 미설정"
  fi
```

Add optional JSON validation near the “글로벌 설정 확인” section:

```bash
echo ""
echo "=== Hooks 산출물 확인 ==="

if [ -f "$REPO_ROOT/.codex/hooks.json" ]; then
  if python3 - "$REPO_ROOT/.codex/hooks.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
assert isinstance(data, dict)
PY
  then
    pass ".codex/hooks.json JSON 파싱 성공"
  else
    fail ".codex/hooks.json JSON 파싱 실패"
  fi
else
  warn ".codex/hooks.json 없음 (hooks sync 미실행)"
fi

if [ -f "$REPO_ROOT/.codex/hooks.compatibility.json" ]; then
  if python3 - "$REPO_ROOT/.codex/hooks.compatibility.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
assert "summary" in data
assert "items" in data
PY
  then
    pass ".codex/hooks.compatibility.json 구조 확인"
  else
    fail ".codex/hooks.compatibility.json 구조 확인 실패"
  fi
else
  warn ".codex/hooks.compatibility.json 없음 (hooks sync 미실행)"
fi
```

- [ ] **Step 2: Run verification and confirm it fails before the config change**

Run:

```bash
./scripts/ai/verify-ai-compat.sh
```

Expected:

```text
[FAIL] codex_hooks = true 미설정
검증 실패: ... 오류 ...
```

- [ ] **Step 3: Add the feature flag to both Codex config templates**

Update `modules/shared/programs/codex/files/config.toml`:

```toml
[features]
multi_agent = true
apps = true
prevent_idle_sleep = true
codex_hooks = true
```

Update `modules/shared/programs/codex/files/config.darwin.toml`:

```toml
[features]
multi_agent = true
apps = true
prevent_idle_sleep = true
voice_transcription = true
codex_hooks = true
```

- [ ] **Step 4: Re-run verification and confirm the feature check passes**

Run:

```bash
./scripts/ai/verify-ai-compat.sh
```

Expected:

```text
[OK] codex_hooks = true
```

Warnings about missing `.codex/hooks.json` and `.codex/hooks.compatibility.json` are acceptable at this stage.

- [ ] **Step 5: Commit**

```bash
git add scripts/ai/verify-ai-compat.sh \
  modules/shared/programs/codex/files/config.toml \
  modules/shared/programs/codex/files/config.darwin.toml
git commit -m "feat(codex): enable hooks feature flag"
```

## Task 2: Build The Hook Compiler With Fixture-Based Regression Tests

**Files:**
- Create: `modules/shared/programs/claude/files/skills/syncing-codex-harness/references/testdata/hooks/project-settings.json`
- Create: `modules/shared/programs/claude/files/skills/syncing-codex-harness/references/testdata/hooks/effective-settings-same.json`
- Create: `modules/shared/programs/claude/files/skills/syncing-codex-harness/references/testdata/hooks/effective-settings-drift.json`
- Create: `modules/shared/programs/claude/files/skills/syncing-codex-harness/references/test-hooks-sync.sh`
- Create: `modules/shared/programs/claude/files/skills/syncing-codex-harness/references/compile-hooks.py`

- [ ] **Step 1: Create deterministic fixtures and a failing regression test**

Create `project-settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/session-init-icons.sh" }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/detect-pain-point.sh" }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/stop-notification.sh" }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/worktree-path-guard.sh" }
        ]
      }
    ],
    "SessionEnd": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/nrs-session-cleanup.sh" }
        ]
      }
    ]
  }
}
```

Create `effective-settings-same.json` by copying the project fixture exactly:

```bash
cp modules/shared/programs/claude/files/skills/syncing-codex-harness/references/testdata/hooks/project-settings.json \
  modules/shared/programs/claude/files/skills/syncing-codex-harness/references/testdata/hooks/effective-settings-same.json
```

Create `effective-settings-drift.json` with one extra supported hook group so that drift detection flips to `true`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/session-init-icons.sh" }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/detect-pain-point.sh" }
        ]
      },
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/detect-pain-point-extra.sh" }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/stop-notification.sh" }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/worktree-path-guard.sh" }
        ]
      }
    ],
    "SessionEnd": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/nrs-session-cleanup.sh" }
        ]
      }
    ]
  }
}
```

Create `test-hooks-sync.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTDATA_DIR="$SCRIPT_DIR/testdata/hooks"
COMPILER="$SCRIPT_DIR/compile-hooks.py"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_SETTINGS="$TESTDATA_DIR/project-settings.json"
EFFECTIVE_SAME="$TESTDATA_DIR/effective-settings-same.json"
EFFECTIVE_DRIFT="$TESTDATA_DIR/effective-settings-drift.json"

python3 "$COMPILER" \
  --project-settings "$PROJECT_SETTINGS" \
  --effective-settings "$EFFECTIVE_SAME" \
  --output-hooks "$TMPDIR/hooks.json" \
  --output-report "$TMPDIR/report.json"

jq -e '.hooks.SessionStart[0].matcher == "startup|resume"' "$TMPDIR/hooks.json" >/dev/null
jq -e '.hooks.PreToolUse[0].matcher == ""' "$TMPDIR/hooks.json" >/dev/null
jq -e '.summary.total == 6' "$TMPDIR/report.json" >/dev/null
jq -e '.summary.supported == 3' "$TMPDIR/report.json" >/dev/null
jq -e '.summary.lossy == 1' "$TMPDIR/report.json" >/dev/null
jq -e '.summary.unsupported == 2' "$TMPDIR/report.json" >/dev/null
jq -e '.drift_detected == false' "$TMPDIR/report.json" >/dev/null

python3 "$COMPILER" \
  --project-settings "$PROJECT_SETTINGS" \
  --effective-settings "$EFFECTIVE_DRIFT" \
  --output-hooks "$TMPDIR/hooks-drift.json" \
  --output-report "$TMPDIR/report-drift.json"

jq -e '.drift_detected == true' "$TMPDIR/report-drift.json" >/dev/null

EMPTY_EFFECTIVE="$TMPDIR/effective-empty.json"
cat > "$EMPTY_EFFECTIVE" <<'EOF'
{"hooks": {}}
EOF

python3 "$COMPILER" \
  --project-settings "$PROJECT_SETTINGS" \
  --effective-settings "$EMPTY_EFFECTIVE" \
  --output-hooks "$TMPDIR/hooks-empty.json" \
  --output-report "$TMPDIR/report-empty.json"

jq -e '.drift_detected == true' "$TMPDIR/report-empty.json" >/dev/null
echo "test-hooks-sync: PASS"
```

- [ ] **Step 2: Run the test and confirm it fails because the compiler does not exist yet**

Run:

```bash
bash modules/shared/programs/claude/files/skills/syncing-codex-harness/references/test-hooks-sync.sh
```

Expected:

```text
python3: can't open file '.../compile-hooks.py': [Errno 2] No such file or directory
```

- [ ] **Step 3: Implement the compiler helper**

Create `compile-hooks.py`:

```python
#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import subprocess
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

DOCS_VALIDATED_ON = "2026-04-03"
GENERATOR = "syncing-codex-harness"


def load_json(path: str | None) -> dict:
    if not path:
        return {}
    file = Path(path)
    if not file.is_file():
        return {}
    with file.open() as handle:
        return json.load(handle)


def load_hooks(path: str | None) -> dict:
    payload = load_json(path)
    hooks = payload.get("hooks", {})
    return hooks if isinstance(hooks, dict) else {}


def detect_codex_version() -> str:
    try:
        out = subprocess.check_output(["codex", "--version"], text=True).strip()
        return out.split()[-1]
    except Exception:
        return "unknown"


def classify_group(event: str, matcher: str, hooks: list[dict]) -> tuple[str, str, dict | None]:
    matcher = "" if matcher is None else str(matcher)

    if not hooks:
        return "unsupported", "empty hooks array", None

    commands: list[dict] = []
    for hook in hooks:
        if not isinstance(hook, dict):
            return "unsupported", "hook entry must be an object", None
        if hook.get("type", "command") != "command":
            return "unsupported", "Codex sync only supports command hooks", None
        if not hook.get("command"):
            return "unsupported", "command hook is missing command", None
        commands.append({"type": "command", "command": hook["command"]})

    mapped = {"event": event, "matcher": matcher, "hooks": commands}

    if event == "SessionStart":
        if matcher in ("", "*"):
            mapped["matcher"] = "startup|resume"
            return "lossy", "empty matcher narrowed to startup|resume", mapped
        if matcher in ("startup", "resume", "startup|resume", "resume|startup"):
            return "supported", "direct event support", mapped
        return "unsupported", "SessionStart supports startup|resume only", None

    if event == "UserPromptSubmit":
        if matcher in ("", "*"):
            return "supported", "direct event support", mapped
        return "lossy", "Codex ignores UserPromptSubmit matcher", mapped

    if event == "Stop":
        if matcher in ("", "*"):
            return "supported", "direct event support", mapped
        return "lossy", "Codex ignores Stop matcher", mapped

    if event in ("PreToolUse", "PostToolUse"):
        if matcher == "Bash":
            return "supported", f"{event} Bash matcher support", mapped
        return "unsupported", f"Codex {event} currently supports Bash matcher only", None

    return "unsupported", f"no documented Codex equivalent for {event}", None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-settings", required=True)
    parser.add_argument("--effective-settings")
    parser.add_argument("--output-hooks", required=True)
    parser.add_argument("--output-report", required=True)
    args = parser.parse_args()

    project_hooks = load_hooks(args.project_settings)
    effective_hooks = load_hooks(args.effective_settings)
    drift_detected = bool(effective_hooks) and project_hooks != effective_hooks

    compiled: dict[str, list[dict]] = defaultdict(list)
    items: list[dict] = []
    counts = {"supported": 0, "lossy": 0, "unsupported": 0}
    total = 0

    for event, groups in project_hooks.items():
        if not isinstance(groups, list):
            continue
        for group in groups:
            if not isinstance(group, dict):
                continue
            matcher = group.get("matcher", "")
            hooks = group.get("hooks", [])
            commands = [hook.get("command") for hook in hooks if isinstance(hook, dict)]
            status, reason, mapping = classify_group(event, matcher, hooks)
            total += 1
            counts[status] += 1
            items.append(
                {
                    "event": event,
                    "matcher": matcher,
                    "commands": commands,
                    "status": status,
                    "reason": reason,
                    "codex_mapping": None if mapping is None else {"event": mapping["event"], "matcher": mapping["matcher"]},
                    "notes": [],
                }
            )
            if mapping is not None:
                compiled[mapping["event"]].append({"matcher": mapping["matcher"], "hooks": mapping["hooks"]})

    hooks_output = {event: groups for event, groups in compiled.items()}
    report = {
        "generated_at": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
        "generator": GENERATOR,
        "codex_cli_version": detect_codex_version(),
        "codex_hooks_docs_validated_on": DOCS_VALIDATED_ON,
        "source_settings_path": args.project_settings,
        "effective_settings_path": args.effective_settings,
        "drift_detected": drift_detected,
        "summary": {"total": total, **counts},
        "items": items,
    }

    Path(args.output_hooks).write_text(json.dumps(hooks_output, indent=2, ensure_ascii=False) + "\n")
    Path(args.output_report).write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
```

Make it executable:

```bash
chmod +x modules/shared/programs/claude/files/skills/syncing-codex-harness/references/compile-hooks.py
chmod +x modules/shared/programs/claude/files/skills/syncing-codex-harness/references/test-hooks-sync.sh
```

- [ ] **Step 4: Re-run the regression test and confirm it passes**

Run:

```bash
bash modules/shared/programs/claude/files/skills/syncing-codex-harness/references/test-hooks-sync.sh
```

Expected:

```text
test-hooks-sync: PASS
```

- [ ] **Step 5: Commit**

```bash
git add \
  modules/shared/programs/claude/files/skills/syncing-codex-harness/references/compile-hooks.py \
  modules/shared/programs/claude/files/skills/syncing-codex-harness/references/test-hooks-sync.sh \
  modules/shared/programs/claude/files/skills/syncing-codex-harness/references/testdata/hooks/project-settings.json \
  modules/shared/programs/claude/files/skills/syncing-codex-harness/references/testdata/hooks/effective-settings-same.json \
  modules/shared/programs/claude/files/skills/syncing-codex-harness/references/testdata/hooks/effective-settings-drift.json
git commit -m "feat(codex): add hooks compatibility compiler"
```

## Task 3: Wire The Compiler Into `sync.sh`

**Files:**
- Modify: `modules/shared/programs/claude/files/skills/syncing-codex-harness/references/test-hooks-sync.sh`
- Modify: `modules/shared/programs/claude/files/skills/syncing-codex-harness/references/sync.sh`

- [ ] **Step 1: Extend the regression test so it fails until `sync.sh hooks-config` exists**

Append this block to `test-hooks-sync.sh`:

```bash
SYNC_SH="$SCRIPT_DIR/sync.sh"
REPO_ROOT="$TMPDIR/repo"
HOME_ROOT="$TMPDIR/home"

mkdir -p "$REPO_ROOT/modules/shared/programs/claude/files" "$HOME_ROOT/.claude"
printf '# temp repo\n' > "$REPO_ROOT/CLAUDE.md"
cp "$PROJECT_SETTINGS" "$REPO_ROOT/modules/shared/programs/claude/files/settings.json"
cp "$EFFECTIVE_DRIFT" "$HOME_ROOT/.claude/settings.json"
git -C "$REPO_ROOT" init -q

HOME="$HOME_ROOT" CODEX_HOME="$HOME_ROOT/.codex" bash "$SYNC_SH" hooks-config "$REPO_ROOT"

jq -e '.hooks.SessionStart[0].matcher == "startup|resume"' "$REPO_ROOT/.codex/hooks.json" >/dev/null
jq -e '.summary.lossy == 1' "$REPO_ROOT/.codex/hooks.compatibility.json" >/dev/null
jq -e '.summary.supported == 3' "$REPO_ROOT/.codex/hooks.compatibility.json" >/dev/null
```

- [ ] **Step 2: Run the test and confirm it fails because `hooks-config` is unknown**

Run:

```bash
bash modules/shared/programs/claude/files/skills/syncing-codex-harness/references/test-hooks-sync.sh
```

Expected:

```text
Usage: sync.sh {...}
```

or:

```text
sync.sh: unknown subcommand hooks-config
```

- [ ] **Step 3: Add a `hooks-config` subcommand and include it in `all`**

Update the usage header in `sync.sh`:

```bash
#   sync.sh hooks-config      <project-root> [--project-settings=PATH] [--effective-settings=PATH]
#   sync.sh all               <project-root> [--local-skills-dir=DIR] [--plugin-install-path=PATH:NAME]... [--plugin-claude-md=PATH] [--user-mcp=PATH] [--user-codex-config=PATH]
```

Add the helper function above `sync_all()`:

```bash
hooks_config() {
  local project_root="$1"
  shift

  local project_settings="$project_root/modules/shared/programs/claude/files/settings.json"
  local effective_settings="${CLAUDE_SETTINGS_PATH:-$HOME/.claude/settings.json}"

  for arg in "$@"; do
    case "$arg" in
      --project-settings=*) project_settings="${arg#--project-settings=}" ;;
      --effective-settings=*) effective_settings="${arg#--effective-settings=}" ;;
    esac
  done

  if [ ! -f "$project_settings" ]; then
    echo "Warning: Hooks source settings not found: $project_settings" >&2
    return 0
  fi

  local script_dir compiler
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  compiler="$script_dir/compile-hooks.py"

  if [ ! -f "$compiler" ]; then
    echo "Warning: Hooks compiler not found: $compiler" >&2
    return 0
  fi

  mkdir -p "$project_root/.codex"

  python3 "$compiler" \
    --project-settings "$project_settings" \
    --effective-settings "$effective_settings" \
    --output-hooks "$project_root/.codex/hooks.json" \
    --output-report "$project_root/.codex/hooks.compatibility.json"
}
```

Update `sync_all()` so hooks become an explicit stage:

```bash
  echo "[6/9] MCP config updated (project)" >&2
  # ...

  hooks_config "$project_root"
  echo "[7/9] Hooks config: ${hooks_status:-unknown}" >&2

  trust_result="$(ensure_project_trusted "$project_root")"
  echo "[8/9] Trust: $trust_result" >&2

  if [ -n "$missing" ]; then
    echo "[9/9] Missing .gitignore entries:" >&2
```

Add dispatch support near the bottom:

```bash
  hooks-config)
    hooks_config "$2" "${@:3}"
    ;;
```

Update the fallback usage line:

```bash
echo "Usage: sync.sh {project-skills|plugin-skills|agents|agents-md|agents-override|mcp-config|hooks-config|trust-project|generate-openai-yaml|init|gitignore-check|all} ..." >&2
```

- [ ] **Step 4: Re-run the regression test and confirm both compiler and subcommand paths pass**

Run:

```bash
bash modules/shared/programs/claude/files/skills/syncing-codex-harness/references/test-hooks-sync.sh
```

Expected:

```text
test-hooks-sync: PASS
```

Then run the subcommand against the actual repo:

```bash
bash modules/shared/programs/claude/files/skills/syncing-codex-harness/references/sync.sh hooks-config "$PWD"
jq '.summary' .codex/hooks.compatibility.json
```

Expected:

```json
{
  "total": 10,
  "supported": 2,
  "lossy": 1,
  "unsupported": 7
}
```

- [ ] **Step 5: Commit**

```bash
git add \
  modules/shared/programs/claude/files/skills/syncing-codex-harness/references/sync.sh \
  modules/shared/programs/claude/files/skills/syncing-codex-harness/references/test-hooks-sync.sh
git commit -m "feat(codex): sync compatible hooks into project config"
```

## Task 4: Update Sync Documentation And Codex Guidance

**Files:**
- Modify: `modules/shared/programs/claude/files/skills/syncing-codex-harness/SKILL.md`
- Modify: `modules/shared/programs/claude/files/skills/syncing-codex-harness/references/codex-structure.md`
- Modify: `modules/shared/programs/claude/files/skills/syncing-codex-harness/references/agents-override-template.md`
- Modify: `modules/shared/programs/claude/files/skills/syncing-codex-harness/references/sync.sh`
- Modify: `AGENTS.override.md`

- [ ] **Step 1: Confirm the stale wording still exists before editing docs**

Run:

```bash
rg -n "Hooks/plugins not supported|Codex에서 미지원|no Codex equivalent" \
  modules/shared/programs/claude/files/skills/syncing-codex-harness \
  AGENTS.override.md
```

Expected:

```text
... stale lines are still matched ...
```

- [ ] **Step 2: Replace the stale wording with the new partial-compatibility language**

Update the `sync.sh` auto-generated note:

```bash
  auto_content+="- Claude hooks는 experimental이며, sync.sh가 호환 가능한 subset만 \`.codex/hooks.json\`로 투영한다"$'\n'
  auto_content+="- plugins와 MCP UI는 여전히 Claude Code 전용 기능이다"$'\n'
```

Update `AGENTS.override.md`:

```md
## 도구 차이

- Claude Code의 `/skill-name` 호출은 Codex에서 `$skill-name`에 대응
- Claude hooks는 experimental이며, 이 저장소는 project-local `.codex/hooks.json`에 호환 가능한 subset만 sync한다
- Claude Code plugins와 MCP UI는 Codex에서 직접 대응이 없다
```

Update `codex-structure.md`:

```md
| Hooks | `settings.json`의 `hooks` | `.codex/hooks.json` (experimental, partial compatibility) |
```

and replace the limitations note with:

```md
- Hooks are no longer "unsupported", but only a compiled subset is safe to project. This repo syncs supported/lossy Claude hook groups into `.codex/hooks.json` and records unsupported groups in `.codex/hooks.compatibility.json`.
```

Update `agents-override-template.md`:

```md
### 3. Codex-specific notes
- Skill invocation syntax: `$skill-name` (not `/skill-name`)
- Claude hooks are experimental in Codex; only the compatibility-checked subset should be projected into `.codex/hooks.json`
- Plugins remain unsupported in Codex
```

Update `SKILL.md` quick reference to include hooks:

```md
| Hooks 섹션만 | `bash "$SYNC_SH" hooks-config "$PWD"` |
```

and add this note near the “전체 재생성” section:

```md
`sync.sh all`은 `.codex/hooks.json`과 `.codex/hooks.compatibility.json`도 함께 재생성한다.
단, Codex 공식 표면에서 의미가 유지되는 hook만 포함되고 나머지는 compatibility report에 기록된다.
```

- [ ] **Step 3: Re-run the doc scan and confirm only the new wording remains**

Run:

```bash
rg -n "Hooks/plugins not supported|Codex에서 미지원|no Codex equivalent" \
  modules/shared/programs/claude/files/skills/syncing-codex-harness \
  AGENTS.override.md
```

Expected:

```text
no matches
```

Then run:

```bash
rg -n "experimental|partial compatibility|hooks.compatibility.json|hooks-config" \
  modules/shared/programs/claude/files/skills/syncing-codex-harness \
  AGENTS.override.md
```

Expected:

```text
... updated guidance matches ...
```

- [ ] **Step 4: Commit**

```bash
git add \
  modules/shared/programs/claude/files/skills/syncing-codex-harness/SKILL.md \
  modules/shared/programs/claude/files/skills/syncing-codex-harness/references/codex-structure.md \
  modules/shared/programs/claude/files/skills/syncing-codex-harness/references/agents-override-template.md \
  modules/shared/programs/claude/files/skills/syncing-codex-harness/references/sync.sh \
  AGENTS.override.md
git commit -m "docs(codex): document partial hooks compatibility"
```

## Task 5: Run End-To-End Verification And Smoke Checks

**Files:**
- Modify: none unless a verification step exposes a bug

- [ ] **Step 1: Run the deterministic regression suite**

Run:

```bash
bash modules/shared/programs/claude/files/skills/syncing-codex-harness/references/test-hooks-sync.sh
```

Expected:

```text
test-hooks-sync: PASS
```

- [ ] **Step 2: Re-run the compatibility verifier**

Run:

```bash
./scripts/ai/verify-ai-compat.sh
```

Expected:

```text
[OK] codex_hooks = true
```

If `.codex/hooks.json` and `.codex/hooks.compatibility.json` were generated in the previous task, they should also pass the new JSON checks.

- [ ] **Step 3: Run the real sync path and inspect the generated artifacts**

Run:

```bash
bash modules/shared/scripts/codex-sync.sh "$PWD"
jq '.summary' .codex/hooks.compatibility.json
jq '.hooks | keys' .codex/hooks.json
```

Expected:

```json
{
  "total": 10,
  "supported": 2,
  "lossy": 1,
  "unsupported": 7
}
```

and:

```json
[
  "SessionStart",
  "Stop",
  "UserPromptSubmit"
]
```

- [ ] **Step 4: Run a best-effort manual Codex smoke test**

Run:

```bash
codex -C "$PWD"
```

Inside the session:

```text
(pain) codex hooks smoke test
```

Then verify outside the session:

```bash
tail -n 1 ~/.claude/pain-points.jsonl
```

Expected:

```text
the last JSONL record references nixos-config and the current session/prompt
```

If the record is not written but no hook parse errors appear, capture that as a Codex runtime caveat rather than silently “fixing” it with unofficial emulation.

- [ ] **Step 5: Commit only if verification forced a code change**

If verification exposed and fixed a bug:

```bash
git add -A
git commit -m "fix(codex): address hooks sync verification issues"
```

If verification produced no code changes, do not create an extra commit.
