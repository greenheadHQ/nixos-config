#!/usr/bin/env python3
"""Disable autonomous daemon updates without replacing unrelated settings."""

import fcntl
import json
import os
from pathlib import Path
import sys
import tempfile
import time


def reject_non_json_constant(_value: str) -> None:
    raise ValueError("invalid-json-constant")


def disable_auto_update(codex_home: Path, timeout: float) -> None:
    state_dir = codex_home / "app-server-daemon"
    state_dir.mkdir(parents=True, exist_ok=True)
    # Match the native lifecycle lock. Never replace/unlink this inode; the
    # settings file is read only after acquiring it to preserve concurrent edits.
    lock_fd = os.open(state_dir / "daemon.lock", os.O_RDWR | os.O_CREAT, 0o600)
    with os.fdopen(lock_fd, "a") as lock:
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError("settings-lock-timeout") from None
                time.sleep(min(0.05, max(0, deadline - time.monotonic())))

        target = state_dir / "settings.json"
        try:
            with target.open(encoding="utf-8") as source:
                settings = json.load(source, parse_constant=reject_non_json_constant)
        except FileNotFoundError:
            settings = {}
        if not isinstance(settings, dict):
            raise ValueError("settings-root-must-be-object")
        updater = settings.get("updater", {})
        if not isinstance(updater, dict):
            raise ValueError("settings-updater-must-be-object")
        if updater.get("autoUpdateEnabled") is False:
            return
        updater["autoUpdateEnabled"] = False
        settings["updater"] = updater

        fd, temp_name = tempfile.mkstemp(prefix=".settings-", dir=state_dir)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as output:
                json.dump(settings, output, ensure_ascii=False, indent=2, allow_nan=False)
                output.write("\n")
                output.flush()
                os.fsync(output.fileno())
            os.replace(temp_name, target)
        finally:
            if os.path.lexists(temp_name):
                os.unlink(temp_name)
    # Release before running any native CLI lifecycle command, which takes the
    # same lock. Lock ownership never escapes this short-lived helper process.


def main() -> int:
    try:
        if len(sys.argv) != 3:
            raise ValueError("invalid-arguments")
        timeout = float(sys.argv[2])
        if timeout < 0 or not timeout < float("inf"):
            raise ValueError("invalid-timeout")
        disable_auto_update(Path(sys.argv[1]), timeout)
    except (OSError, ValueError, TimeoutError) as error:
        # Report only a stable failure class.
        print(f"daemon-settings: {type(error).__name__}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
