"""Real Anki readback for link diagnostics; synthetic collections only."""

import copy
import json

import pytest

from test_real_collection import add, runtime  # noqa: F401

MISSING = 1700000000000


def marker(nid, title='reference'):
    return f'[{title}|nid{nid}]'


def check(out):
    value = out['link_check']
    assert value['state'] == 'checked', value
    assert value['scope'] == 'stored-note-link-candidates'
    assert not value['truncated']
    return value


def test_add_new_dangling_reference_in_real_stored_fields(runtime):
    r = runtime
    target = add(r, fields={'Front': 'target', 'Back': 'exists'})
    _, out = r.apply('add_notes', {'notes': [{'deck_name': 'Default', 'model_name': 'Basic',
        'fields': {'Front': 'source', 'Back': marker(target) + marker(MISSING)}}], 'allow_duplicate': False})
    source = out['result']['results'][0]['noteId']
    assert check(out)['references'] == [{'source_note_id': source, 'field_name': 'Back',
        'target_note_id': MISSING, 'new_occurrences': 1}]
    assert r.col.get_note(source)['Back'] == marker(target) + marker(MISSING)


def test_field_edits_only_report_new_occurrences_and_preserve_cards(runtime):
    r = runtime
    source = add(r, fields={'Front': 'source', 'Back': marker(MISSING)})
    before = r.col.db.all('select * from cards')
    _, same = r.apply('update_fields', {'note_id': source, 'fields': {'Back': marker(MISSING, 'new title')}})
    assert check(same)['new_missing_occurrences'] == 0
    _, out = r.apply('update_fields', {'note_id': source, 'fields': {'Back': marker(MISSING) * 2}})
    assert check(out)['new_missing_occurrences'] == 1
    assert check(out)['references'][0]['source_note_id'] == source
    assert r.col.db.all('select * from cards') == before
    _, removed = r.apply('update_fields', {'note_id': source, 'fields': {'Back': 'no references'}})
    assert check(removed)['new_missing_occurrences'] == 0


def test_delete_reports_surviving_sources_but_not_deleted_sources(runtime):
    r = runtime
    target = add(r, fields={'Front': 'target', 'Back': 'exists'})
    removed_source = add(r, fields={'Front': 'removed source', 'Back': marker(target)})
    retained_source = add(r, fields={'Front': 'retained source', 'Back': marker(target) * 2})
    _, out = r.apply('delete_notes', {'note_ids': [target, removed_source]})
    assert check(out)['references'] == [{'source_note_id': retained_source, 'field_name': 'Back',
        'target_note_id': target, 'new_occurrences': 2}]
    assert r.col.get_note(retained_source)['Back'] == marker(target) * 2


def test_deck_delete_respects_sibling_cards_that_keep_target_note_alive(runtime):
    r = runtime
    for deck in ['Delete', 'Delete::Child', 'Keep']:
        r.apply('create_deck', {'name': deck})
    retained = add(r, 'Basic (and reversed card)', {'Front': 'retained', 'Back': 'second'}, 'Delete::Child')
    deleted = add(r, fields={'Front': 'deleted target', 'Back': 'gone'}, deck='Delete')
    sibling = r.col.get_note(retained).card_ids()[1]
    r.apply('move_cards', {'card_ids': [sibling], 'deck_name': 'Keep'})
    source = add(r, fields={'Front': 'source', 'Back': marker(retained) + marker(deleted)}, deck='Keep')
    _, out = r.apply('delete_decks', {'deck_names': ['Delete']})
    assert check(out)['references'] == [{'source_note_id': source, 'field_name': 'Back',
        'target_note_id': deleted, 'new_occurrences': 1}]
    assert r.col.get_note(retained).card_ids() == [sibling]


def test_bulk_partial_readback_includes_actual_uncertain_write_but_not_unattempted(runtime, monkeypatch):
    r = runtime
    ids = [add(r, fields={'Front': f'question {n}', 'Back': 'old'}) for n in range(3)]
    original = r.ac.updateNoteFields
    def write(note):
        original(note=note)
        if note['id'] == ids[1]:
            raise RuntimeError('lost response after actual mutation')
    monkeypatch.setattr(r.ac, 'updateNoteFields', write)
    p = r.ops.prepare('update_fields_bulk', {'notes': [
        {'note_id': nid, 'fields': {'Back': marker(MISSING)}} for nid in ids]}, 'partial-links')
    out = r.ops.apply(p['operation_id'], p['preview_token'])
    assert out['state'] == 'partial'
    assert [item['state'] for item in out['result']['results']] == ['applied', 'unknown', 'not-attempted']
    assert [ref['source_note_id'] for ref in check(out)['references']] == ids[:2]
    assert check(out)['new_missing_occurrences'] == 2
    assert r.col.get_note(ids[2])['Back'] == 'old'
    assert r.ops.apply(p['operation_id'], p['preview_token']) == out


