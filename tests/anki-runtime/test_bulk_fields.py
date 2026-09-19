"""Bulk field edits and their restore points against generated Anki collections.

The real Anki backend and patched AnkiConnect are used with inert UI callbacks.
No production collection, account, AnkiWeb connection, or HTTP listener is used.
"""

import copy

import pytest

from test_real_collection import add, runtime  # noqa: F401


def collection_rows(r):
    return {table: r.col.db.all(f'select * from {table} order by id')
            for table in ('notes', 'cards', 'revlog')}


def note_fields(r, note_ids):
    return {nid: dict(r.col.get_note(nid).items()) for nid in note_ids}


def assert_receipt(outcome, note_ids):
    assert outcome['state'] == 'applied', outcome
    assert outcome['result']['updated'] == len(note_ids)
    assert outcome['result']['attempted'] == len(note_ids)
    assert [(item['note_id'], item['state']) for item in outcome['result']['results']] == [
        (nid, 'applied') for nid in note_ids]


def test_single_field_edit_has_restore_point_without_extra_confirmation(runtime):
    r = runtime
    nid = add(r, fields={'Front': 'keep question', 'Back': 'old answer'})
    before = collection_rows(r)
    preview = r.ops.prepare('update_fields', {'note_id': nid, 'fields': {'Back': 'new answer'}})
    assert preview['backup_required'] is True
    assert preview['confirmation_required'] is False
    assert preview['schema_required'] is False
    assert not r.restored
    outcome = r.ops.apply(preview['operation_id'], preview['preview_token'])
    assert outcome['state'] == 'applied', outcome
    assert len(r.restored) == 1
    assert r.col.get_note(nid)['Front'] == 'keep question'
    assert r.col.get_note(nid)['Back'] == 'new answer'
    after = collection_rows(r)
    assert after['cards'] == before['cards']
    assert after['revlog'] == before['revlog']


def test_bulk_mixed_note_types_preserves_other_fields_scheduling_and_reviews(runtime):
    r = runtime
    basic = add(r, fields={'Front': 'basic question', 'Back': 'old answer'})
    reversed_note = add(r, 'Basic (and reversed card)', {'Front': '앞면', 'Back': '뒷면'})
    cloze = add(r, 'Cloze', {'Text': '{{c1::사과}}와 {{c2::배}}', 'Back Extra': 'old context'})
    unrelated = add(r, fields={'Front': 'unrelated question', 'Back': 'do not change'})
    selected = [basic, reversed_note, cloze]
    all_ids = [*selected, unrelated]
    card_ids = [cid for nid in all_ids for cid in r.col.get_note(nid).card_ids()]
    r.apply('set_due_date', {'card_ids': card_ids, 'days': '3'})
    r.col.set_user_flag_for_cards(4, card_ids)
    r.apply('add_tags', {'note_ids': selected, 'tags': ['marked', 'keep-tag']})
    before = collection_rows(r)
    assert before['revlog'], 'Preservation must include nonempty review history.'
    original_fields = note_fields(r, all_ids)
    original_tags = {nid: r.col.get_note(nid).tags for nid in all_ids}
    types = {name: copy.deepcopy(r.adapter.model_info(name)) for name in (
        'Basic', 'Basic (and reversed card)', 'Cloze')}
    backup_count = len(r.restored)
    patches = [
        {'note_id': basic, 'fields': {'Back': '<p>첫 문단</p><p>둘째 문단 — 전체 보존</p>'}},
        {'note_id': reversed_note, 'fields': {'Back': '새 뒷면'}},
        {'note_id': cloze, 'fields': {'Back Extra': 'new context'}},
    ]
    preview = r.ops.prepare('update_fields_bulk', {'notes': patches}, 'mixed-field-edits')
    assert preview['summary']['notes'] == 3
    assert preview['summary']['cards'] == 5
    assert preview['backup_required'] is True
    assert preview['confirmation_required'] is False
    assert preview['schema_required'] is False
    assert collection_rows(r) == before
    outcome = r.ops.apply(preview['operation_id'], preview['preview_token'])
    assert_receipt(outcome, selected)
    assert len(r.restored) == backup_count + 1
    for patch in patches:
        nid = patch['note_id']
        expected = {**original_fields[nid], **patch['fields']}
        assert dict(r.col.get_note(nid).items()) == expected
        readback = r.ac.notesInfo(notes=[nid])[0]
        assert {name: info['value'] for name, info in readback['fields'].items()} == expected
    assert dict(r.col.get_note(unrelated).items()) == original_fields[unrelated]
    assert {nid: r.col.get_note(nid).tags for nid in all_ids} == original_tags
    after = collection_rows(r)
    assert after['cards'] == before['cards']
    assert after['revlog'] == before['revlog']
    assert next(row for row in after['notes'] if row[0] == unrelated) == next(
        row for row in before['notes'] if row[0] == unrelated)
    assert {name: r.adapter.model_info(name) for name in types} == types

    # A retried request returns the same receipt, with no second write or export.
    assert r.ops.prepare('update_fields_bulk', {'notes': patches}, 'mixed-field-edits') == outcome
    assert r.ops.apply(preview['operation_id'], preview['preview_token']) == outcome
    assert collection_rows(r) == after
    assert len(r.restored) == backup_count + 1


