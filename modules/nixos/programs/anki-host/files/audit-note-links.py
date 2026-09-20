#!/usr/bin/env python3
"""Inventory stored Note Linker markers from a complete, read-only note export.

Input: {"notes": [...], "page": {"total": N}}. Notes use the public MCP
noteId/modelName/fields shape; AnkiConnect's {value, order} field shape is also
accepted. The caller must collect every page and set the collection total.
This is a storage audit, not a renderer: markers inside code, attributes or
unsupported HTML are still reported and require contextual review before repair.
No collection, network, credentials, or mutation API is accessed here.
"""

import argparse
from collections import Counter, defaultdict
import json
import os
from pathlib import Path
import re


# Keep storage parsing compatible with the pinned Anki Note Linker package.
# HTML is deliberately left untouched, including markup in the display title.
NOTE_LINK_PATTERN = re.compile(r"\[((?:[^\[]|\\\[)*?)\|nid(\d{13})\]")


def audit(snapshot):
    """Return ordered occurrences and missing-target groups, without edits."""
    if not isinstance(snapshot, dict) or not isinstance(snapshot.get("notes"), list):
        raise ValueError("snapshot-notes-required")
    notes = snapshot["notes"]
    page = snapshot.get("page")
    if not isinstance(page, dict) or type(page.get("total")) is not int:
        raise ValueError("complete-collection-total-required")
    if page["total"] != len(notes):
        raise ValueError("incomplete-collection-snapshot")
    ids = set()
    normalized = []
    for note in notes:
        if not isinstance(note, dict):
            raise ValueError("invalid-note")
        note_id = note.get("noteId")
        if type(note_id) is not int or note_id <= 0 or note_id in ids:
            raise ValueError("invalid-or-duplicate-note-id")
        ids.add(note_id)
        if not isinstance(note.get("modelName"), str) or not isinstance(note.get("fields"), dict):
            raise ValueError("invalid-note-model-or-fields")
        fields = {}
        for name, value in note["fields"].items():
            if isinstance(value, dict):
                value = value.get("value")
            if not isinstance(name, str) or not isinstance(value, str):
                raise ValueError("full-string-fields-required")
            fields[name] = value
        normalized.append((note_id, note["modelName"], fields))

    occurrences = []
    for note_id, model, fields in normalized:
        for field, value in fields.items():
            for match in NOTE_LINK_PATTERN.finditer(value):
                target = int(match[2])
                occurrences.append({
                    "source_note_id": note_id,
                    "model_name": model,
                    "field_name": field,
                    "target_note_id": target,
                    "target_exists": target in ids,
                    "title_html": match[1].replace(r"\[", "["),
                    "raw_marker": match[0],
                    # Python string offsets, not UTF-8 byte offsets.
                    "start": match.start(),
                    "end": match.end(),
                })
    missing = [item for item in occurrences if not item["target_exists"]]
    counts = Counter()
    source_ids = defaultdict(set)
    for item in missing:
        target = item["target_note_id"]
        counts[target] += 1
        source_ids[target].add(item["source_note_id"])
    return {
        "summary": {
            "notes_scanned": len(notes),
            "stored_markers": len(occurrences),
            "missing_targets": len(counts),
            "missing_occurrences": len(missing),
            "missing_source_notes": len({item["source_note_id"] for item in missing}),
        },
        "missing_targets": [{
            "target_note_id": target,
            "occurrences": count,
            "source_note_ids": sorted(source_ids[target]),
        } for target, count in sorted(counts.items())],
        "occurrences": occurrences,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path,
                        help="New private JSON report; existing paths are never overwritten.")
    args = parser.parse_args()
    try:
        report = audit(json.loads(args.input.read_text(encoding="utf-8")))
        # Reports contain private note titles. No contents are printed to stdout.
        fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as file:
            json.dump(report, file, ensure_ascii=False, indent=2)
            file.write("\n")
    except (OSError, ValueError) as error:
        parser.exit(1, f"audit failed: {type(error).__name__}\n")
    print(json.dumps(report["summary"]))


if __name__ == "__main__":
    main()
