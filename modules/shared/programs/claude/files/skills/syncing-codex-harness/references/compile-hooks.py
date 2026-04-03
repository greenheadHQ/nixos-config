#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path

DOCS_VALIDATED_ON = "2026-04-03"
GENERATOR = "syncing-codex-harness"


def load_json(path: str | None, *, required: bool = False) -> tuple[dict, bool]:
    if not path:
        return {}, False

    file = Path(path)
    if not file.is_file():
        return {}, False

    try:
        with file.open() as handle:
            payload = json.load(handle)
    except (OSError, json.JSONDecodeError):
        if required:
            raise
        return {}, True

    return (payload if isinstance(payload, dict) else {}), True


def load_hooks(path: str | None, *, required: bool = False) -> tuple[dict[str, list[dict]], bool]:
    payload, present = load_json(path, required=required)
    hooks = payload.get("hooks", {})
    return (hooks if isinstance(hooks, dict) else {}), present


def detect_codex_version() -> str:
    try:
        output = subprocess.check_output(
            ["codex", "--version"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except Exception:
        return "unknown"

    parts = output.split()
    return parts[-1] if parts else "unknown"


def normalize_command_hooks(hooks: list[dict]) -> list[dict] | None:
    commands: list[dict] = []

    for hook in hooks:
        if not isinstance(hook, dict):
            return None

        hook_type = hook.get("type", "command")
        command = hook.get("command")
        if hook_type != "command" or not command:
            return None

        commands.append({"type": "command", "command": command})

    return commands


def matcher_supports_bash(matcher: str) -> bool:
    if matcher in ("", "*"):
        return True

    try:
        return re.search(matcher, "Bash") is not None
    except re.error:
        return False


def classify_group(event: str, matcher: str, hooks: list[dict]) -> tuple[str, str, dict | None]:
    matcher = "" if matcher is None else str(matcher)
    normalized_hooks = normalize_command_hooks(hooks)

    if not normalized_hooks:
        return "unsupported", "Codex sync only supports non-empty command hooks", None

    mapping = {
        "event": event,
        "matcher": matcher,
        "hooks": normalized_hooks,
    }

    if event == "SessionStart":
        if matcher in ("", "*"):
            mapping["matcher"] = "startup|resume"
            return "lossy", "empty matcher narrowed to startup|resume", mapping
        if matcher in ("startup", "resume", "startup|resume", "resume|startup"):
            return "supported", "direct event support", mapping
        return "unsupported", "SessionStart supports startup|resume only", None

    if event == "UserPromptSubmit":
        if matcher in ("", "*"):
            return "supported", "direct event support", mapping
        return "lossy", "Codex ignores UserPromptSubmit matcher", mapping

    if event == "Stop":
        if matcher in ("", "*"):
            return "supported", "direct event support", mapping
        return "lossy", "Codex ignores Stop matcher", mapping

    if event in ("PreToolUse", "PostToolUse"):
        if matcher_supports_bash(matcher):
            return "supported", f"{event} Bash matcher support", mapping
        return "unsupported", f"Codex {event} currently supports Bash matcher only", None

    return "unsupported", f"no documented Codex equivalent for {event}", None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-settings", required=True)
    parser.add_argument("--effective-settings")
    parser.add_argument("--output-hooks", required=True)
    parser.add_argument("--output-report", required=True)
    args = parser.parse_args()

    project_hooks, _ = load_hooks(args.project_settings, required=True)
    effective_hooks, effective_present = load_hooks(args.effective_settings)
    drift_detected = effective_present and project_hooks != effective_hooks

    compiled_hooks: dict[str, list[dict]] = {}
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
            commands = [
                hook.get("command")
                for hook in hooks
                if isinstance(hook, dict) and hook.get("command")
            ]

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
                    "codex_mapping": None
                    if mapping is None
                    else {"event": mapping["event"], "matcher": mapping["matcher"]},
                    "notes": [],
                }
            )

            if mapping is not None:
                compiled_hooks.setdefault(mapping["event"], []).append(
                    {"matcher": mapping["matcher"], "hooks": mapping["hooks"]}
                )

    report = {
        "generated_at": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
        "generator": GENERATOR,
        "codex_cli_version": detect_codex_version(),
        "codex_hooks_docs_validated_on": DOCS_VALIDATED_ON,
        "source_settings_path": args.project_settings,
        "effective_settings_path": args.effective_settings,
        "drift_detected": drift_detected,
        "summary": {
            "total": total,
            "supported": counts["supported"],
            "lossy": counts["lossy"],
            "unsupported": counts["unsupported"],
        },
        "items": items,
    }

    hooks_payload = {"hooks": compiled_hooks}
    Path(args.output_hooks).write_text(json.dumps(hooks_payload, indent=2) + "\n")
    Path(args.output_report).write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
