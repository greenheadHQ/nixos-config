#!/usr/bin/env python3
"""ArchiveBox user hook: enqueue snapshot events for host-side notifier.

This hook is intentionally best-effort and must not break archiving.
It always exits 0 and emits ArchiveResult JSONL.
"""

import json
import os
import sys
import time
from urllib.parse import urlparse


def parse_args() -> dict[str, str]:
    parsed: dict[str, str] = {}
    for arg in sys.argv[1:]:
        if not arg.startswith("--") or "=" not in arg:
            continue
        key, value = arg[2:].split("=", 1)
        parsed[key.replace("-", "_")] = value
    return parsed


def domain_from_url(url: str) -> str:
    try:
        return urlparse(url).hostname or "unknown"
    except Exception:
        return "unknown"


def emit_archiveresult(status: str, output_str: str) -> None:
    print(
        json.dumps(
            {
                "type": "ArchiveResult",
                "status": status,
                "output_str": output_str,
            },
            ensure_ascii=True,
        ),
        flush=True,
    )


def main() -> int:
    args = parse_args()
    snapshot_id = args.get("snapshot_id", "")
    url = args.get("url", "")

    if not snapshot_id:
        emit_archiveresult("skipped", "notify hook skipped: snapshot_id missing")
        return 0

    queue_file = os.environ.get("PUSHOVER_NOTIFY_QUEUE_FILE", "/data/notify/events.jsonl")

    event = {
        "type": "ArchiveBoxNotifyEvent",
        "snapshot_id": snapshot_id,
        "url": url,
        "domain": domain_from_url(url),
        "timestamp": int(time.time()),
    }

    try:
        os.makedirs(os.path.dirname(queue_file), exist_ok=True)
        with open(queue_file, "a", encoding="utf-8") as fp:
            fp.write(json.dumps(event, ensure_ascii=True) + "\n")

        emit_archiveresult("succeeded", "notify event queued")
    except Exception as exc:
        # Keep archiving pipeline healthy even if notification enqueue fails.
        emit_archiveresult("skipped", f"notify hook write failed: {exc}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
