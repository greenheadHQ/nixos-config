from anki_mcp.shaping import card_view, note_view, page, truncate
import pytest


def test_truncate_marks_and_keeps_short_values():
    assert truncate("abc", 10) == "abc"
    assert truncate("abc", 0) == "abc"
    out = truncate("x" * 50, 10)
    assert out.startswith("x" * 10) and "truncated 10/50" in out


def test_page_clamps_and_reports_next_offset():
    items = list(range(25))
    chunk, meta = page(items, limit=10, offset=0, page_max=100)
    assert chunk == list(range(10)) and meta["next_offset"] == 10 and meta["total"] == 25
    chunk, meta = page(items, limit=10, offset=20, page_max=100)
    assert chunk == [20, 21, 22, 23, 24] and meta["next_offset"] is None
    chunk, meta = page(items, limit=500, offset=-5, page_max=100)
    assert meta["limit"] == 100 and meta["offset"] == 0 and len(chunk) == 25


def test_note_view_orders_fields_and_truncates():
    note = {
        "noteId": 1,
        "modelName": "Basic",
        "tags": ["a"],
        "cards": [11],
        "fields": {"Back": {"value": "b" * 20, "order": 1}, "Front": {"value": "f", "order": 0}},
    }
    view = note_view(note, 5, "https://anki.example")
    assert list(view["fields"]) == ["Front", "Back"]
    assert view["fields"]["Back"].startswith("bbbbb…")


def test_card_view_drops_css_and_keeps_schedule():
    card = {"cardId": 5, "note": 1, "deckName": "D", "css": ".x{}", "question": "q" * 9, "answer": "a", "interval": 3}
    view = card_view(card, 4, "https://anki.example")
    assert "css" not in view and view["interval"] == 3 and view["question"].startswith("qqqq…")


@pytest.mark.parametrize("flag", range(8))
def test_card_view_reports_user_flag_without_reserved_bits(flag):
    assert card_view({"flags": 0b101000 | flag}, 10, "https://anki.example")["flag"] == flag


def test_card_view_missing_flag_is_unknown_not_unflagged():
    assert card_view({}, 10, "https://anki.example")["flag"] is None


def test_note_links_preserve_original_ids_and_include_every_sibling():
    ids = [10, 9007199254740993, 9223372036854775807, 0, -1, True, "11", 1.5, None]
    view = note_view({"noteId": 123, "cards": ids}, 10, "https://anki.example")
    assert view["noteId"] == 123 and view["cards"] == ids
    assert view["cardLinks"] == [
        {"cardId": str(cid), "cardUrl": f"https://anki.example/c/{cid}"} for cid in ids[:3]
    ]
    assert note_view({}, 10, "https://anki.example")["cardLinks"] == []


@pytest.mark.parametrize("cid", [0, -1, True, False, "10", 1.0, None, 9223372036854775808])
def test_card_links_fail_closed_without_changing_original_ids(cid):
    view = card_view({"cardId": cid}, 10, "https://anki.example")
    assert view["cardId"] is cid
    assert view["cardUrl"] is None


def test_card_link_preserves_id_above_javascript_integer_precision():
    cid = 9007199254740993
    view = card_view({"cardId": cid, "note": 123}, 10, "https://anki.example")
    assert type(view["cardId"]) is int and view["cardId"] == cid
    assert view["noteId"] == 123
    assert view["cardUrl"] == "https://anki.example/c/9007199254740993"
