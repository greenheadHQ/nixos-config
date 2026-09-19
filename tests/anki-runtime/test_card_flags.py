"""Card flag mutations against generated Anki collections, without sync or HTTP.

Reuse the real backend/AnkiConnect fixture so the tests exercise the same
prepare/apply journal and restore-point path as the existing runtime checks.
"""

import pytest

from test_real_collection import add, runtime  # noqa: F401


def rows(r, table):
    # The table names below are test constants, never external input.
    columns = [row[1] for row in r.col.db.all(f'pragma table_info({table})')]
    return {row[0]: dict(zip(columns, row, strict=True))
            for row in r.col.db.all(f'select * from {table} order by id')}


def collection_rows(r):
    return {table: rows(r, table) for table in ('cards', 'notes', 'revlog')}


def assert_only_flags_changed(before, after, selected):
    assert after['notes'] == before['notes']
    assert after['revlog'] == before['revlog']
    assert after['cards'].keys() == before['cards'].keys()
    for cid, previous in before['cards'].items():
        current = after['cards'][cid]
        if cid in selected:
            allowed = {'flags', 'mod', 'usn'}
            assert {key: value for key, value in current.items() if key not in allowed} == {
                key: value for key, value in previous.items() if key not in allowed}
        else:
            assert current == previous


def test_all_flag_colors_round_trip_preserves_siblings_notes_and_review_history(runtime):
    r = runtime
    nid = add(r, 'Basic (and reversed card)', {'Front': 'front', 'Back': 'back'})
    selected, sibling = r.col.get_note(nid).card_ids()
    unrelated = add(r, fields={'Front': 'unrelated', 'Back': 'keep'})
    unrelated_cid = r.col.get_note(unrelated).card_ids()[0]
    r.apply('set_due_date', {'card_ids': [selected, sibling, unrelated_cid], 'days': '2'})
    r.col.set_user_flag_for_cards(3, [sibling])
    before = collection_rows(r)
    assert len(before['revlog']) >= 3
    original_scm = r.col.db.scalar('select scm from col')
    restore_count = len(r.restored)

    for flag in [*range(1, 8), 0]:
        preview, outcome = r.apply('set_card_flags', {'card_ids': [selected], 'flag': flag})
        assert preview['summary']['cards'] == 1
        assert preview['confirmation_required'] is False
        assert preview['backup_required'] is False
        assert preview['schema_required'] is False
        assert outcome['result']['card_ids'] == [selected]
        assert outcome['result']['flag'] == flag
        assert r.col.get_card(selected).user_flag() == flag
        assert r.ac.cardsInfo(cards=[selected])[0]['flags'] & 7 == flag
        assert r.col.find_cards(f'cid:{selected} flag:{flag}') == [selected]
        assert r.col.get_card(sibling).user_flag() == 3
        assert_only_flags_changed(before, collection_rows(r), {selected})
        assert r.col.db.scalar('select scm from col') == original_scm

    assert len(r.restored) == restore_count


def test_flag_changes_preserve_reserved_upper_bits(runtime):
    r = runtime
    cid = r.col.get_note(add(r)).card_ids()[0]
    # Seed reserved bits in the generated fixture; only bits 0..2 are the flag.
    upper_bits = 0b10101000
    r.col.db.execute('update cards set flags=? where id=?', upper_bits, cid)
    before = collection_rows(r)
    for flag in [*range(1, 8), 0]:
        r.apply('set_card_flags', {'card_ids': [cid], 'flag': flag})
        assert r.col.get_card(cid).flags == upper_bits | flag
        assert r.col.get_card(cid).user_flag() == flag
        assert_only_flags_changed(before, collection_rows(r), {cid})


@pytest.mark.parametrize('flag', [-1, 8, True, False, 1.0, '1', None, [], {}])
def test_invalid_flag_rejected_before_mutation(runtime, flag):
    r = runtime
    cid = r.col.get_note(add(r)).card_ids()[0]
    before = collection_rows(r)
    journal_count = len(list((r.root / 'journal').glob('*.json')))
    with pytest.raises(r.error):
        r.ops.prepare('set_card_flags', {'card_ids': [cid], 'flag': flag})
    assert collection_rows(r) == before
    assert len(list((r.root / 'journal').glob('*.json'))) == journal_count
    assert not r.restored


@pytest.mark.parametrize('card_ids', [[], [0], [-1], [True], ['1']])
def test_invalid_card_ids_rejected_before_mutation(runtime, card_ids):
    r = runtime
    add(r)
    before = collection_rows(r)
    with pytest.raises(r.error, match='ids-must-be-a-nonempty-list-of-positive-integers'):
        r.ops.prepare('set_card_flags', {'card_ids': card_ids, 'flag': 4})
    assert collection_rows(r) == before
    assert not r.restored


def test_missing_card_rejects_entire_request(runtime):
    r = runtime
    cid = r.col.get_note(add(r)).card_ids()[0]
    before = collection_rows(r)
    with pytest.raises(r.error, match='card-not-found'):
        r.ops.prepare('set_card_flags', {'card_ids': [cid, cid + 100000], 'flag': 4})
    assert collection_rows(r) == before
    assert not r.restored


