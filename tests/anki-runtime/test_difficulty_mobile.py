"""Opt-in mobile summaries on synthetic collections, without UI or AnkiWeb.

The reducer is checked against the independent full-history policy. Native
candidate tests cover Anki's custom-data/answer/Undo transaction, not execution
of the JavaScript custom scheduler or physical AnkiMobile behavior.
"""
import copy
from itertools import product
import json
from types import SimpleNamespace

import pytest

from test_real_collection import HOST, add, load, runtime  # noqa: F401
from test_difficulty_badge import _collection_rows, _managed, _native_again

mobile = load("anki_difficulty_mobile_policy", HOST / "difficulty_mobile.py")
difficulty = mobile.difficulty
CARD_ID = 1791158400000


def rows_for(events, *, gap=1000):
    return [{"id": CARD_ID + i * gap, "type": kind, "ease": ease,
             "ivl": 1, "lastIvl": 1, "factor": 2500, "time": 1000}
            for i, (kind, ease) in enumerate(events)]


def signal_counts(state):
    """Project stored evidence, without implementing its state transitions."""
    _, _, recent, recovery, samples, again, hard = state
    result = []
    if recovery >= 0:
        grades = mobile.grades(recent)
        result.append(("review", len(grades), grades.count(1), grades.count(2)))
    if again >= 3 or hard >= 4 or again > 0 and hard > 0 and again + hard >= 4:
        result.append(("learning", samples, again, hard))
    return result


def expected_counts(rows, *, card_type, cutoff=0):
    return [(s["kind"], s["samples"], s["again"], s["hard"])
            for s in difficulty.assess(rows, card_type=card_type, cutoff=cutoff)]


@pytest.mark.parametrize("length", range(3, 9))
def test_every_review_sequence_through_eight_answers_matches_log_policy(length):
    # 87,360 histories include activation, rolling recovery, and reactivation.
    # All answers are on the same day, so a daily-first regression also fails.
    rows = rows_for([(1, 1)] * length)
    for choices in product((1, 2, 3, 4), repeat=length):
        for row, grade in zip(rows, choices, strict=True):
            row["ease"] = grade
        state = mobile.replay(CARD_ID, rows, card_type=2)
        assert signal_counts(state) == expected_counts(rows, card_type=2), choices
        assert mobile.decode(mobile.encode(state), card_id=CARD_ID) == state


@pytest.mark.parametrize("kind,card_type", [(0, 1), (2, 3)])
def test_learning_episode_accumulates_across_dates_and_clears_on_graduation(kind, card_type):
    rows = rows_for([(kind, 1), (kind, 2), (kind, 1), (kind, 2)], gap=86400000)
    state = mobile.replay(CARD_ID, rows, card_type=card_type)
    assert signal_counts(state) == [("learning", 4, 2, 2)]
    assert signal_counts(state) == expected_counts(rows, card_type=card_type)
    assert mobile.replay(CARD_ID, rows, card_type=2)[4:] == [0, 0, 0]
    assert mobile.advance(state, kind, 3, graduated=True)[4:] == [0, 0, 0]


@pytest.mark.parametrize("boundary,ease", [(1, 1), (4, 0), (5, 0)])
def test_review_and_manual_boundaries_start_a_fresh_learning_episode(boundary, ease):
    rows = rows_for([(0, 1)] * 3 + [(boundary, ease), (2, 1), (2, 1)])
    state = mobile.replay(CARD_ID, rows, card_type=3)
    assert state[4:] == [2, 2, 0]
    assert signal_counts(state) == expected_counts(rows, card_type=3) == []


def test_learning_again_does_not_advance_review_or_its_recovery_window():
    events = [(1, 1), (2, 1), (2, 1), (1, 1), (1, 3)]
    events += [(2, 1)] * 3 + [(3, 4), (1, 3), (2, 4), (1, 3)]
    state = mobile.replay(CARD_ID, rows_for(events), card_type=3)
    assert mobile.grades(state[3]) == [3, 3]
    events.append((1, 2))
    rows = rows_for(events)
    state = mobile.replay(CARD_ID, rows, card_type=2)
    assert signal_counts(state) == expected_counts(rows, card_type=2) == []


