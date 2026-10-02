"""Scan cost on synthetic SQLite data; Rust Unicode matching is tested in runtime."""

import re
import sqlite3
from types import SimpleNamespace

import pytest

from anki_host_fixture import unused_tags


class ScanDB:
    def __init__(self, registered, note_tags):
        self.connection = sqlite3.connect(":memory:")
        self.connection.execute("create table tags(tag text, usn integer, collapsed integer)")
        self.connection.execute("create table notes(tags text)")
        self.connection.executemany("insert into tags values (?, 0, 0)", [(name,) for name in registered])
        self.connection.executemany("insert into notes values (?)", [(value,) for value in note_tags])
        self.connection.create_function("regexp", 2, lambda pattern, value: bool(re.search(pattern, value)))
        self.queries = []

    def all(self, sql, *params):
        self.queries.append((sql, params))
        return self.connection.execute(sql, params).fetchall()

    def list(self, sql, *params):
        return [row[0] for row in self.all(sql, *params)]

    def scalar(self, sql, *params):
        rows = self.all(sql, *params)
        return rows[0][0] if rows else None


def test_large_inspection_scans_notes_once_and_keeps_descendant_protection():
    empty = [f"unused-{i:04d}" for i in range(2_000)]
    live = [f"live-{i:03d}" for i in range(300)]
    db = ScanDB(empty + live + [name + "::child" for name in live] + ["keep", "keep::child"],
                [f" {live[i % len(live)]}::child " for i in range(12_000)])
    try:
        result = unused_tags.inspect(SimpleNamespace(db=db), ["KEEP"])
        assert result["unused_tags"] == empty
        assert result["protected_unused_tags"] == ["keep", "keep::child"]
        assert result["registered_count"] == 2_602
        assert [sql for sql, _ in db.queries if "from notes" in sql] == [
            "select distinct tags from notes where tags != ''"]
        # 600 distinct used names/ancestors need three registry batches, not
        # 2,602 scans of the 12,000-note table.
        assert len(db.queries) == 6  # registry + protection + usage + 3 batches
    finally:
        db.connection.close()


@pytest.mark.parametrize("registered,note_tags", [
    (["a", "a:", "a::b", "a:::b", "a::::b", "other"], [" a:::b "]),
    (["literal_*", "literal_ab", "[x]", "x", "back\\slash", "parent", "parent::child"],
     [" literal_* [x] back\\slash parent::child::leaf "]),
    (["a", "b", "a\u3000b", "x", "x\ty"], [" a\u3000b x\ty "]),
    (["parent", "parent::child", "empty"], []),
    ([], [" live "]),
])
def test_batched_scan_matches_original_boundaries(registered, note_tags):
    db = ScanDB(registered, note_tags)
    col = SimpleNamespace(db=db)
    try:
        expected = sorted(name for name in registered if not unused_tags._used(col, [name]))
        assert unused_tags.inspect(col, [])["unused_tags"] == expected
    finally:
        db.connection.close()


def test_usage_patterns_bound_count_and_encoded_size_without_losing_long_names():
    names = {f"태그.{i:04d}" * 12 for i in range(700)}
    long_name = "long." * unused_tags._USAGE_BATCH_BYTES
    names.add(long_name)
    patterns = list(unused_tags._usage_patterns(names))
    assert len(patterns) > 3
    for pattern in patterns:
        if re.escape(long_name) in pattern:
            assert pattern == "(?i)^(?:" + re.escape(long_name) + ")$"
        else:
            assert len(pattern.encode("utf-8")) <= unused_tags._USAGE_BATCH_BYTES
        assert pattern.count("|") < unused_tags._USAGE_BATCH_NAMES
    assert all(any(re.fullmatch(pattern, name) for pattern in patterns) for name in names)