@pytest.mark.parametrize('card_count', [20, 21])
def test_bulk_confirmation_boundary_counts_sibling_cards_not_just_notes(runtime, card_count):
    r = runtime
    note_ids = [add(r, 'Basic (and reversed card)', {'Front': f'question {i}', 'Back': 'old'})
                for i in range(10)]
    if card_count == 21:
        note_ids.append(add(r, fields={'Front': 'one more question', 'Back': 'old'}))
    patches = [{'note_id': nid, 'fields': {'Back': f'new answer {i}'}}
               for i, nid in enumerate(note_ids)]
    before = collection_rows(r)
    assert len(before['cards']) == card_count
    preview = r.ops.prepare('update_fields_bulk', {'notes': patches})
    assert preview['summary']['notes'] == len(note_ids)
    assert preview['summary']['cards'] == card_count
    assert preview['confirmation_required'] is (card_count > 20)
    assert preview['backup_required'] is True
    if card_count > 20:
        with pytest.raises(r.error, match='explicit-confirmation-required'):
            r.ops.apply(preview['operation_id'], preview['preview_token'])
        assert collection_rows(r) == before
        assert not r.restored
    outcome = r.ops.apply(preview['operation_id'], preview['preview_token'], card_count > 20)
    assert_receipt(outcome, note_ids)
    assert len(r.restored) == 1
    assert collection_rows(r)['cards'] == before['cards']
    for patch in patches:
        assert r.col.get_note(patch['note_id'])['Back'] == patch['fields']['Back']


@pytest.mark.parametrize('card_count', [20, 21])
def test_bulk_cloze_impact_includes_old_and_new_ordinals_per_note(runtime, card_count):
    r = runtime
    first = add(r, 'Cloze', {'Text': '{{c1::old first}}', 'Back Extra': 'keep first'})
    second = add(r, 'Cloze', {'Text': '{{c1::old second}}', 'Back Extra': 'keep second'})
    old_cards = [*r.col.get_note(first).card_ids(), *r.col.get_note(second).card_ids()]
    r.apply('set_due_date', {'card_ids': old_cards, 'days': '2'})
    before = collection_rows(r)
    backups_before = len(r.restored)
    # Both notes have c1, but they are different cards. The first note's old c1
    # remains after being replaced by disjoint ordinals, while the second c1 is
    # updated in place. A global union of ordinal numbers would undercount.
    patches = [
        {'note_id': first, 'fields': {'Text': ' '.join(
            '{{c%d::new first}}' % n for n in range(2, card_count))}},
        {'note_id': second, 'fields': {'Text': '{{c1::new second}}'}},
    ]
    preview = r.ops.prepare('update_fields_bulk', {'notes': patches})
    assert preview['summary']['notes'] == 2
    assert preview['summary']['cards'] == card_count
    assert preview['confirmation_required'] is (card_count > 20)
    assert preview['backup_required'] is True
    if card_count > 20:
        with pytest.raises(r.error, match='explicit-confirmation-required'):
            r.ops.apply(preview['operation_id'], preview['preview_token'])
        assert collection_rows(r) == before
        assert len(r.restored) == backups_before
    outcome = r.ops.apply(preview['operation_id'], preview['preview_token'], card_count > 20)
    assert_receipt(outcome, [first, second])
    assert len(r.restored) == backups_before + 1
    assert len(r.col.get_note(first).card_ids()) == card_count - 1
    assert len(r.col.get_note(second).card_ids()) == 1
    after = collection_rows(r)
    assert all(row in after['cards'] for row in before['cards'])
    assert after['revlog'] == before['revlog']
    assert r.col.get_note(first)['Back Extra'] == 'keep first'
    assert r.col.get_note(second)['Back Extra'] == 'keep second'