def test_replay_sorts_and_reassessment_counts_new_answers_on_the_same_day():
    rows = rows_for([(1, 1), (1, 1), (1, 3), (1, 2), (1, 2), (1, 2)])
    cutoff = rows[2]["id"]
    state = mobile.replay(CARD_ID, list(reversed(rows)), card_type=2, cutoff=cutoff)
    assert signal_counts(state) == [("review", 3, 0, 3)]
    assert signal_counts(state) == expected_counts(rows, card_type=2, cutoff=cutoff)
    with pytest.raises(difficulty.DifficultyError, match="duplicate-review-id"):
        mobile.replay(CARD_ID, rows + [rows[-1]], card_type=2)


def test_advance_does_not_mutate_its_input_or_mix_candidate_branches():
    initial = mobile.replay(CARD_ID, rows_for([(0, 1), (0, 2)]), card_type=1)
    before = list(initial)
    again = mobile.advance(initial, 0, 1)
    hard = mobile.advance(initial, 0, 2)
    assert initial == before
    assert again[4:] == [3, 2, 1]
    assert hard[4:] == [3, 1, 2]
    assert mobile.advance(initial, 3, 1) == initial
    assert mobile.advance(initial, 0, 0) == initial


@pytest.mark.parametrize("value", [None, [], "", "3.1.0.-.0.0.0",
    "2.01.0.-.0.0.0", "2.0.0.-.0.0.0", "2.1.5.-.0.0.0",
    "2.1.0.5.0.0.0", "2.1.0.-.1.2.0", "2.1.0.-.1.1.1",
    "2.1.0.-.0.0.0.extra", "2.1.0.-.0.0.0\n"])
def test_decode_rejects_unknown_noncanonical_or_inconsistent_data(value):
    with pytest.raises(difficulty.DifficultyError, match="invalid-mobile-summary"):
        mobile.decode(value)


@pytest.mark.parametrize("state", [
    [2, mobile.MAX_ID + 1, 0, -1, 0, 0, 0],
    [2, CARD_ID, 3125, -1, 0, 0, 0],
    [2, CARD_ID, 1, 125, 0, 0, 0],
    [2, CARD_ID, 0, -1, mobile.MAX_COUNT + 1, 0, 0],
])
def test_decode_checks_numeric_bounds(state):
    with pytest.raises(difficulty.DifficultyError, match="invalid-mobile-summary"):
        mobile.decode(mobile.encode(state))


def test_clone_marker_and_counter_overflow_are_not_silently_reset():
    value = mobile.encode(mobile.empty(CARD_ID))
    with pytest.raises(difficulty.DifficultyError, match="invalid-mobile-summary"):
        mobile.decode(value, card_id=CARD_ID + 1)
    full = [2, CARD_ID, 0, -1, mobile.MAX_COUNT, 1, 2]
    with pytest.raises(difficulty.DifficultyError, match="mobile-summary-capacity-exceeded"):
        mobile.advance(full, 0, 3)
    assert full[4] == mobile.MAX_COUNT


def test_capacity_reserves_counter_growth_future_anchor_and_preserves_other_keys():
    data = {"x": 1}
    original = copy.deepcopy(data)
    value = mobile.with_summary(data, mobile.empty(CARD_ID))
    assert json.loads(value)["x"] == 1 and data == original
    worst_valid = [2, CARD_ID, 3124, 124, mobile.MAX_COUNT, mobile.MAX_COUNT, 0]
    grown = mobile.with_summary(json.loads(value), worst_valid)
    future = difficulty.reassessed_data(grown, rows_for([(0, 1)]))
    assert len(future.encode("utf-8")) <= 100
    assert json.loads(future)["x"] == 1
    assert mobile.decode(json.loads(grown)[mobile.KEY]) == worst_valid
    # This fits today but cannot accommodate future counter and anchor growth.
    crowded = {"x": "a" * 20}
    current = {**crowded, mobile.KEY: mobile.encode(mobile.empty(CARD_ID))}
    assert len(json.dumps(current).encode("utf-8")) < 100
    with pytest.raises(difficulty.DifficultyError, match="custom-data-capacity-exceeded"):
        mobile.with_summary(crowded, mobile.empty(CARD_ID))


