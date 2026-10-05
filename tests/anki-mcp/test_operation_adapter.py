import re
import sqlite3
from types import SimpleNamespace

import pytest

from anki_host_fixture.operation_adapter import AnkiAdapter
from anki_host_fixture.operations import Operations, OperationError


class DB:
    def __init__(self):
        self.db = sqlite3.connect(":memory:")
        self.db.executescript("""
            create table notes(id integer primary key, mid integer, flds text);
            create table cards(id integer primary key, nid integer, did integer, odid integer, ord integer);
            create table revlog(id integer primary key, cid integer, ease integer);
            insert into notes values(1, 1, 'old');
            insert into cards values(10, 1, 1, 0, 0);
            insert into revlog values(100, 10, 3);
        """)
    def all(self, sql, *args): return [list(row) for row in self.db.execute(sql, args)]
    def list(self, sql, *args): return [row[0] for row in self.db.execute(sql, args)]
    def scalar(self, sql, *args): return self.db.execute(sql, args).fetchone()[0]


class Note(dict):
    def __init__(self, col, nid):
        super().__init__({"Text": "{{c1::old}}"})
        self.col, self.id = col, nid
    def card_ids(self): return self.col.db.list("select id from cards where nid=?", self.id)
    def note_type(self): return self.col.model


class Col:
    def __init__(self):
        self.db = DB()
        self.model = {"id": 1, "name": "Cloze", "type": 1, "flds": [{"name": "Text", "ord": 0}],
                      "tmpls": [{"name": "Cloze", "ord": 0, "qfmt": "{{cloze:Text}}", "afmt": "{{cloze:Text}}"}], "css": ""}
        self.models = SimpleNamespace(by_name=lambda name: self.model if name == "Cloze" else None)
        self.deck_list = [{"id": 1, "name": "A", "dyn": 0, "conf": 1}, {"id": 2, "name": "B", "dyn": 0, "conf": 1}]
        self.decks = SimpleNamespace(all=lambda: self.deck_list)
    def new_note(self, model):
        class UnsavedNote(dict):
            def cloze_numbers_in_fields(self):
                # Anki API boundary double for these simple fixture strings.
                # Real parser/card-generation agreement is checked by the
                # separate pinned Anki runtime suite, not this test double.
                return {int(number) for field in self.values()
                        for group in re.findall(r"\{\{c([0-9,]+)::", field)
                        for number in group.split(",") if number and 0 < int(number) <= 65535}
        return UnsavedNote({field["name"]: "" for field in model["flds"]})
    def get_note(self, nid):
        if not self.db.list("select id from notes where id=?", nid):
            raise ValueError("not found")
        return Note(self, nid)
    def get_card(self, cid):
        rows = self.db.all("select id, nid, did, odid, ord from cards where id=?", cid)
        if not rows:
            raise ValueError("not found")
        return SimpleNamespace(**dict(zip(("id", "nid", "did", "odid", "ord"), rows[0], strict=True)))


def adapter_fixture(tmp_path):
    col = Col()
    window = SimpleNamespace(col=col, reset=lambda: None, _anki_host_connect_version=1)
    adapter = AnkiAdapter(window, 5242880)
    ops = Operations(tmp_path, adapter, lambda _: {"mirrored": True}, ttl=600, bulk_limit=20, media_limit=5242880)
    return ops, adapter, col


def test_field_update_counts_new_cloze_cards_and_retained_old_cards(tmp_path):
    ops, _adapter, col = adapter_fixture(tmp_path)
    # Old c1 card remains; c2 through c21 generate twenty additional cards.
    text = " ".join("{{c%d::new}}" % n for n in range(2, 22))
    preview = ops.prepare("update_fields", {"note_id": 1, "fields": {"Text": text}}, "cloze001")
    assert preview["summary"]["cards"] == 21 and preview["backup_required"]
    assert col.db.scalar("select count() from cards") == 1


