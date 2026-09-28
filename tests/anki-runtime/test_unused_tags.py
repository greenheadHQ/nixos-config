"""Selected registry cleanup on generated collections with the real Anki backend."""

import pytest
from anki.collection import AddNoteRequest

from test_real_collection import add, runtime  # noqa: F401


def preserve(r):
    return {table: r.col.db.all(f"select * from {table} order by id") for table in ("notes", "cards", "revlog")}


def register(r, *names):
    for name in names:
        r.col.tags.set_collapsed(name, True)


def preview(r, names, protected=()):
    return r.ops.prepare("remove_unused_tags", {"tags": list(names), "protected_tags": list(protected)},
                         operator_authorized=True)


def apply(r, p):
    return r.ops.apply(p["operation_id"], p["preview_token"], True, operator_authorized=True)


def test_selected_empty_registry_names_only_and_repeated_call_is_receipt(runtime):
    r = runtime
    nid = add(r)
    cid = r.col.get_note(nid).card_ids()[0]
    r.apply("set_due_date", {"card_ids": [cid], "days": "2"})
    r.col.tags.bulk_add([nid], "live::child marked")
    register(r, "live", "unused", "unused::child", "keep", "keep::child", "literal_*", "literal_ab")
    before = preserve(r)
    assert before["revlog"]
    registry = r.col.db.all("select tag, usn, collapsed from tags order by tag")
    selected = ["unused", "unused::child", "literal_*"]
    scan = r.helper.unused_tags.inspect(r.col, ["keep"])
    assert "live" not in scan["unused_tags"]
    assert scan["protected_unused_tags"] == ["keep", "keep::child"]
    assert set(selected) <= set(scan["unused_tags"])
    p = preview(r, selected, ["keep"])
    assert p["schema_required"] is False
    assert p["summary"]["notes"] == p["summary"]["cards"] == 0
    outcome = apply(r, p)
    assert outcome["state"] == "applied", outcome
    assert outcome["result"]["verified"] and outcome["result"]["notes_changed"] == 0
    assert outcome["sync"] == outcome["notification"] == {"state": "disabled"}
    assert preserve(r) == before
    assert r.col.db.all("select tag, usn, collapsed from tags order by tag") == [row for row in registry if row[0] not in selected]
    assert len(r.restored) == 2  # Scheduling and this metadata cleanup both have restore points.
    assert apply(r, p) == outcome and len(r.restored) == 2
    assert preserve(r) == before


@pytest.mark.parametrize("names,protected,error", [
    (["parent"], [], "include-all-descendants"),
    (["parent", "parent::child"], ["parent::child"], "protected-name"),
    (["parent::child"], ["PARENT"], "protected-name"),
    (["live", "live::child"], [], "in-use"),
    (["missing"], [], "missing-or-changed"),
    (["PARENT::CHILD"], [], "missing-or-changed"),
])
def test_rejects_unapproved_descendants_exceptions_live_children_and_changed_names(runtime, names, protected, error):
    r = runtime
    nid = add(r)
    r.col.tags.bulk_add([nid], "live::child")
    register(r, "live", "parent", "parent::child")
    before, registered = preserve(r), r.col.tags.all()
    with pytest.raises(r.error, match=error):
        preview(r, names, protected)
    assert preserve(r) == before and r.col.tags.all() == registered and not r.restored


@pytest.mark.parametrize("change,error", [("used", "in-use"), ("new-child", "include-all-descendants"),
                                         ("replaced-name", "missing-or-changed")])
def test_changed_preview_stops_before_write(runtime, change, error):
    r = runtime
    nid = add(r)
    register(r, "unused")
    p = preview(r, ["unused"])
    original = (preserve(r), r.col.tags.all())
    if change == "used":
        r.col.tags.bulk_add([nid], "unused")
    elif change == "new-child":
        register(r, "unused::new")
    else:
        # Anki rename is deliberately a no-op for an unused registry name.
        # Replace it through native APIs to actually invalidate the preview.
        assert r.col.tags.remove("unused").count == 0
        register(r, "renamed")
        assert "unused" not in r.col.tags.all() and "renamed" in r.col.tags.all()
    before, registered = preserve(r), r.col.tags.all()
    assert (before, registered) != original
    with pytest.raises(r.error, match=error):
        apply(r, p)
    assert preserve(r) == before and r.col.tags.all() == registered and not r.restored


def test_name_reuse_during_export_is_rechecked_on_reopened_collection(runtime):
    r = runtime
    nid = add(r)
    register(r, "unused")
    p = preview(r, ["unused"])
    restore = r.ops.restore
    def changed_during_export(opid):
        receipt = restore(opid)
        r.col.tags.bulk_add([nid], "unused")
        return receipt
    r.ops.restore = changed_during_export
    with pytest.raises(r.error, match="in-use"):
        apply(r, p)
    assert "unused" in r.col.get_note(nid).tags
    assert r.ops.status(p["operation_id"])["state"] == "prepared"
    assert len(r.restored) == 1


@pytest.mark.parametrize("registered,note_tag,used", [
    ("ss", "ß", False), ("ß", "ss", False), ("ẞ", "ß", True),
    ("İ", "i", False), ("ı", "I", False), ("K", "K", True),
    ("Σ", "ς", True), ("S", "ſ", True),
    ("a", "a:::b", True), ("a:", "a:::b", True),
    ("parent", "PARENT::child", True), ("literal_*", "literal_ab", False),
    ("literal_*", "literal_*::child", True),
])
def test_inspect_retains_native_unicode_case_and_boundary_semantics(runtime, registered, note_tag, used):
    r = runtime
    nid = add(r)
    register(r, registered)
    # Preserve different historical spelling without native registration
    # canonicalizing the note to the already registered name. Synthetic only.
    r.col.db.execute("update notes set tags = ? where id = ?", f" {note_tag} ", nid)
    assert registered in r.col.tags.all()
    assert r.helper.unused_tags._used(r.col, [registered]) is used
    before, registry = preserve(r), r.col.tags.all()
    scan = r.helper.unused_tags.inspect(r.col, [])
    assert (registered not in scan["unused_tags"]) is used
    assert preserve(r) == before and r.col.tags.all() == registry


def test_large_generated_collection_inspection_reads_notes_once(runtime, monkeypatch):
    r = runtime
    requests = []
    model = r.col.models.by_name("Basic")
    for i in range(3_000):
        note = r.col.new_note(model)
        note["Front"], note["Back"] = f"synthetic {i}", "back"
        note.tags = [f"live-{i % 300:03d}::child"]
        requests.append(AddNoteRequest(note, 1))
    r.col.add_notes(requests)
    empty = [f"unused-{i:04d}" for i in range(2_000)]
    register(r, *empty, "keep", "keep::child")
    before, registry = preserve(r), r.col.tags.all()
    queries = []
    original = r.col.db.list
    def traced(sql, *args, **kwargs):
        queries.append(sql)
        return original(sql, *args, **kwargs)
    monkeypatch.setattr(r.col.db, "list", traced)
    result = r.helper.unused_tags.inspect(r.col, ["KEEP"])
    assert result["unused_tags"] == empty
    assert result["protected_unused_tags"] == ["keep", "keep::child"]
    assert [sql for sql in queries if "from notes" in sql] == [
        "select distinct tags from notes where tags != ''"]
    assert sum(sql == "select tag from tags where tag regexp ?" for sql in queries) == 3
    assert preserve(r) == before and r.col.tags.all() == registry
