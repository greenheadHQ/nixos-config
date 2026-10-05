"""Difficulty policy and card metadata on actual Anki, with synthetic content."""
import copy
from datetime import datetime
import json

import pytest

from test_real_collection import HOST, add, load, runtime  # noqa: F401

difficulty = load("anki_difficulty_policy", HOST / "difficulty.py")


def logs(grades, *, days=None, kind=1, start="2026-01-01", hour=12):
    first = datetime.fromisoformat(start).timestamp()
    return [{"id": int((first + (i if days is None else days[i]) * 86400 + hour * 3600) * 1000),
             "ease": grade, "type": kind, "ivl": 1, "lastIvl": 1, "factor": 2500, "time": 1000}
            for i, grade in enumerate(grades)]


@pytest.mark.parametrize("grades,active", [([1, 1], False), ([1, 1, 3], True),
    ([2, 2, 2], True), ([1, 2, 2], True), ([1, 2, 3], False), ([3, 3, 3], False)])
def test_review_thresholds_require_three_opportunities(grades, active):
    assert bool(difficulty.assess(logs(grades), card_type=2)) == active


def test_multi_year_intervals_do_not_expire_the_evidence():
    rows = logs([1, 2, 1], days=[0, 180, 540])
    result = difficulty.assess(rows, card_type=2)
    assert result[0]["again"] == 2
    assert result[0]["first_review_at"] == rows[0]["id"]
    assert result[0]["late_days_estimate"] == 359


def test_all_review_events_count_and_again_relearning_is_separate():
    rows = logs([1, 1, 1], days=[0, 1, 2])
    repeat = dict(rows[-1], id=rows[-1]["id"] + 1000, ease=1)
    relearn = [dict(repeat, id=repeat["id"] + i * 1000, type=2) for i in range(1, 4)]
    result = difficulty.assess(rows + [repeat] + relearn, card_type=3)
    assert [s["kind"] for s in result] == ["review", "learning"]
    assert result[0]["samples"] == 4
    assert result[1]["again"] == 3


@pytest.mark.parametrize("grades,active", [([1, 1, 3, 3, 3, 2], False),
    ([1, 1, 3, 3, 3, 1], True), ([2, 2, 2, 2, 3, 2], True)])
def test_recovery_uses_only_three_new_reviews_after_activation(grades, active):
    assert bool(difficulty.assess(logs(grades), card_type=2)) == active


def test_recovery_does_not_immediately_reactivate_from_the_old_window():
    rows = logs([1, 1, 3, 3, 3, 2, 2])
    assert difficulty.assess(rows, card_type=2) == []
    # Three fresh opportunities are needed even though the old failures exist.
    assert difficulty.assess(rows + logs([2], start="2026-01-08"), card_type=2) == []
    assert difficulty.assess(rows + logs([2, 2], start="2026-01-08"), card_type=2)[0]["hard"] == 3


@pytest.mark.parametrize("grades,active", [([1, 1, 1], True), ([2, 2, 2], False),
    ([2, 2, 2, 2], True), ([1, 2, 2, 2], True), ([1, 2, 2, 3], False)])
def test_learning_repeats_use_separate_episode_thresholds(grades, active):
    rows = logs(grades, days=[0] * len(grades), kind=0)
    for i, row in enumerate(rows):
        row["id"] += i * 1000
    assert bool(difficulty.assess(rows, card_type=1)) == active
    assert difficulty.assess(rows, card_type=2) == []


def test_learning_latch_survives_day_change_but_episodes_are_separate():
    rows = logs([1, 1, 1], days=[0, 0, 0], kind=0)
    for i, row in enumerate(rows):
        row["id"] += i * 1000
    rows += logs([3], start="2026-01-02", kind=0)
    assert difficulty.assess(rows, card_type=1)[0]["again"] == 3
    rows += logs([1], start="2026-01-03") + logs([1], start="2026-01-04", kind=2)
    assert difficulty.assess(rows, card_type=3) == []