@pytest.mark.parametrize('invalid', ['wrong-field-for-type', 'missing-note'])
def test_bulk_invalid_later_item_rejects_every_item_before_backup(runtime, invalid):
    r = runtime
    first = add(r, fields={'Front': 'valid first', 'Back': 'keep first'})
    second = add(r, 'Cloze', {'Text': '{{c1::valid second}}', 'Back Extra': 'keep second'})
    later = ({'note_id': second, 'fields': {'Back': 'field absent on Cloze'}}
             if invalid == 'wrong-field-for-type' else
             {'note_id': second + 100000, 'fields': {'Text': 'missing note'}})
    before = collection_rows(r)
    journal_before = sorted((r.root / 'journal').glob('*.json'))
    with pytest.raises(r.error, match='unknown-note-field|note-not-found'):
        r.ops.prepare('update_fields_bulk', {'notes': [
            {'note_id': first, 'fields': {'Back': 'must not be written'}}, later]})
    assert collection_rows(r) == before
    assert sorted((r.root / 'journal').glob('*.json')) == journal_before
    assert not r.restored


@pytest.mark.parametrize('change', ['field', 'model'])
def test_bulk_rechecks_each_note_and_type_before_export(runtime, change):
    r = runtime
    first = add(r, fields={'Front': 'first', 'Back': 'old first'})
    second = add(r, 'Cloze', {'Text': '{{c1::second}}', 'Back Extra': 'old second'})
    preview = r.ops.prepare('update_fields_bulk', {'notes': [
        {'note_id': first, 'fields': {'Back': 'requested first'}},
        {'note_id': second, 'fields': {'Back Extra': 'requested second'}},
    ]})
    if change == 'field':
        r.ac.updateNoteFields(note={'id': second, 'fields': {'Back Extra': 'external change'}})
    else:
        r.ac.updateModelStyling(model={'name': 'Cloze', 'css': '.card { color: #123456; }'})
    before = collection_rows(r)
    with pytest.raises(r.error, match='stale-preview-create-a-new-request-id'):
        r.ops.apply(preview['operation_id'], preview['preview_token'])
    assert collection_rows(r) == before
    assert r.col.get_note(first)['Back'] == 'old first'
    assert not r.restored


def test_bulk_unverified_restore_point_prevents_every_write(runtime, monkeypatch):
    r = runtime
    note_ids = [add(r, fields={'Front': f'question {i}', 'Back': 'old'}) for i in range(2)]
    before = collection_rows(r)
    preview = r.ops.prepare('update_fields_bulk', {'notes': [
        {'note_id': nid, 'fields': {'Back': 'must not change'}} for nid in note_ids]})
    monkeypatch.setattr(r.ops, 'restore', lambda _: {'mirrored': False})
    with pytest.raises(r.error, match='restore-point-not-mirrored'):
        r.ops.apply(preview['operation_id'], preview['preview_token'])
    assert collection_rows(r) == before
    assert r.ops.status(preview['operation_id'])['state'] == 'prepared'
    assert not r.restored


@pytest.mark.parametrize('failure', ['exception-after-write', 'readback-mismatch'])
def test_bulk_unknown_item_stops_later_items_and_is_never_repeated(runtime, monkeypatch, failure):
    r = runtime
    note_ids = [add(r, fields={'Front': f'question {i}', 'Back': f'old {i}'}) for i in range(3)]
    before = collection_rows(r)
    real_update = r.ac.updateNoteFields
    attempted = []

    def update_with_failure(note):
        attempted.append(note['id'])
        if note['id'] == note_ids[1]:
            if failure == 'exception-after-write':
                real_update(note=note)
                raise RuntimeError('synthetic lost response after the actual write')
            return None  # A claimed success without a write must fail readback.
        return real_update(note=note)

    monkeypatch.setattr(r.ac, 'updateNoteFields', update_with_failure)
    params = {'notes': [{'note_id': nid, 'fields': {'Back': f'new {i}'}}
                        for i, nid in enumerate(note_ids)]}
    request_id = f'bulk-stop-{failure}'
    preview = r.ops.prepare('update_fields_bulk', params, request_id)
    outcome = r.ops.apply(preview['operation_id'], preview['preview_token'])
    assert outcome['state'] == 'partial', outcome
    result = outcome['result']
    assert result['updated'] == 1
    assert result['attempted'] == 2
    assert [(item['note_id'], item['state']) for item in result['results']] == [
        (note_ids[0], 'applied'), (note_ids[1], 'unknown'), (note_ids[2], 'not-attempted')]
    assert result['results'][1]['error']
    assert attempted == note_ids[:2]
    assert r.col.get_note(note_ids[0])['Back'] == 'new 0'
    assert r.col.get_note(note_ids[1])['Back'] == ('new 1' if failure == 'exception-after-write' else 'old 1')
    assert r.col.get_note(note_ids[2])['Back'] == 'old 2'
    assert len(r.restored) == 1
    after = collection_rows(r)
    assert after['cards'] == before['cards']
    assert after['revlog'] == before['revlog']
    assert next(row for row in after['notes'] if row[0] == note_ids[2]) == next(
        row for row in before['notes'] if row[0] == note_ids[2])

    assert r.ops.prepare('update_fields_bulk', params, request_id) == outcome
    assert r.ops.apply(preview['operation_id'], preview['preview_token']) == outcome
    assert attempted == note_ids[:2]
    assert len(r.restored) == 1
    assert collection_rows(r) == after


