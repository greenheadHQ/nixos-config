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
    def get_note(self, nid):
        if not self.db.list("select id from notes where id=?", nid): raise ValueError("not found")
        return Note(self, nid)
    def get_card(self, cid):
        rows = self.db.all("select id, nid, did, odid, ord from cards where id=?", cid)
        if not rows: raise ValueError("not found")
        return SimpleNamespace(**dict(zip(("id", "nid", "did", "odid", "ord"), rows[0])))


def adapter_fixture(tmp_path):
    col = Col()
    window = SimpleNamespace(col=col, reset=lambda: None, _anki_host_connect_version=1)
    adapter = AnkiAdapter(window, 5242880)
    ops = Operations(tmp_path, adapter, lambda _: {"mirrored": True}, ttl=600, bulk_limit=20, media_limit=5242880)
    return ops, adapter, col


def test_field_update_counts_new_cloze_cards_and_retained_old_cards(tmp_path):
    ops, adapter, col = adapter_fixture(tmp_path)
    # Old c1 card remains; c2 through c21 generate twenty additional cards.
    text = " ".join("{{c%d::new}}" % n for n in range(2, 22))
    preview = ops.prepare("update_fields", {"note_id": 1, "fields": {"Text": text}}, "cloze001")
    assert preview["summary"]["cards"] == 21 and preview["backup_required"]
    assert col.db.scalar("select count() from cards") == 1


def test_deck_delete_snapshot_includes_siblings_without_deleting_them(tmp_path):
    ops, adapter, col = adapter_fixture(tmp_path)
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
    ops, adapter, col = adapter_fixture(tmp_path)
    p = ops.prepare("delete_decks", {"deck_names": ["A"]}, "children1")
    col.deck_list.append({"id": 3, "name": "A::child", "dyn": 0, "conf": 1})
    with pytest.raises(OperationError, match="stale-preview"):
        ops.apply(p["operation_id"], p["preview_token"], True)


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