def test_preview_and_manual_rows_are_not_answers_and_interval_estimate_is_unknown_after_manual():
    rows = logs([1, 1, 1], kind=3) + logs([0], start="2026-01-05", kind=4)
    assert difficulty.assess(rows, card_type=2) == []
    rows += logs([1, 1, 3], start="2026-01-06")
    result = difficulty.assess(rows, card_type=2)[0]
    assert result["samples"] == 3
    assert rows[4]["id"] == result["first_review_at"]


def test_rollover_is_not_midnight_and_can_be_changed():
    before = int(datetime(2026, 10, 4, 3, 59).timestamp() * 1000)
    after = int(datetime(2026, 10, 4, 4, 0).timestamp() * 1000)
    assert difficulty.study_day(before) == "2026-10-03"
    assert difficulty.study_day(after) == "2026-10-04"
    assert difficulty.study_day(before, 0) == "2026-10-04"
    with pytest.raises(difficulty.DifficultyError):
        difficulty.study_day(after, 24)


def test_reassessment_preserves_other_custom_data_and_checks_anchor():
    rows = logs([1, 1, 3])
    value = difficulty.reassessed_data('{"other":42}', rows)
    assert json.loads(value)["other"] == 42
    assert len(value.encode()) <= 100
    assert difficulty.assess(rows, card_type=2, cutoff=difficulty.baseline(json.loads(value), rows)) == []
    with pytest.raises(difficulty.DifficultyError, match="anchor-changed"):
        difficulty.baseline(json.loads(value), rows[:-1])
    changed = copy.deepcopy(rows)
    changed[-1]["ease"] = 4
    with pytest.raises(difficulty.DifficultyError, match="anchor-changed"):
        difficulty.baseline(json.loads(value), changed)


def test_custom_data_byte_budget_and_unknown_versions_fail_without_loss():
    with pytest.raises(difficulty.DifficultyError, match="capacity"):
        difficulty.reassessed_data(json.dumps({"other": "가" * 25}), logs([3]))
    with pytest.raises(difficulty.DifficultyError, match="anchor"):
        difficulty.reassessed_data('{"dcb":[2,0,""]}', [])


def _managed(r, *, sibling=False):
    model = r.col.models.by_name(difficulty.MODEL_NAME)
    if model is None:
        source = "Basic (and reversed card)" if sibling else "Basic"
        model = copy.deepcopy(r.col.models.by_name(source))
        model["name"] = difficulty.MODEL_NAME
        r.col.models.update_dict(model)
        r.col.models._clear_cache()
    nid = add(r, model=difficulty.MODEL_NAME)
    return r.col.get_note(nid).card_ids()[0]


def test_actual_custom_data_reassessment_is_undoable_and_preserves_rows(runtime):
    r = runtime
    cid = _managed(r)
    card = r.col.get_card(cid)
    card.custom_data = '{"other":42}'
    r.col.update_card(card)
    before_notes = r.col.db.all("select * from notes order by id")
    before_reviews = r.col.db.all("select * from revlog order by id")
    before_card = r.col.db.first("select * from cards where id=?", cid)
    point = r.col.add_custom_undo_entry("Difficulty reassessment")
    difficulty.reassess_card(r.col, cid)
    r.col.merge_undo_entries(point)
    assert json.loads(r.col.get_card(cid).custom_data)["other"] == 42
    assert difficulty.card_payload(r.col, cid, now=1)["signals"] == []
    assert r.col.db.all("select * from notes order by id") == before_notes
    assert r.col.db.all("select * from revlog order by id") == before_reviews
    after_card = r.col.db.first("select * from cards where id=?", cid)
    assert after_card[:4] == before_card[:4]  # identity/model membership
    assert after_card[6:-1] == before_card[6:-1]  # complete scheduling, flags
    r.col.undo()
    assert r.col.get_card(cid).custom_data == '{"other":42}'