@pytest.mark.parametrize("data", [{"123456789": 0}, {"x": "가" * 12}])
def test_capacity_uses_utf8_bytes_and_native_key_limit(data):
    with pytest.raises(difficulty.DifficultyError, match="custom-data-capacity-exceeded"):
        mobile.with_summary(data, mobile.empty(CARD_ID))


def test_card_data_reassessment_resets_summary_preserves_anchor_and_other_data():
    rows = rows_for([(1, 1), (1, 1), (1, 3)])
    card = SimpleNamespace(id=CARD_ID, type=2, custom_data='{"x":1}')
    seeded = mobile.card_data(card, rows)
    card.custom_data = seeded
    changed = json.loads(mobile.card_data(card, rows, reassess=True))
    assert changed["x"] == 1
    assert difficulty.baseline(changed, rows) == rows[-1]["id"]
    assert mobile.decode(changed[mobile.KEY], card_id=CARD_ID) == mobile.empty(CARD_ID)
    card.custom_data = json.dumps(changed)
    with pytest.raises(difficulty.DifficultyError, match="reassessment-anchor-changed"):
        mobile.card_data(card, rows[:-1])


def test_native_install_is_read_only_until_apply_and_undo_groups_config_and_cards(runtime):
    r = runtime
    cid = _managed(r)
    unrelated = r.col.get_note(add(r, model="Basic (and reversed card)")).card_ids()[0]
    _native_again(r.col, cid)
    before = _collection_rows(r.col)
    config_before = r.col.get_config(mobile.CONFIG_KEY, None)
    prepared = mobile.plan(r.col, enabled=True)
    assert prepared["card_ids"] == [cid]
    assert _collection_rows(r.col) == before
    assert r.col.get_config(mobile.CONFIG_KEY, None) == config_before
    mobile.apply(r.col, prepared)
    assert r.col.get_config(mobile.CONFIG_KEY) == mobile.script()
    stored = json.loads(r.col.get_card(cid).custom_data)
    assert signal_counts(mobile.decode(stored[mobile.KEY], card_id=cid)) == [("learning", 3, 3, 0)]
    after = _collection_rows(r.col)
    assert after["notes"] == before["notes"] and after["revlog"] == before["revlog"]
    for old, new in zip(before["cards"], after["cards"], strict=True):
        assert old[:4] == new[:4] and old[6:-1] == new[6:-1]
        if old[0] == unrelated:
            assert old == new
    assert mobile.plan(r.col, enabled=True)["updates"] == []
    r.col.undo()
    assert r.col.get_card(cid).custom_data == ""
    assert r.col.get_config(mobile.CONFIG_KEY, None) == config_before
    assert r.col.db.all("select * from revlog order by id") == before["revlog"]


@pytest.mark.parametrize("enabled", [True, False])
def test_native_foreign_custom_scheduler_is_refused_without_mutation(runtime, enabled):
    r = runtime
    _managed(r)
    foreign = "customData.easy.keep = 1;"
    r.col.set_config(mobile.CONFIG_KEY, foreign)
    before = _collection_rows(r.col)
    with pytest.raises(difficulty.DifficultyError, match="custom-scheduling-already-configured"):
        mobile.plan(r.col, enabled=enabled)
    assert _collection_rows(r.col) == before
    assert r.col.get_config(mobile.CONFIG_KEY) == foreign


