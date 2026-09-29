"""Selected, unused registry names only. Called under the helper mutation lock.

Use Anki's own SQLite regexp function for the same Unicode/case and hierarchy
matching as tags.remove(). No caller can supply SQL or a regular expression.
"""

from __future__ import annotations

import re
from collections.abc import Iterator
from typing import Any

from .operations import OperationError, digest, tags


_USAGE_BATCH_NAMES = 256
_USAGE_BATCH_BYTES = 16 * 1024


def _pattern(names: list[str], *, in_notes: bool = False) -> str:
    alternatives = "|".join(re.escape(name) for name in names)
    start, end = (r"(?:^| )", r"(?:::| |$)") if in_notes else ("^", r"(?:::|$)")
    return f"(?i){start}(?:{alternatives}){end}"


def _matching(col: Any, names: list[str]) -> list[str]:
    if not names:
        return []
    return col.db.list("select tag from tags where tag regexp ? order by tag", _pattern(names))


def _used(col: Any, names: list[str]) -> bool:
    return bool(names and col.db.scalar("select 1 from notes where tags regexp ? limit 1",
                                       _pattern(names, in_notes=True)))


def _registry(col: Any) -> list[list[Any]]:
    return col.db.all("select tag, usn, collapsed from tags order by tag")


def _note_tags(col: Any) -> list[list[Any]]:
    return col.db.all("select id, tags, mod, usn from notes order by id")


def _usage_patterns(names: set[str]) -> Iterator[str]:
    batch: list[str] = []
    overhead = len("(?i)^(?:)$")
    size = overhead
    for name in sorted(names):
        escaped = re.escape(name)
        length = len(escaped.encode("utf-8")) + 1
        if batch and (len(batch) == _USAGE_BATCH_NAMES or size + length > _USAGE_BATCH_BYTES):
            yield "(?i)^(?:" + "|".join(batch) + ")$"
            batch, size = [], overhead
        # A single long name stays intact in its own pattern, never truncated.
        batch.append(escaped)
        size += length
    if batch:
        yield "(?i)^(?:" + "|".join(batch) + ")$"


def _used_registry(col: Any) -> set[str]:
    names: set[str] = set()
    # Scan notes once, irrespective of the number of unused registered names.
    for value in col.db.list("select distinct tags from notes where tags != ''"):
        for name in value.split(" "):
            if name:
                names.add(name)
                # Include overlapping boundaries: a:::b uses both a and a:.
                names.update(name[:match.start()] for match in re.finditer(r"(?=::)", name))
    used: set[str] = set()
    for pattern in _usage_patterns(names):
        # Reverse the literal match using Anki's Rust Unicode simple folding.
        # Python casefold() would incorrectly conflate e.g. ss with ß. Bound
        # unions so distinct usage cannot produce one enormous compiled regex.
        used.update(col.db.list("select tag from tags where tag regexp ?", pattern))
    return used


def inspect(col: Any, protected_tags: list[str]) -> dict[str, Any]:
    protected_tags = tags(protected_tags)
    registered = [row[0] for row in _registry(col)]
    protected = set(_matching(col, protected_tags))
    used = _used_registry(col) if registered else set()
    unused = [name for name in registered if name not in used]
    return {"unused_tags": [name for name in unused if name not in protected],
            "protected_unused_tags": [name for name in unused if name in protected],
            "registered_count": len(registered), "scope": "local-tag-registry"}


def checked_snapshot(col: Any, selected: list[str], protected: list[str]) -> dict[str, Any]:
    registry = _registry(col)
    known = {row[0] for row in registry}
    if not selected or not set(selected) <= known:
        raise OperationError("unused-tag-name-missing-or-changed")
    affected = set(_matching(col, selected))
    if affected != set(selected):
        raise OperationError("unused-tag-selection-must-include-all-descendants")
    if affected & set(_matching(col, protected)):
        raise OperationError("unused-tag-selection-includes-protected-name")
    if _used(col, selected):
        raise OperationError("selected-tag-or-descendant-is-in-use")
    # Registry metadata and note tag assignments bind the preview to the current
    # names and usage. Export/reopen is followed by another live inspection.
    return {"registry": registry, "note_tags_digest": digest(_note_tags(col))}


def apply(col: Any, selected: list[str], protected: list[str]) -> dict[str, Any]:
    before = checked_snapshot(col, selected, protected)
    expected = [row for row in before["registry"] if row[0] not in selected]
    changed = col.tags.remove(" ".join(selected))
    verified = (changed.count == 0 and _registry(col) == expected
                and digest(_note_tags(col)) == before["note_tags_digest"])
    return {"state": "applied" if verified else "partial", "scope": "local-tag-registry",
            "removed_tags": selected, "removed_count": len(selected) if verified else None,
            "verified": verified, "notes_changed": changed.count}