def test_actual_review_history_replay_changes_after_native_undo(runtime):
    r = runtime
    cid = _managed(r)
    # Native answers produce real Rust scheduling/logging operations.
    for _ in range(3):
        r.col.sched.reset()
        card = r.col.get_card(cid)
        card.start_timer()
        r.col.sched.answerCard(card, 1)
    payload = difficulty.card_payload(r.col, cid, now=1)
    assert payload["signals"][0]["kind"] == "learning"
    assert payload["signals"][0]["again"] == 3
    r.col.undo()
    assert difficulty.card_payload(r.col, cid, now=2)["signals"] == []


def test_script_literal_cannot_close_script():
    result = difficulty.script_payload({"value": "</script><script>alert(1)</script>&\u2028"})
    assert "<" not in result and "&" not in result
    assert json.loads(result)["value"].startswith("</script>")


def _collection_rows(col):
    return {table: col.db.all(f"select * from {table} order by id")
            for table in ("notes", "cards", "revlog")}


def _native_again(col, cid, count=3):
    for _ in range(count):
        card = col.get_card(cid)
        card.start_timer()
        col.sched.answerCard(card, 1)


def test_native_custom_data_byte_and_key_capacity_matches_policy_boundary(runtime):
    from anki.errors import InvalidInput

    r = runtime
    cid = _managed(r)
    allowed = json.dumps({"x": "v" * 92}, separators=(",", ":"))
    assert len(allowed.encode()) == 100
    card = r.col.get_card(cid)
    card.custom_data = allowed
    r.col.update_card(card)
    assert r.col.get_card(cid).custom_data == allowed
    for rejected, message in [(json.dumps({"x": "v" * 93}, separators=(",", ":")), "100 bytes"),
                              ('{"123456789":1}', "keys must be <= 8 bytes")]:
        before = _collection_rows(r.col)
        card = r.col.get_card(cid)
        card.custom_data = rejected
        with pytest.raises(InvalidInput, match=message):
            r.col.update_card(card)
        assert _collection_rows(r.col) == before
    card = r.col.get_card(cid)
    card.custom_data = '{"12345678":1}'
    r.col.update_card(card)
    assert r.col.get_card(cid).custom_data == '{"12345678":1}'


def test_operation_receipt_and_durable_request_id_do_not_repeat_reassessment(runtime):
    r = runtime
    cid = _managed(r)
    _native_again(r.col, cid)
    params = {"card_ids": [cid]}
    preview = r.ops.prepare("reassess_difficulty", params, "difficulty-reassessment-retry")
    assert preview["summary"]["scope"] == "card-difficulty-reassessment-anchor"
    assert preview["summary"]["cards"] == 1
    assert preview["confirmation_required"] is False
    assert preview["schema_required"] is False
    outcome = r.ops.apply(preview["operation_id"], preview["preview_token"])
    assert outcome["state"] == "applied"
    assert outcome["result"] == {"state": "applied", "card_ids": [cid],
                                  "scope": "card-difficulty-reassessment-anchor"}
    assert outcome["sync"]["state"] == "pending"  # Local receipt does not claim sync.
    assert r.ops.status(preview["operation_id"]) == outcome
    after = _collection_rows(r.col)
    backups = len(r.restored)
    restarted = type(r.ops)(r.ops.root, r.adapter, r.ops.restore, ttl=600,
                            bulk_limit=20, media_limit=5242880)
    assert restarted.prepare("reassess_difficulty", params, "difficulty-reassessment-retry") == outcome
    assert restarted.apply(preview["operation_id"], preview["preview_token"]) == outcome
    assert _collection_rows(r.col) == after
    assert len(r.restored) == backups
    with pytest.raises(r.error, match="request-id-payload-mismatch"):
        restarted.prepare("reassess_difficulty", {"card_ids": [cid, cid + 1]},
                          "difficulty-reassessment-retry")


