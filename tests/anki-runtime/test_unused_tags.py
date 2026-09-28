"""Selected registry cleanup on generated collections with the real Anki backend."""

import pytest

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


@pytest.mark.parametrize("change", ["used", "new-child", "renamed"])
def test_changed_preview_stops_before_write(runtime, change):
    r = runtime
    nid = add(r)
    register(r, "unused")
    p = preview(r, ["unused"])
    if change == "used":
        r.col.tags.bulk_add([nid], "unused")
    elif change == "new-child":
        register(r, "unused::new")
    else:
        r.col.tags.rename("unused", "renamed")
    before, registered = preserve(r), r.col.tags.all()
    with pytest.raises(r.error):
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
