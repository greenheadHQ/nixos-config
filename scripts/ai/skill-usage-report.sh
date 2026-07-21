#!/usr/bin/env bash
# skill-usage-report.sh - summarize Claude Skill hook usage.
# Usage: scripts/ai/skill-usage-report.sh [--log PATH] [--since YYYY-MM-DD]
# Usage: scripts/ai/skill-usage-report.sh --log ~/skill-usage.log --since 2026-01-01
#
# Consumes the log emitted by modules/shared/programs/claude/files/hooks/log-skill.sh.
# Rows starting with "{" are strict v2 JSONL events; other rows are legacy TSV
# (read-only compatibility). Schema definitions live in that hook; update together.
set -euo pipefail

DEFAULT_LOG="${HOME}/.claude/skill-usage.log"
log_file="$DEFAULT_LOG"
since_date=""

usage() {
  cat <<'EOF'
Usage: skill-usage-report.sh [--log PATH] [--since YYYY-MM-DD]

Summarize Claude Skill usage from the log-skill.sh log (v2 JSONL events + legacy TSV rows).
EOF
}

die() {
  echo "skill-usage-report: $*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --log)
      [ "$#" -ge 2 ] || die "--log requires a path"
      log_file="$2"
      shift 2
      ;;
    --since)
      [ "$#" -ge 2 ] || die "--since requires YYYY-MM-DD"
      since_date="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

if [ -n "$since_date" ] && [[ ! "$since_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  die "invalid --since date: $since_date (expected YYYY-MM-DD)"
fi

if [ ! -e "$log_file" ]; then
  die "skill usage log not found: $log_file (default: $DEFAULT_LOG; use --log PATH for imported logs)"
fi
if [ ! -f "$log_file" ]; then
  die "skill usage log is not a regular file: $log_file"
fi
if [ ! -r "$log_file" ]; then
  die "skill usage log is not readable: $log_file"
fi

command -v python3 >/dev/null 2>&1 || die "python3 is required"

python3 - "$log_file" "$since_date" <<'PY'
from __future__ import annotations

import json
import re
import sys
from collections import defaultdict
from datetime import date, datetime, time, timezone

log_path = sys.argv[1]
since_arg = sys.argv[2]

since_epoch = None
if since_arg:
    try:
        since_day = date.fromisoformat(since_arg)
    except ValueError:
        print(
            f"skill-usage-report: invalid --since date: {since_arg}",
            file=sys.stderr,
        )
        sys.exit(1)
    since_epoch = int(
        datetime.combine(since_day, time.min, tzinfo=timezone.utc).timestamp()
    )

rows: dict[str, dict[str, int]] = defaultdict(
    lambda: {"count": 0, "first": 0, "recent": 0}
)

# v2 event contract (log-skill.sh와 동기 유지): exact 6-key set + exact types.
V2_KEYS = {"schema_version", "event_type", "ts", "runtime", "skill", "session_key"}
SESSION_KEY_RE = re.compile(r"^[0-9a-f]{64}$")


def parse_v2_event(line: str) -> tuple[int, str] | None:
    """Strict v2 JSONL row -> (timestamp, skill). Malformed rows are skipped."""
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        return None
    if not isinstance(event, dict) or set(event) != V2_KEYS:
        return None
    if type(event["schema_version"]) is not int or event["schema_version"] != 2:
        return None
    if event["event_type"] != "skill_invocation":
        return None
    if type(event["ts"]) is not int:
        return None
    if not isinstance(event["runtime"], str) or not event["runtime"]:
        return None
    if not isinstance(event["skill"], str) or not event["skill"]:
        return None
    if not isinstance(event["session_key"], str) or not SESSION_KEY_RE.match(
        event["session_key"]
    ):
        return None
    return event["ts"], event["skill"]


with open(log_path, "r", encoding="utf-8", errors="replace", newline="") as handle:
    for raw_line in handle:
        line = raw_line.rstrip("\n")
        if not line:
            continue

        if line.startswith("{"):
            parsed = parse_v2_event(line)
            if parsed is None:
                continue
            timestamp, skill = parsed
        else:
            fields = line.split("\t")
            if len(fields) < 5:
                continue

            try:
                timestamp = int(fields[0])
            except ValueError:
                continue

            skill = fields[4]
            if not skill:
                continue

        if since_epoch is not None and timestamp < since_epoch:
            continue

        row = rows[skill]
        row["count"] += 1
        row["first"] = timestamp if row["first"] == 0 else min(row["first"], timestamp)
        row["recent"] = max(row["recent"], timestamp)

print("skill\tcount\tfirst_used\trecent_used")
for skill, row in sorted(rows.items(), key=lambda item: (-item[1]["count"], item[0])):
    first = datetime.fromtimestamp(row["first"], tz=timezone.utc).date().isoformat()
    recent = datetime.fromtimestamp(row["recent"], tz=timezone.utc).date().isoformat()
    print(f"{skill}\t{row['count']}\t{first}\t{recent}")
PY