def test_new_native_answer_invalidates_reassessment_preview_without_changes(runtime):
    r = runtime
    cid = _managed(r)
    _native_again(r.col, cid, count=2)
    preview = r.ops.prepare("reassess_difficulty", {"card_ids": [cid]}, "difficulty-stale-review")
    _native_again(r.col, cid, count=1)
    after_answer = _collection_rows(r.col)
    assert difficulty.card_payload(r.col, cid, now=1)["signals"]
    with pytest.raises(r.error, match="stale-preview"):
        r.ops.apply(preview["operation_id"], preview["preview_token"])
    assert _collection_rows(r.col) == after_answer
    assert r.col.get_card(cid).custom_data == ""
    assert r.ops.status(preview["operation_id"])["state"] == "prepared"
    assert not r.restored


@pytest.mark.parametrize("card_count", [20, 21])
def test_reassessment_bulk_boundary_requires_complete_preview_and_confirmation(runtime, card_count):
    r = runtime
    cids = [_managed(r) for _ in range(card_count)]
    before = _collection_rows(r.col)
    preview = r.ops.prepare("reassess_difficulty", {"card_ids": cids})
    assert preview["summary"]["cards"] == card_count
    assert preview["summary"]["card_ids"] == sorted(cids)
    assert preview["confirmation_required"] is (card_count > 20)
    assert _collection_rows(r.col) == before
    if card_count > 20:
        with pytest.raises(r.error, match="explicit-confirmation-required"):
            r.ops.apply(preview["operation_id"], preview["preview_token"])
        assert _collection_rows(r.col) == before
        assert not r.restored
    outcome = r.ops.apply(preview["operation_id"], preview["preview_token"], card_count > 20)
    assert outcome["state"] == "applied"
    assert outcome["result"]["card_ids"] == sorted(cids)
    assert len(r.restored) == (1 if card_count > 20 else 0)
    assert all(json.loads(r.col.get_card(cid).custom_data)["dcb"] == [1, 0, ""] for cid in cids)
    after = _collection_rows(r.col)
    assert after["notes"] == before["notes"]
    assert after["revlog"] == before["revlog"]
    for old, new in zip(before["cards"], after["cards"], strict=True):
        assert new[:4] == old[:4]
        assert new[6:-1] == old[6:-1]


@pytest.mark.parametrize("unsupported", ["capacity", "unmanaged"])
def test_reassessment_preflights_entire_mixed_batch_before_any_card_changes(runtime, unsupported):
    r = runtime
    first = _managed(r)
    if unsupported == "capacity":
        second = _managed(r)
        card = r.col.get_card(second)
        card.custom_data = json.dumps({"other": "x" * 65}, separators=(",", ":"))
        r.col.update_card(card)
        expected = "custom-data-capacity-exceeded"
    else:
        nid = add(r, "Basic (and reversed card)")
        second = r.col.get_note(nid).card_ids()[0]
        expected = "unmanaged-difficulty-card"
    _native_again(r.col, first)
    if unsupported == "capacity":
        _native_again(r.col, second)
    before = _collection_rows(r.col)
    journal = set(r.ops.root.glob("*.json"))
    with pytest.raises(r.error, match=expected):
        r.ops.prepare("reassess_difficulty", {"card_ids": [first, second]})
    assert _collection_rows(r.col) == before
    assert set(r.ops.root.glob("*.json")) == journal
    assert r.col.get_card(first).custom_data == ""
    assert not r.restored


def test_ordinary_content_edit_keeps_candidate_and_prior_reassessment_anchor(runtime):
    r = runtime
    cid = _managed(r)
    _native_again(r.col, cid)
    nid = r.col.get_card(cid).nid
    r.apply("reassess_difficulty", {"card_ids": [cid]})
    _native_again(r.col, cid)
    before = _collection_rows(r.col)
    anchor = r.col.get_card(cid).custom_data
    payload = difficulty.card_payload(r.col, cid, now=1)
    assert payload["signals"][0]["again"] == 3
    r.apply("update_fields", {"note_id": nid, "fields": {"Back": "synthetic corrected explanation"}})
    after = _collection_rows(r.col)
    assert r.col.get_note(nid)["Back"] == "synthetic corrected explanation"
    assert r.col.get_card(cid).custom_data == anchor
    assert difficulty.card_payload(r.col, cid, now=1) == payload
    assert after["cards"] == before["cards"]
    assert after["revlog"] == before["revlog"]


