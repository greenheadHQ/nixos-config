"""Real collection proof for the last-read -> pre-sync -> prepare boundary.

OperationService, Operations, the adapter, AnkiConnect and the Anki backend are
real. Only the helper transport and sync are replaced: pre-sync injects an edit
into a disposable collection. This tests an incoming edit's effect, not AnkiWeb
merging or proof that any user's actual memo has been lost.
"""

import asyncio
import copy
import os
import sys
from pathlib import Path

import pytest

from test_real_collection import add, runtime  # noqa: F401: register the fixture
from test_review_memos import LONG_MEMO, MEMO_FIELD, _card_state, _readback

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, os.environ.get('ANKI_MCP_SOURCE', str(ROOT / 'modules/nixos/programs/anki-mcp/src')))
from anki_mcp.helper import HelperRejected
from anki_mcp.operations import OperationService


@pytest.mark.parametrize('action', ['update_fields', 'update_fields_bulk'])
@pytest.mark.parametrize('guarded,incoming', [(False, True), (True, True), (True, False)],
                         ids=['unguarded-loss-control', 'guarded-changed', 'guarded-unchanged'])
def test_review_memo_cleanup_through_service_presync(runtime, action, guarded, incoming):
    r = runtime
    name = 'Basic (and reversed card)'
    r.apply('model_field_add', {'model_name': name, 'field_name': MEMO_FIELD}, schema=True)
    fields = {'Front': '합성 질문', 'Back': '기존 답변', MEMO_FIELD: LONG_MEMO}
    selected = [add(r, name, fields) for _ in range(2 if action == 'update_fields_bulk' else 1)]
    unfinished = add(r, name, {**fields, MEMO_FIELD: LONG_MEMO + '\n\n미해결 질문'})
    all_notes = [*selected, unfinished]
    all_cards = [cid for nid in all_notes for cid in r.col.get_note(nid).card_ids()]
    assert len(all_cards) == len(all_notes) * 2
    r.apply('add_tags', {'note_ids': all_notes, 'tags': ['marked', 'keep::context']})
    r.apply('set_card_flags', {'card_ids': all_cards, 'flag': 4})
    r.apply('set_due_date', {'card_ids': all_cards, 'days': '3'})
    before_cards = {nid: _card_state(r, nid) for nid in all_notes}
    assert all(value['reviews'] for value in before_cards.values())
    before_fields = {nid: dict(r.col.get_note(nid).items()) for nid in all_notes}
    before_tags = {nid: set(r.col.get_note(nid).tags) for nid in all_notes}
    excluded = r.col.db.all('select * from notes where id=?', unfinished)
    model_before = copy.deepcopy(r.adapter.model_info(name))
    backup_count = len(r.restored)
    journal_before = set(r.ops.root.glob('*.json'))
    # Read the complete values through the same AnkiConnect entry used by note
    # lookup. Exact HTML, newlines and trailing text belong in expected_fields.
    observed = {note['noteId']: note['fields'][MEMO_FIELD]['value']
                for note in r.ac.notesInfo(notes=selected)}
    assert all(value == LONG_MEMO for value in observed.values())
    incoming_memo = LONG_MEMO + '\n\n<p>새 질문 B: 아직 검토하지 않은 내용 &amp; 예시</p>\n'
    events = ['read']
    prepare_values, imported_rows, sync_calls, helper_calls = [], [], [], []

    class HelperTransport:
        async def post(self, path, payload):
            helper_calls.append(path)
            try:
                if path == '/operations/status':
                    return r.ops.status(payload['operation_id'])
                if path == '/operations/prepare':
                    events.append('prepare')
                    prepare_values.append(r.col.get_note(selected[-1])[MEMO_FIELD])
                    return r.ops.prepare(payload['action'], payload['params'], payload['request_id'])
                if path == '/operations/apply':
                    return r.ops.apply(payload['operation_id'], payload['preview_token'], payload['confirm'])
                assert path == '/operations/delivery'
                return r.ops.record_delivery(payload['operation_id'], payload['kind'], payload['receipt'])
            except r.error as err:
                raise HelperRejected(str(err)) from err

    class IncomingMemoSync:
        async def run_fresh(self, *, after=None):
            sync_calls.append(after)
            if after is None:
                if incoming:
                    r.ac.updateNoteFields(note={'id': selected[-1], 'fields': {MEMO_FIELD: incoming_memo}})
                imported_rows.append(r.col.db.all('select * from notes order by id'))
                events.append('pre-sync')
            return {'outcome': 'synced', 'status': {
                'runId': f'fixture-sync-{len(sync_calls)}', 'result': 'success', 'action': 'normal',
            }}

    service = OperationService(HelperTransport(), IncomingMemoSync(), None, sync_enabled=True)
    updates = [{'note_id': nid, 'fields': {MEMO_FIELD: ''},
                **({'expected_fields': {MEMO_FIELD: observed[nid]}} if guarded else {})}
               for nid in selected]
    params = {'notes': updates} if action == 'update_fields_bulk' else updates[0]
    call = service.run(action, params, request_id='review-memo-presync')
    if guarded and incoming:
        with pytest.raises(HelperRejected, match='^expected-field-value-mismatch$'):
            asyncio.run(call)
        assert helper_calls == ['/operations/status', '/operations/prepare']
        assert sync_calls == [None]
        assert len(r.restored) == backup_count
        assert set(r.ops.root.glob('*.json')) == journal_before
        # An unchanged item before the changed one must not be partly cleared.
        assert r.col.db.all('select * from notes order by id') == imported_rows[0]
        for nid in selected:
            _readback(r, nid, incoming_memo if nid == selected[-1] else observed[nid])
    else:
        result = asyncio.run(call)
        assert result['state'] == 'applied' and result['sync']['state'] == 'synced'
        assert helper_calls.count('/operations/apply') == 1
        assert len(sync_calls) == 2 and sync_calls[0] is None and sync_calls[1] is not None
        assert len(r.restored) == backup_count + 1
        for nid in selected:
            _readback(r, nid, '')
    assert events == ['read', 'pre-sync', 'prepare']
    assert prepare_values == [incoming_memo if incoming else observed[selected[-1]]]
    for nid in all_notes:
        assert {key: value for key, value in r.col.get_note(nid).items() if key != MEMO_FIELD} == {
            key: value for key, value in before_fields[nid].items() if key != MEMO_FIELD}
        assert set(r.col.get_note(nid).tags) == before_tags[nid]
        assert _card_state(r, nid) == before_cards[nid]
    assert r.col.db.all('select * from notes where id=?', unfinished) == excluded
    assert r.adapter.model_info(name) == model_before
    # This operation is only the memo step. The caller must retain marked on
    # refusal, and remove it only after successful memo readback and consent.
    assert all('marked' in r.col.get_note(nid).tags for nid in all_notes)