@pytest.mark.parametrize("problem", ["capacity", "malformed", "clone", "anchor", "unsafe-integer"])
def test_native_plan_preflights_the_whole_batch_before_any_changes(runtime, problem):
    r = runtime
    first, second = _managed(r), _managed(r)
    card = r.col.get_card(second)
    if problem == "capacity":
        card.custom_data = '{"x":"' + "a" * 20 + '"}'
        error = "custom-data-capacity-exceeded"
    elif problem == "malformed":
        card.custom_data = '{"dce":"broken"}'
        error = "invalid-mobile-summary"
    elif problem == "clone":
        card.custom_data = json.dumps({mobile.KEY: mobile.encode(mobile.empty(first))})
        error = "invalid-mobile-summary"
    elif problem == "unsafe-integer":
        card.custom_data = json.dumps({"x": [mobile.MAX_ID + 1]})
        error = "custom-data-integer-not-javascript-safe"
    else:
        card.custom_data = '{"dcb":[1,123,"000000000000"]}'
        error = "reassessment-anchor-changed"
    r.col.update_card(card)
    before = _collection_rows(r.col)
    with pytest.raises(difficulty.DifficultyError, match=error):
        mobile.plan(r.col, enabled=True)
    assert _collection_rows(r.col) == before
    assert r.col.get_card(first).custom_data == ""


def test_native_disable_preserves_summaries_and_undo_restores_owned_script(runtime):
    r = runtime
    cid = _managed(r)
    mobile.apply(r.col, mobile.plan(r.col, enabled=True))
    before = _collection_rows(r.col)
    prepared = mobile.plan(r.col, enabled=False)
    assert prepared["updates"] == []
    mobile.apply(r.col, prepared)
    assert r.col.get_config(mobile.CONFIG_KEY) == ""
    assert _collection_rows(r.col) == before
    r.col.undo()
    assert r.col.get_config(mobile.CONFIG_KEY) == mobile.script()
    assert r.col.get_card(cid).custom_data != ""


def test_native_candidate_summary_is_saved_with_selected_answer_and_undone_with_it(runtime):
    from anki.scheduler_pb2 import CardAnswer

    r = runtime
    cid = _managed(r)
    mobile.apply(r.col, mobile.plan(r.col, enabled=True))
    for _ in range(3):
        card = r.col.get_card(cid)
        before = card.custom_data
        data = json.loads(before)
        state = mobile.decode(data[mobile.KEY], card_id=cid)
        states = r.col._backend.get_scheduling_states(cid)
        states.current.custom_data = before
        kind = 0 if card.type in (0, 1) else 2
        for grade, name in enumerate(("again", "hard", "good", "easy"), 1):
            candidate = getattr(states, name)
            graduated = candidate.normal.WhichOneof("kind") == "review"
            candidate.custom_data = mobile.with_summary(
                data, mobile.advance(state, kind, grade, graduated=graduated))
        # Constructing all branches has no persistent effect.
        assert r.col.get_card(cid).custom_data == before
        card.start_timer()
        r.col.sched.answer_card(r.col.sched.build_answer(
            card=card, states=states, rating=CardAnswer.AGAIN))
        assert r.col.get_card(cid).custom_data == states.again.custom_data
    rows = difficulty.review_rows(r.col, cid)
    assert len(rows) == 3 and all(row["ease"] == 1 for row in rows)
    stored = mobile.decode(json.loads(r.col.get_card(cid).custom_data)[mobile.KEY], card_id=cid)
    assert signal_counts(stored) == expected_counts(rows, card_type=r.col.get_card(cid).type)
    assert signal_counts(stored) == [("learning", 3, 3, 0)]
    r.col.undo()
    assert r.col.get_card(cid).custom_data == before
    restored_rows = difficulty.review_rows(r.col, cid)
    assert len(restored_rows) == 2
    restored = mobile.decode(json.loads(before)[mobile.KEY], card_id=cid)
    assert signal_counts(restored) == expected_counts(restored_rows, card_type=r.col.get_card(cid).type) == []