def test_diagnostic_read_failure_after_real_write_keeps_success(runtime, monkeypatch):
    r = runtime
    nid = add(r)
    real_read = r.adapter.note_link_snapshot
    calls = []
    def read():
        calls.append(True)
        if len(calls) == 2:
            raise RuntimeError('private note content')
        return real_read()
    monkeypatch.setattr(r.adapter, 'note_link_snapshot', read)
    _, out = r.apply('update_fields', {'note_id': nid, 'fields': {'Back': marker(MISSING)}})
    assert out['state'] == 'applied' and r.col.get_note(nid)['Back'] == marker(MISSING)
    assert out['link_check'] == {'state': 'unavailable', 'scope': 'stored-note-link-candidates',
                                 'stage': 'after-write', 'error': 'RuntimeError'}
    assert 'private note content' not in json.dumps(out)


def test_snapshot_is_read_only_and_preserves_all_note_card_review_rows(runtime):
    r = runtime
    target = add(r)
    source = add(r, fields={'Front': 'source', 'Back': marker(target) + marker(MISSING)})
    r.apply('set_due_date', {'card_ids': r.col.get_note(source).card_ids(), 'days': '4'})
    r.apply('add_tags', {'note_ids': [source], 'tags': ['marked', 'keep']})
    before = {table: r.col.db.all(f'select * from {table} order by id') for table in ('notes', 'cards', 'revlog')}
    assert before['revlog']
    models = copy.deepcopy(r.col.models.all())
    snapshot = r.adapter.note_link_snapshot()
    assert snapshot['missing'][(source, 'Back', MISSING)] == 1
    assert {table: r.col.db.all(f'select * from {table} order by id') for table in before} == before
    assert r.col.models.all() == models


def test_unknown_single_write_has_diagnostic_but_is_not_success_or_retry(runtime, monkeypatch):
    r = runtime
    source = add(r)
    original = r.ac.updateNoteFields
    calls = []
    def write(note):
        calls.append(note['id'])
        original(note=note)
        raise RuntimeError('lost response after actual mutation')
    monkeypatch.setattr(r.ac, 'updateNoteFields', write)
    p = r.ops.prepare('update_fields', {'note_id': source, 'fields': {'Back': marker(MISSING)}}, 'unknown-links')
    out = r.ops.apply(p['operation_id'], p['preview_token'])
    assert out['state'] == 'unknown' and out['sync']['state'] == 'not-started'
    assert check(out)['new_missing_occurrences'] == 1
    assert r.col.get_note(source)['Back'] == marker(MISSING)
    assert r.ops.apply(p['operation_id'], p['preview_token']) == out
    assert calls == [source]


@pytest.mark.parametrize('delete_original', [False, True])
def test_filtered_deck_reference_follows_actual_target_survival(runtime, delete_original):
    from test_deck_delete_receipts import filtered_deck_with_card
    r = runtime
    r.apply('create_deck', {'name': 'Source'})
    target = add(r, deck='Source')
    cid = r.col.get_note(target).card_ids()[0]
    filtered_deck_with_card(r, 'Filtered', cid)
    source = add(r, fields={'Front': 'source', 'Back': marker(target)})
    _, out = r.apply('delete_decks', {'deck_names': ['Source' if delete_original else 'Filtered']})
    assert check(out)['new_missing_occurrences'] == int(delete_original)
    if delete_original:
        assert check(out)['references'][0]['source_note_id'] == source
        assert not r.col.db.list('select id from notes where id=?', target)
    else:
        assert r.col.get_note(target).card_ids() == [cid]


def test_default_deck_retention_does_not_hide_its_deleted_note_references(runtime):
    r = runtime
    target = add(r)
    r.apply('create_deck', {'name': 'Keep'})
    source = add(r, fields={'Front': 'source', 'Back': marker(target)}, deck='Keep')
    _, out = r.apply('delete_decks', {'deck_names': ['Default']})
    assert out['result']['retained_decks'] == ['Default']
    assert check(out)['new_missing_occurrences'] == 1
    assert check(out)['references'][0]['source_note_id'] == source