def test_template_update_expected_preimage_and_model_id_are_checked_before_prepare(tmp_path):
    ops, _adapter, col = adapter_fixture(tmp_path)
    template = col.model["tmpls"][0]
    base = {
        "model_name": "Cloze", "template_name": "Cloze",
        "front": "{{cloze:Text}}!", "back": "{{cloze:Text}}!",
        "expected_model_id": col.model["id"],
        "expected_front": template["qfmt"], "expected_back": template["afmt"],
    }
    assert ops.prepare("model_template_update", base, "template-cas")["state"] == "prepared"

    for key, value in (("expected_model_id", col.model["id"] + 1),
                       ("expected_front", "stale front"),
                       ("expected_back", "stale back")):
        wrong = {**base, key: value}
        with pytest.raises(OperationError, match="expected-model-or-template-value-mismatch"):
            ops.prepare("model_template_update", wrong, f"wrong-{key}")


def test_deck_delete_snapshot_includes_siblings_without_deleting_them(tmp_path):
    ops, _adapter, col = adapter_fixture(tmp_path)
    col.db.db.execute("insert into cards values(11, 1, 2, 0, 1)")
    preview = ops.prepare("delete_decks", {"deck_names": ["A"]}, "deckdel01")
    assert preview["summary"]["card_ids"] == [10]
    assert preview["summary"]["cards_to_remove"] == 1 and preview["summary"]["notes_to_remove"] == 0
    # The note would become orphaned if its sibling disappears before apply.
    col.db.db.execute("delete from cards where id=11")
    with pytest.raises(OperationError, match="stale-preview"):
        ops.apply(preview["operation_id"], preview["preview_token"], True)
    assert col.db.scalar("select count() from notes") == 1


def test_new_child_deck_after_preview_is_stale(tmp_path):
    ops, _adapter, col = adapter_fixture(tmp_path)
    p = ops.prepare("delete_decks", {"deck_names": ["A"]}, "children1")
    col.deck_list.append({"id": 3, "name": "A::child", "dyn": 0, "conf": 1})
    with pytest.raises(OperationError, match="stale-preview"):
        ops.apply(p["operation_id"], p["preview_token"], True)


@pytest.mark.parametrize("count", [0, 1, 10, 100])
def test_deck_delete_reads_each_card_once_per_inspection(tmp_path, monkeypatch, count):
    _ops, adapter, col = adapter_fixture(tmp_path)
    col.db.db.execute("delete from cards")
    col.db.db.executemany("insert into cards values(?, 1, 1, 0, ?)", [(10 + i, i) for i in range(count)])
    original, calls = col.get_card, []
    def get_card(cid):
        calls.append(cid)
        return original(cid)
    monkeypatch.setattr(col, "get_card", get_card)
    spec = {"action": "delete_decks", "params": {"deck_names": ["A"]}}
    first = adapter.inspect(spec)
    assert calls == list(range(10, 10 + count))
    assert first["summary"]["cards_to_remove"] == count
    assert first["summary"]["notes_to_remove"] == bool(count)
    calls.clear()
    col.db.db.execute("insert into cards values(999, 1, 2, 0, 999)")
    second = adapter.inspect(spec)
    assert calls == list(range(10, 10 + count))
    assert second["summary"]["notes_to_remove"] == 0
    if count:
        assert second["snapshot"]["note_card_membership"] != first["snapshot"]["note_card_membership"]