@pytest.mark.parametrize('count', [20, 21])
def test_bulk_boundary_requires_preview_and_backup_only_above_twenty(runtime, monkeypatch, count):
    r = runtime
    card_ids = sorted(r.col.get_note(add(r, fields={'Front': f'item {i}', 'Back': 'back'})).card_ids()[0]
                      for i in range(count))
    before = collection_rows(r)
    # Repeated IDs are one affected card, not extra work or extra impact.
    params = {'card_ids': [*reversed(card_ids), card_ids[0]], 'flag': 4}
    request_id = f'flag-bulk-{count}'
    preview = r.ops.prepare('set_card_flags', params, request_id)
    assert preview['summary']['cards'] == count
    assert preview['summary']['notes'] == count
    assert preview['confirmation_required'] is (count > 20)
    assert preview['backup_required'] is (count > 20)
    assert preview['schema_required'] is False
    assert collection_rows(r) == before
    assert not r.restored
    if count > 20:
        with pytest.raises(r.error, match='explicit-confirmation-required'):
            r.ops.apply(preview['operation_id'], preview['preview_token'])
        assert collection_rows(r) == before
        assert not r.restored

    applications = []
    actual_apply = r.adapter.apply

    def apply_once(spec):
        applications.append(spec)
        return actual_apply(spec)

    monkeypatch.setattr(r.adapter, 'apply', apply_once)
    outcome = r.ops.apply(preview['operation_id'], preview['preview_token'], count > 20)
    assert outcome['state'] == 'applied', outcome
    assert outcome['result']['card_ids'] == card_ids
    assert outcome['result']['flag'] == 4
    assert len(r.restored) == int(count > 20)
    assert all(r.col.get_card(cid).user_flag() == 4 for cid in card_ids)
    after = collection_rows(r)
    assert_only_flags_changed(before, after, set(card_ids))

    # Both duplicate prepare and duplicate apply return the durable receipt.
    assert r.ops.prepare('set_card_flags', params, request_id) == outcome
    assert r.ops.apply(preview['operation_id'], preview['preview_token'], True) == outcome
    assert len(applications) == 1
    assert len(r.restored) == int(count > 20)
    assert collection_rows(r) == after


def test_changed_flag_invalidates_preview(runtime):
    r = runtime
    cid = r.col.get_note(add(r)).card_ids()[0]
    preview = r.ops.prepare('set_card_flags', {'card_ids': [cid], 'flag': 4})
    # A separate client changes the same card after the preview.
    r.col.set_user_flag_for_cards(2, [cid])
    before = collection_rows(r)
    with pytest.raises(r.error, match='stale-preview-create-a-new-request-id'):
        r.ops.apply(preview['operation_id'], preview['preview_token'])
    assert r.col.get_card(cid).user_flag() == 2
    assert collection_rows(r) == before
    assert not r.restored


def test_setting_existing_flag_preserves_card_modification_time(runtime):
    r = runtime
    cid = r.col.get_note(add(r)).card_ids()[0]
    r.col.set_user_flag_for_cards(4, [cid])
    # Make an unnecessary update observable without sleeping for an epoch tick.
    r.col.db.execute('update cards set mod=?, usn=? where id=?', 946684800, 17, cid)
    before = collection_rows(r)
    r.apply('set_card_flags', {'card_ids': [cid], 'flag': 4})
    assert collection_rows(r) == before
    assert not r.restored


def test_exception_after_backend_write_is_unknown_and_never_repeated(runtime, monkeypatch):
    r = runtime
    cid = r.col.get_note(add(r)).card_ids()[0]
    before = collection_rows(r)
    actual_set_flag = r.col.set_user_flag_for_cards
    applications = []

    def write_then_fail(flag, cids):
        applications.append((flag, list(cids)))
        actual_set_flag(flag, cids)
        raise RuntimeError('synthetic lost result after write')

    monkeypatch.setattr(r.col, 'set_user_flag_for_cards', write_then_fail)
    params = {'card_ids': [cid], 'flag': 4}
    preview = r.ops.prepare('set_card_flags', params, 'flag-result-unknown')
    outcome = r.ops.apply(preview['operation_id'], preview['preview_token'])
    assert outcome['state'] == 'unknown'
    assert outcome['error'] == 'apply-result-unknown:RuntimeError'
    assert 'result' not in outcome
    assert outcome['sync']['state'] == 'not-started'
    assert r.col.get_card(cid).user_flag() == 4
    after = collection_rows(r)
    assert_only_flags_changed(before, after, {cid})

    assert r.ops.prepare('set_card_flags', params, 'flag-result-unknown') == outcome
    assert r.ops.apply(preview['operation_id'], preview['preview_token']) == outcome
    assert applications == [(4, [cid])]
    assert collection_rows(r) == after
    assert not r.restored