def test_native_unseeded_card_and_stale_summary_wait_for_explicit_reconcile(runtime):
    r = runtime
    first = _managed(r)
    mobile.apply(r.col, mobile.plan(r.col, enabled=True))
    old_summary = r.col.get_card(first).custom_data
    # The legacy native answer API intentionally does not run custom JavaScript.
    _native_again(r.col, first)
    second = _managed(r)
    before = _collection_rows(r.col)
    assert r.col.get_card(first).custom_data == old_summary
    assert r.col.get_card(second).custom_data == ""
    assert difficulty.card_payload(r.col, first, now=1)["signals"][0]["again"] == 3
    difficulty.card_payload(r.col, second, now=1)
    assert _collection_rows(r.col) == before
    prepared = mobile.plan(r.col, enabled=True)
    assert {cid for cid, _ in prepared["updates"]} == {first, second}
    assert _collection_rows(r.col) == before
    mobile.apply(r.col, prepared)
    first_state = mobile.decode(json.loads(r.col.get_card(first).custom_data)[mobile.KEY])
    assert signal_counts(first_state) == [("learning", 3, 3, 0)]
    assert mobile.decode(json.loads(r.col.get_card(second).custom_data)[mobile.KEY]) == mobile.empty(second)
    assert r.col.db.all("select * from revlog order by id") == before["revlog"]


def test_native_reassessment_resets_mobile_and_desktop_evidence_in_one_undo(runtime):
    r = runtime
    cid = _managed(r)
    _native_again(r.col, cid)
    mobile.apply(r.col, mobile.plan(r.col, enabled=True))
    before = _collection_rows(r.col)
    previous_data = r.col.get_card(cid).custom_data
    _, outcome = r.apply("reassess_difficulty", {"card_ids": [cid]})
    assert outcome["state"] == "applied"
    changed = json.loads(r.col.get_card(cid).custom_data)
    assert mobile.decode(changed[mobile.KEY]) == mobile.empty(cid)
    assert difficulty.card_payload(r.col, cid, now=1)["signals"] == []
    assert r.col.db.all("select * from revlog order by id") == before["revlog"]
    r.col.undo()
    assert r.col.get_card(cid).custom_data == previous_data
    assert difficulty.card_payload(r.col, cid, now=1)["signals"][0]["again"] == 3


def operator_preview(r, *, enabled=True, request_id="mobile-operator-01"):
    return r.ops.prepare("configure_difficulty_mobile", {"enabled": enabled, "devices_ready": True},
                         request_id, operator_authorized=True)


@pytest.mark.parametrize("enabled,ready,error", [
    (True, False, "difficulty-mobile-devices-must-be-ready"),
    (True, 1, "invalid-boolean"), (1, True, "invalid-boolean"),
])
def test_native_operator_requires_explicit_device_readiness_and_boolean_inputs(runtime, enabled, ready, error):
    r = runtime
    _managed(r)
    before = _collection_rows(r.col)
    with pytest.raises(r.error, match=error):
        r.ops.prepare("configure_difficulty_mobile", {"enabled": enabled, "devices_ready": ready},
                      operator_authorized=True)
    assert _collection_rows(r.col) == before
    assert not r.restored


def test_native_operator_route_and_apply_cannot_be_reached_with_regular_authority(runtime):
    r = runtime
    _managed(r)
    before = _collection_rows(r.col)
    params = {"enabled": True, "devices_ready": True}
    with pytest.raises(r.error, match="root-operator-command-required"):
        r.ops.prepare("configure_difficulty_mobile", params)
    preview = operator_preview(r)
    with pytest.raises(r.error, match="root-operator-command-required"):
        r.ops.apply(preview["operation_id"], preview["preview_token"], True, schema_authorized=True)
    with pytest.raises(r.error, match="explicit-confirmation-required"):
        r.ops.apply(preview["operation_id"], preview["preview_token"], False, operator_authorized=True)
    for path in ("/difficulty/mobile/prepare", "/difficulty/mobile/apply"):
        for role in (None, "read", "operation", "maintenance"):
            assert r.helper.ACCESS.allowed("POST", path, role) is False
        assert r.helper.ACCESS.allowed("POST", path, "schema") is True
    assert _collection_rows(r.col) == before
    assert not r.restored