def test_deck_delete_counts_surviving_siblings_and_filtered_returns(tmp_path, monkeypatch):
    _ops, adapter, col = adapter_fixture(tmp_path)
    col.deck_list.extend([{"id": 3, "name": "A::Child", "dyn": 0}, {"id": 4, "name": "Filtered", "dyn": 1}])
    col.db.db.executemany("insert into notes values(?, 1, 'keep')", [(i,) for i in range(2, 6)])
    col.db.db.executemany("insert into cards values(?, ?, ?, ?, ?)", [
        (11, 1, 2, 0, 1), (20, 2, 1, 0, 0), (21, 2, 3, 0, 1),
        (30, 3, 4, 1, 0), (40, 4, 4, 2, 0), (50, 5, 2, 0, 0)])
    before = [col.db.all("select * from " + table) for table in ("notes", "cards", "revlog")]
    original, calls = col.get_card, []
    def get_card(cid):
        calls.append(cid)
        return original(cid)
    monkeypatch.setattr(col, "get_card", get_card)
    result = adapter.inspect({"action": "delete_decks", "params": {"deck_names": ["A", "A::Child", "Filtered"]}})
    assert calls == [10, 20, 21, 30, 40]
    assert result["summary"]["cards_to_remove"] == 4
    assert result["summary"]["notes_to_remove"] == 2
    assert result["snapshot"]["note_card_membership"] == [[10, 1], [11, 1], [20, 2], [21, 2], [30, 3], [40, 4]]
    assert [col.db.all("select * from " + table) for table in ("notes", "cards", "revlog")] == before


def test_deck_delete_keeps_first_sorted_card_failure(tmp_path, monkeypatch):
    _ops, adapter, col = adapter_fixture(tmp_path)
    col.db.db.execute("insert into cards values(11, 1, 1, 0, 1)")
    calls = []
    def get_card(cid):
        calls.append(cid)
        raise ValueError("missing")
    monkeypatch.setattr(col, "get_card", get_card)
    with pytest.raises(OperationError, match="^card-not-found$"):
        adapter.inspect({"action": "delete_decks", "params": {"deck_names": ["A"]}})
    assert calls == [10]


@pytest.mark.parametrize("action", ["delete_notes", "delete_decks"])
@pytest.mark.parametrize("change", ["preserved", "removed", "changed", "added"])
def test_deletion_review_receipt_is_read_back_and_mismatch_is_partial(tmp_path, action, change):
    ops, adapter, col = adapter_fixture(tmp_path)
    params = {"note_ids": [1]} if action == "delete_notes" else {"deck_names": ["A"]}
    preview = ops.prepare(action, params)
    assert preview["summary"]["affected_review_rows"] == 1
    assert any("before deletion, not rows removed" in warning for warning in preview["summary"]["warnings"])

    def delete(**_):
        col.db.db.execute("delete from cards where id=10")
        col.db.db.execute("delete from notes where id=1")
        if change == "removed":
            col.db.db.execute("delete from revlog where cid=10")
        elif change == "changed":
            col.db.db.execute("update revlog set ease=1 where cid=10")
        elif change == "added":
            col.db.db.execute("insert into revlog values(101, 10, 2)")
    adapter.mw._anki_host_connect = SimpleNamespace(deleteNotes=delete, deleteDecks=delete)
    outcome = ops.apply(preview["operation_id"], preview["preview_token"], True)
    assert outcome["result"]["retained_review_rows"] == {"removed": 0, "added": 2}.get(change, 1)
    assert outcome["state"] == ("applied" if change == "preserved" else "partial")


@pytest.mark.parametrize("returned", [[None], [], [42, 43], None])
def test_add_notes_never_marks_malformed_or_null_ids_as_success(returned):
    ac = SimpleNamespace(canAddNotesWithErrorDetail=lambda **_: [{"canAdd": True}], addNotes=lambda **_: returned)
    window = SimpleNamespace(_anki_host_connect_version=1, _anki_host_connect=ac)
    adapter = AnkiAdapter(window, 100)
    result = adapter._add_notes({"allow_duplicate": False, "notes": [
        {"deck_name": "A", "model_name": "Basic", "fields": {"Front": "x"}, "tags": []}]})
    assert result["state"] == "partial" and result["added"] == 0
    assert result["results"] == [{"noteId": None, "error": "add-result-unknown"}]


