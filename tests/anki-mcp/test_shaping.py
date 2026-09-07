from anki_mcp.shaping import card_view, note_view, page, truncate


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
    view = note_view(note, 5)
    assert list(view["fields"]) == ["Front", "Back"]
    assert view["fields"]["Back"].startswith("bbbbb…")


def test_card_view_drops_css_and_keeps_schedule():
    card = {"cardId": 5, "note": 1, "deckName": "D", "css": ".x{}", "question": "q" * 9, "answer": "a", "interval": 3}
    view = card_view(card, 4)
    assert "css" not in view and view["interval"] == 3 and view["question"].startswith("qqqq…")