def test_native_operator_backup_receipt_idempotency_and_undo(runtime, monkeypatch):
    r = runtime
    cid = _managed(r)
    _native_again(r.col, cid)
    before = _collection_rows(r.col)
    config_before = r.col.get_config(mobile.CONFIG_KEY, None)
    preview = operator_preview(r)
    assert preview["backup_required"] is True and preview["confirmation_required"] is True
    assert preview["sync"]["state"] == preview["notification"]["state"] == "disabled"
    resets = []
    reset = r.window.reset
    monkeypatch.setattr(r.window, "reset", lambda: (resets.append(True), reset()))
    result = r.ops.apply(preview["operation_id"], preview["preview_token"], True, operator_authorized=True)
    assert result["state"] == "applied"
    assert result["result"]["sync_required"] is True and len(r.restored) == 1 and resets
    after = _collection_rows(r.col)
    assert after["notes"] == before["notes"] and after["revlog"] == before["revlog"]
    assert r.ops.apply(preview["operation_id"], preview["preview_token"], True,
                       operator_authorized=True) == result
    assert len(r.restored) == 1 and _collection_rows(r.col) == after
    with pytest.raises(r.error, match="operator-local-action-has-no-delivery"):
        r.ops.record_delivery(preview["operation_id"], "sync", {"state": "synced"})
    r.col.undo()
    assert r.col.get_card(cid).custom_data == ""
    assert r.col.get_config(mobile.CONFIG_KEY, None) == config_before


@pytest.mark.parametrize("change", ["review", "membership", "script"])
def test_native_operator_rejects_stale_snapshot_before_backup_or_mutation(runtime, change):
    r = runtime
    cid = _managed(r)
    preview = operator_preview(r)
    if change == "review":
        _native_again(r.col, cid, count=1)
    elif change == "membership":
        _managed(r)
    else:
        r.col.set_config(mobile.CONFIG_KEY, "void 0;")
    before = _collection_rows(r.col)
    config_before = r.col.get_config(mobile.CONFIG_KEY, None)
    with pytest.raises(r.error, match="stale-preview"):
        r.ops.apply(preview["operation_id"], preview["preview_token"], True, operator_authorized=True)
    assert _collection_rows(r.col) == before
    assert r.col.get_config(mobile.CONFIG_KEY, None) == config_before
    assert not r.restored


def test_native_operator_refuses_an_open_reviewer_at_prepare_and_apply(runtime):
    r = runtime
    _managed(r)
    r.window.state = "review"
    with pytest.raises(r.error, match="difficulty-mobile-reviewer-must-be-closed"):
        operator_preview(r)
    r.window.state = "deckBrowser"
    preview = operator_preview(r)
    r.window.state = "review"
    before = _collection_rows(r.col)
    with pytest.raises(r.error, match="difficulty-mobile-reviewer-must-be-closed"):
        r.ops.apply(preview["operation_id"], preview["preview_token"], True, operator_authorized=True)
    assert _collection_rows(r.col) == before and not r.restored


def test_native_mobile_route_rejects_another_actions_receipt(runtime, monkeypatch):
    r = runtime
    cid = _managed(r)
    preview = r.ops.prepare("reassess_difficulty", {"card_ids": [cid]})
    monkeypatch.setattr(r.helper, "_ops", lambda: r.ops)
    before = _collection_rows(r.col)
    with pytest.raises(r.error, match="invalid-difficulty-mobile-request"):
        r.helper._difficulty_mobile_request("/difficulty/mobile/apply", {
            "operation_id": preview["operation_id"], "preview_token": preview["preview_token"], "confirm": True})
    assert _collection_rows(r.col) == before and not r.restored


