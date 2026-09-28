"""Selected, unused registry names only. Called under the helper mutation lock.

Use Anki's own SQLite regexp function for the same Unicode/case and hierarchy
matching as tags.remove(). No caller can supply SQL or a regular expression.
"""

from __future__ import annotations

import re
from typing import Any

from .operations import OperationError, digest, tags


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


def inspect(col: Any, protected_tags: list[str]) -> dict[str, Any]:
    protected_tags = tags(protected_tags)
    registered = [row[0] for row in _registry(col)]
    protected = set(_matching(col, protected_tags))
    unused = [name for name in registered if not _used(col, [name])]
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