@pytest.mark.parametrize('normalize', [None, True, False])
def test_bulk_readback_follows_anki_field_normalization_setting(runtime, normalize):
    r = runtime
    if normalize is not None:
        r.col.set_config('normalize_note_text', normalize)
    latin = add(r, fields={'Front': 'latin decomposed', 'Back': 'old'})
    hangul = add(r, fields={'Front': 'hangul decomposed', 'Back': 'old'})
    controls = add(r, fields={'Front': 'ASCII controls', 'Back': 'old'})
    # The batch must continue after a correctly normalized first item.
    ids = [latin, hangul, controls]
    patches = [
        {'note_id': latin, 'fields': {'Back': 'e\u0301'}},
        {'note_id': hangul, 'fields': {'Back': '\u1100\u1161'}},
        {'note_id': controls, 'fields': {'Back': 'a\rb\x1fc\x7fd\t\ne\u0301'}},
    ]
    before = collection_rows(r)
    preview, outcome = r.apply('update_fields_bulk', {'notes': patches})
    assert_receipt(outcome, ids)
    assert preview['backup_required'] and not preview['confirmation_required']
    assert r.col.get_note(latin)['Back'] == ('e\u0301' if normalize is False else '\u00e9')
    assert r.col.get_note(hangul)['Back'] == ('\u1100\u1161' if normalize is False else '\uac00')
    assert r.col.get_note(controls)['Back'] == ('abcd\t\ne\u0301' if normalize is False else 'abcd\t\n\u00e9')
    assert r.col.get_config('normalize_note_text', None) is normalize
    after = collection_rows(r)
    assert after['cards'] == before['cards']
    assert after['revlog'] == before['revlog']
    assert len(r.restored) == 1


def test_bulk_unchanged_decomposed_field_survives_anki_noop_after_enabling_normalization(runtime):
    r = runtime
    r.col.set_config('normalize_note_text', False)
    nid = add(r, fields={'Front': 'unchanged note', 'Back': 'e\u0301'})
    r.col.set_config('normalize_note_text', True)
    _, outcome = r.apply('update_fields_bulk', {'notes': [{'note_id': nid, 'fields': {'Back': 'e\u0301'}}]})
    assert_receipt(outcome, [nid])
    assert r.col.get_note(nid)['Back'] == 'e\u0301'


def test_bulk_does_not_treat_nfc_equivalence_as_success_when_normalization_disabled(runtime, monkeypatch):
    r = runtime
    r.col.set_config('normalize_note_text', False)
    nid = add(r, fields={'Front': 'NFC content differs from requested NFD', 'Back': '\u00e9'})
    monkeypatch.setattr(r.ac, 'updateNoteFields', lambda **_: None)
    preview = r.ops.prepare('update_fields_bulk', {'notes': [{'note_id': nid, 'fields': {'Back': 'e\u0301'}}]})
    outcome = r.ops.apply(preview['operation_id'], preview['preview_token'])
    assert outcome['state'] == 'partial'
    assert outcome['result']['updated'] == 0
    assert outcome['result']['results'][0]['state'] == 'unknown'


@pytest.mark.parametrize('action', ['update_fields', 'update_fields_bulk'])
def test_field_impact_counts_cloze_markers_after_anki_control_removal(runtime, action):
    r = runtime
    r.col.set_config('normalize_note_text', False)
    nid = add(r, 'Cloze', {'Text': '{{c1::old}}', 'Back Extra': ''})
    changed = {'note_id': nid, 'fields': {'Text': ' '.join(
        '{{c%d\x1f::new}}' % ordinal for ordinal in range(2, 22))}}
    params = {'notes': [changed]} if action == 'update_fields_bulk' else changed
    preview = r.ops.prepare(action, params)
    assert preview['summary']['cards'] == 21
    assert preview['confirmation_required'] is True
    with pytest.raises(r.error, match='explicit-confirmation-required'):
        r.ops.apply(preview['operation_id'], preview['preview_token'])
    assert len(r.col.get_note(nid).card_ids()) == 1
    outcome = r.ops.apply(preview['operation_id'], preview['preview_token'], True)
    assert outcome['state'] == 'applied'
    assert len(r.col.get_note(nid).card_ids()) == 21
    assert '\x1f' not in r.col.get_note(nid)['Text']