def test_suspend_does_not_let_upstream_mutate_recorded_target_list():
    def suspend(cards, suspend): cards.clear()  # Upstream mutates the supplied list.
    ac = SimpleNamespace(suspend=suspend, areSuspended=lambda cards: [True for _ in cards])
    adapter = AnkiAdapter(SimpleNamespace(_anki_host_connect_version=1, _anki_host_connect=ac, reset=lambda: None), 100)
    spec = {"action": "suspend_cards", "params": {"card_ids": [10, 11], "suspended": True}}
    assert adapter.apply(spec)["state"] == "applied" and spec["params"]["card_ids"] == [10, 11]


@pytest.mark.parametrize("action", ["add_notes", "update_fields", "update_fields_bulk"])
@pytest.mark.parametrize("syntax", ["comma", "leading-zero"])
@pytest.mark.parametrize("card_count", [20, 21])
def test_supported_cloze_syntax_preserves_bulk_safety_boundary(tmp_path, action, syntax, card_count):
    ops, _adapter, col = adapter_fixture(tmp_path)
    text = ("{{c" + ",".join(str(n) for n in range(1, card_count + 1)) + "::new}}"
            if syntax == "comma" else " ".join("{{c%03d::new}}" % n for n in range(1, card_count + 1)))
    if action == "add_notes":
        params = {"notes": [{"deck_name": "A", "model_name": "Cloze", "fields": {"Text": text}, "tags": []}],
                  "allow_duplicate": False}
    else:
        update = {"note_id": 1, "fields": {"Text": text}}
        params = {"notes": [update]} if action == "update_fields_bulk" else update
    preview = ops.prepare(action, params)
    assert preview["summary"]["cards"] == card_count
    assert preview["confirmation_required"] is (card_count > 20)
    assert preview["backup_required"] is (action != "add_notes" or card_count > 20)
    if card_count > 20:
        with pytest.raises(OperationError, match="explicit-confirmation-required"):
            ops.apply(preview["operation_id"], preview["preview_token"])
    assert col.db.scalar("select count() from cards") == 1


def test_model_info_preserves_native_card_generation_requirements(tmp_path):
    _ops, adapter, col = adapter_fixture(tmp_path)
    col.model["req"] = [[0, "any", [0]]]
    result = adapter.model_info("Cloze")
    assert result["req"] == [[0, "any", [0]]]
    result["req"][0][2].append(1)
    assert col.model["req"] == [[0, "any", [0]]]


@pytest.mark.parametrize("action", ["add_notes", "update_fields", "update_fields_bulk"])
def test_predeployment_cloze_preview_requires_fresh_review_after_count_correction(tmp_path, action):
    import json
    ops, _adapter, col = adapter_fixture(tmp_path)
    text = "{{c" + ",".join(str(n) for n in range(1, 22)) + "::new}}"
    if action == "add_notes":
        params = {"notes": [{"deck_name": "A", "model_name": "Cloze", "fields": {"Text": text}, "tags": []}],
                  "allow_duplicate": False}
    else:
        update = {"note_id": 1, "fields": {"Text": text}}
        params = {"notes": [update]} if action == "update_fields_bulk" else update
    preview = ops.prepare(action, params)
    # Replay the persisted preview format from the pre-fix helper: its payload
    # and snapshot match, but the user only saw one anticipated card.
    journal = tmp_path / (preview["operation_id"] + ".json")
    record = json.loads(journal.read_text())
    record["summary"]["cards"] = 1
    record["confirmation_required"] = False
    record["backup_required"] = action != "add_notes"
    journal.write_text(json.dumps(record))
    with pytest.raises(OperationError, match="stale-preview-create-a-new-request-id"):
        ops.apply(preview["operation_id"], preview["preview_token"])
    assert ops.status(preview["operation_id"])["state"] == "prepared"
    assert not ops.status(preview["operation_id"]).get("backup")
    assert col.db.scalar("select count() from cards") == 1