def test_operation_reassessment_preserves_sibling_flags_history_and_native_undo(runtime):
    r = runtime
    cid = _managed(r, sibling=True)
    selected = r.col.get_card(cid)
    siblings = r.col.get_note(selected.nid).card_ids()
    assert len(siblings) == 2
    sibling = next(value for value in siblings if value != cid)
    unrelated = _managed(r)
    r.col.set_user_flag_for_cards(4, [*siblings, unrelated])
    selected = r.col.get_card(cid)
    selected.custom_data = '{"other":42}'
    r.col.update_card(selected)
    r.apply("add_tags", {"note_ids": [selected.nid], "tags": ["marked", "synthetic::keep"]})
    _native_again(r.col, cid)
    before = _collection_rows(r.col)
    before_by_id = {row[0]: row for row in before["cards"]}
    assert before["revlog"]
    preview, outcome = r.apply("reassess_difficulty", {"card_ids": [cid]})
    assert preview["summary"]["cards"] == 1
    assert outcome["result"]["card_ids"] == [cid]
    assert difficulty.card_payload(r.col, cid, now=1)["signals"] == []
    assert json.loads(r.col.get_card(cid).custom_data)["other"] == 42
    after = _collection_rows(r.col)
    after_by_id = {row[0]: row for row in after["cards"]}
    assert after["notes"] == before["notes"]
    assert after["revlog"] == before["revlog"]
    assert after_by_id[sibling] == before_by_id[sibling]
    assert after_by_id[unrelated] == before_by_id[unrelated]
    assert after_by_id[cid][:4] == before_by_id[cid][:4]
    assert after_by_id[cid][6:-1] == before_by_id[cid][6:-1]
    r.col.undo()
    assert r.col.get_card(cid).custom_data == '{"other":42}'
    assert difficulty.card_payload(r.col, cid, now=1)["signals"][0]["again"] == 3
    assert _collection_rows(r.col)["notes"] == before["notes"]
    assert _collection_rows(r.col)["revlog"] == before["revlog"]
    assert all(r.col.get_card(value).user_flag() == 4 for value in [*siblings, unrelated])


def test_modern_colpkg_roundtrip_preserves_reassessment_anchor_and_native_history(runtime, tmp_path):
    from anki._backend import RustBackend
    from anki.collection import Collection
    import zipfile

    r = runtime
    cid = _managed(r)
    _native_again(r.col, cid)
    r.apply("reassess_difficulty", {"card_ids": [cid]})
    before = _collection_rows(r.col)
    expected_data = r.col.get_card(cid).custom_data
    original_rows = difficulty.review_rows(r.col, cid)
    assert difficulty.baseline(json.loads(expected_data), original_rows) == original_rows[-1]["id"]
    target = tmp_path / "difficulty-modern.colpkg"
    try:
        r.col.export_collection_package(out_path=str(target), include_media=False, legacy=False)
    finally:
        r.col.reopen(after_full_sync=False)
    with zipfile.ZipFile(target) as archive:
        assert archive.testzip() is None
        assert "collection.anki21b" in archive.namelist()
    restored = tmp_path / "restored-difficulty"
    restored.mkdir()
    backend = RustBackend()
    backend.import_collection_package(col_path=str(restored / "collection.anki2"), backup_path=str(target),
                                      media_folder=str(restored / "collection.media"),
                                      media_db=str(restored / "collection.media.db2"))
    recovered = Collection(str(restored / "collection.anki2"), backend=backend)
    try:
        assert _collection_rows(recovered) == before
        assert recovered.get_card(cid).custom_data == expected_data
        restored_rows = difficulty.review_rows(recovered, cid)
        assert restored_rows == original_rows
        assert difficulty.baseline(json.loads(expected_data), restored_rows) == original_rows[-1]["id"]
        assert difficulty.card_payload(recovered, cid, now=1)["signals"] == []
    finally:
        recovered.close()
    assert _collection_rows(r.col) == before