def test_native_early_filtered_lapse_starts_learning_after_the_actual_graduation(runtime):
    from anki.scheduler_pb2 import CardAnswer

    r = runtime
    cid = _managed(r)
    _native_again(r.col, cid)
    assert difficulty.card_payload(r.col, cid, now=1)["signals"][0]["again"] == 3

    card = r.col.get_card(cid)
    states = r.col._backend.get_scheduling_states(cid)
    assert states.easy.normal.WhichOneof("kind") == "review"
    card.start_timer()
    r.col.sched.answer_card(r.col.sched.build_answer(card=card, states=states, rating=CardAnswer.EASY))
    assert r.col.get_card(cid).type == 2
    assert difficulty.card_payload(r.col, cid, now=1)["signals"] == []

    did = r.col.decks.new_filtered("Synthetic early Review")
    deck = r.col.decks.get(did)
    deck["terms"] = [[f"cid:{cid}", 100, 0]]
    deck["resched"] = True
    r.col.decks.save(deck)
    r.col.sched.rebuild_filtered_deck(did)
    card = r.col.get_card(cid)
    states = r.col._backend.get_scheduling_states(cid)
    current = states.current.filtered.rescheduling.original_state
    assert current.WhichOneof("kind") == "review"
    assert current.review.elapsed_days < current.review.scheduled_days
    card.start_timer()
    r.col.sched.answer_card(r.col.sched.build_answer(card=card, states=states, rating=CardAnswer.AGAIN))
    rows = difficulty.review_rows(r.col, cid)
    assert rows[-1]["type"] == 3 and rows[-1]["lastIvl"] > 0 and rows[-1]["factor"] > 0
    assert r.col.get_card(cid).type == 3
    assert mobile.replay(cid, rows, card_type=3)[4:] == [0, 0, 0]
    assert difficulty.card_payload(r.col, cid, now=1)["signals"] == []

    _native_again(r.col, cid, count=1)
    rows = difficulty.review_rows(r.col, cid)
    assert rows[-1]["type"] == 2
    assert mobile.replay(cid, rows, card_type=3)[4:] == [1, 1, 0]
    assert difficulty.card_payload(r.col, cid, now=1)["signals"] == []


def test_native_preview_across_rollover_does_not_end_the_learning_episode(runtime):
    from anki.scheduler_pb2 import CardAnswer

    r = runtime
    cid = _managed(r)
    _native_again(r.col, cid)
    before = difficulty.review_rows(r.col, cid)
    original_state = mobile.replay(cid, before, card_type=1)
    original_signals = difficulty.assess(before, card_type=1)
    assert signal_counts(original_state) == [("learning", 3, 3, 0)]

    did = r.col.decks.new_filtered("Synthetic day preview")
    deck = r.col.decks.get(did)
    deck["terms"] = [[f"cid:{cid}", 100, 0]]
    deck["resched"] = False
    deck["previewAgainSecs"] = 86400
    r.col.decks.save(deck)
    r.col.sched.rebuild_filtered_deck(did)
    card = r.col.get_card(cid)
    states = r.col._backend.get_scheduling_states(cid)
    assert states.current.filtered.WhichOneof("kind") == "preview"
    assert states.current.filtered.preview.scheduled_secs == 86400
    card.start_timer()
    r.col.sched.answer_card(r.col.sched.build_answer(card=card, states=states, rating=CardAnswer.EASY))
    rows = difficulty.review_rows(r.col, cid)
    assert rows[-1]["type"] == 3 and rows[-1]["lastIvl"] > 0 and rows[-1]["factor"] == 0
    assert r.col.get_card(cid).type == 1
    assert mobile.replay(cid, rows, card_type=1) == original_state
    assert difficulty.assess(rows, card_type=1) == original_signals


@pytest.mark.parametrize("value", [mobile.MAX_ID + 1, -(mobile.MAX_ID + 1)])
def test_foreign_nested_integer_cannot_be_silently_rounded_by_mobile_javascript(value):
    data = {"x": [{"y": value}]}
    original = copy.deepcopy(data)
    with pytest.raises(difficulty.DifficultyError, match="custom-data-integer-not-javascript-safe"):
        mobile.with_summary(data, mobile.empty(CARD_ID))
    assert data == original


@pytest.mark.parametrize("value, safe", [
    (1.5, True), (9007199254740991.0, True), (1e20, False),
    (9007199254740992.0, False), (float("inf"), False), (float("nan"), False),
])
def test_foreign_number_safety_matches_javascript(value, safe):
    assert mobile.javascript_safe({"x": [value]}) is safe
