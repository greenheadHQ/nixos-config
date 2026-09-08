"""Real Anki API checks, separate from the fast offline MCP suite.

Run with Anki/aqt 26.8 and ANKICONNECT_SOURCE pointing to the built, patched
addon directory. Uses generated collections only; no HTTP listeners or accounts.
Qt window/progress callbacks are inert, while AnkiConnect and the Rust collection
backend are real. This does not exercise a Linux systemd deployment or AnkiWeb.
"""
import ast
import base64
import importlib.util
import json
import os
import sys
import types
import zipfile
from pathlib import Path

import anki
import aqt
import pytest
from anki.collection import Collection

ROOT = Path(__file__).resolve().parents[2]
HOST = ROOT / 'modules/nixos/programs/anki-host/sync-addon'


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path, submodule_search_locations=[str(path.parent)])
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def runtime(tmp_path, monkeypatch):
    assert anki.version == '26.08'
    anki.lang.set_lang('en')
    credentials = tmp_path / 'credentials'
    credentials.mkdir()
    for i, role in enumerate(('read', 'operation', 'maintenance', 'schema'), 1):
        (credentials / role).write_text(str(i) * 64)
    monkeypatch.setenv('CREDENTIALS_DIRECTORY', str(credentials))
    values = {'MAIN_TIMEOUT_SECS': '30', 'BUSY_WAIT_SECS': '1', 'QUERY_TIMEOUT_SECS': '1',
              'GUARD_MIN_RETAIN_PCT': '80', 'OPERATION_TTL_SECS': '600', 'BULK_LIMIT': '20',
              'MEDIA_MAX_BYTES': '5242880', 'BODY_MAX_BYTES': '8388608', 'BODY_TIMEOUT_SECS': '1',
              'MAX_REQUESTS': '8', 'INSTANCE': 'fixture', 'MIRROR_TIMEOUT_SECS': '5',
              'HELPER_PORT': '0', 'STATE_DIR': str(tmp_path)}
    for key, value in values.items():
        monkeypatch.setenv('ANKI_HOST_' + key, value)
    monkeypatch.delenv('ANKI_HOST_SYNC_CREDENTIALS', raising=False)
    col = Collection(str(tmp_path / 'collection.anki2'))
    # GUI reset clears the note-type cache via operation_did_execute. Preserve
    # that non-visual behavior while omitting all widgets/window activation.
    def reset():
        col.models._clear_cache()
    window = types.SimpleNamespace(col=col, reset=reset, requireReset=reset,
             pm=types.SimpleNamespace(name='fixture'), progress=types.SimpleNamespace(start=lambda: None, finish=lambda: None))
    monkeypatch.setattr(aqt, 'mw', window)
    source = Path(os.environ['ANKICONNECT_SOURCE']) / '__init__.py'
    connect = load('plugin', source)  # documented upstream test entry: no listener
    window._anki_host_connect = connect.AnkiConnect()
    window._anki_host_connect_version = 1
    helper = load('anki_real_fixture', HOST / '__init__.py')
    adapter = helper.AnkiAdapter(window, 5242880)
    adapter.check_bridge()
    from anki_real_fixture.operations import Operations, OperationError, digest
    restored = []
    def restore(opid):
        before = helper._collection_identity()
        pending = next((json.loads(p.read_text()) for p in (tmp_path / 'journal').glob('*.json') if p.stem == opid), None)
        source_snapshot = adapter.inspect(pending['spec'])['snapshot'] if pending else None
        receipt = helper._export(str(tmp_path / 'restore-points' / (opid + '.colpkg')), False, False)
        assert helper._collection_identity() == before
        if pending:
            assert adapter.inspect(pending['spec'])['snapshot'] == source_snapshot
        with zipfile.ZipFile(receipt['path']) as package:
            assert package.testzip() is None
        restored.append(receipt)
        return {'mirrored': True, 'sha256': 'f' * 64}
    ops = Operations(tmp_path / 'journal', adapter, restore, ttl=600, bulk_limit=20, media_limit=5242880)
    def apply(action, params, *, schema=False):
        preview = ops.prepare(action, params)
        outcome = ops.apply(preview['operation_id'], preview['preview_token'], True, schema_authorized=schema)
        assert outcome['state'] == 'applied', json.dumps(outcome, ensure_ascii=False)
        return preview, outcome
    yield types.SimpleNamespace(col=col, ac=window._anki_host_connect, adapter=adapter, ops=ops, helper=helper,
              window=window, connect=connect, apply=apply, restored=restored, error=OperationError, digest=digest,
              root=tmp_path, source=source)
    aqt.gui_hooks.profile_did_open.remove(helper._on_profile_open)
    aqt.gui_hooks.profile_will_close.remove(helper._on_profile_close)
    col.close()


def add(r, model='Basic', fields=None, deck='Default'):
    _, outcome = r.apply('add_notes', {'notes': [{'deck_name': deck, 'model_name': model,
                  'fields': fields or {'Front': 'front', 'Back': 'back'}, 'tags': []}], 'allow_duplicate': True})
    return outcome['result']['results'][0]['noteId']


def test_packaged_bridge_registration_and_profile_readiness(runtime, monkeypatch):
    r = runtime
    calls = []
    monkeypatch.setattr(r.connect.Edit, 'register_with_anki', lambda: calls.append('edit'))
    def listener(ac):
        assert aqt.mw._anki_host_connect is ac and aqt.mw._anki_host_connect_version == 1
        calls.append('listener')
    monkeypatch.setattr(r.connect.AnkiConnect, 'startWebServer', listener)
    monkeypatch.setattr(r.connect.AnkiConnect, 'initLogging', lambda _: None)
    module = ast.parse(r.source.read_text())
    entry = module.body[-1]
    assert isinstance(entry, ast.If)
    scope = dict(vars(r.connect), __name__='anki_connect_lifecycle_fixture')
    exec(compile(ast.Module(body=[entry], type_ignores=[]), str(r.source), 'exec'), scope)
    assert calls == ['edit', 'listener']
    r.helper._on_profile_open()
    assert r.helper._status_quick()['collection_open'] is True


def test_note_fields_tags_and_scheduling(runtime):
    r = runtime
    nid = add(r)
    cid = r.col.get_note(nid).card_ids()[0]
    untouched = add(r, fields={'Front': 'unrelated', 'Back': 'keep'})
    untouched_before = r.col.db.all('select * from notes where id=?', untouched)
    r.apply('update_fields', {'note_id': nid, 'fields': {'Back': 'updated'}})
    r.apply('add_tags', {'note_ids': [nid], 'tags': ['testtag']})
    assert 'mcp::added' in r.col.get_note(nid).tags and 'testtag' in r.col.get_note(nid).tags
    r.apply('remove_tags', {'note_ids': [nid], 'tags': ['testtag']})
    ids = [cid]
    r.apply('suspend_cards', {'card_ids': ids, 'suspended': True})
    assert ids == [cid] and r.col.get_card(cid).queue == -1
    r.apply('suspend_cards', {'card_ids': ids, 'suspended': False})
    r.apply('set_due_date', {'card_ids': ids, 'days': '2'})
    assert r.col.get_card(cid).queue == 2
    prior_reviews = r.col.db.all('select * from revlog where cid=?', cid)
    assert prior_reviews
    r.apply('forget_cards', {'card_ids': ids})
    assert r.col.get_card(cid).type == 0
    assert all(row in r.col.db.all('select * from revlog where cid=?', cid) for row in prior_reviews)
    assert r.col.db.all('select * from notes where id=?', untouched) == untouched_before
    assert r.col.get_note(nid)['Back'] == 'updated'
    assert len(r.restored) == 2


def test_cloze_bulk_card_count_and_export_reopen(runtime):
    r = runtime
    nid = add(r, 'Cloze', {'Text': '{{c1::old}}', 'Back Extra': ''})
    text = ' '.join('{{c%d::new}}' % n for n in range(2, 22))
    preview, _ = r.apply('update_fields', {'note_id': nid, 'fields': {'Text': text}})
    assert preview['summary']['cards'] == 21 and preview['backup_required']
    assert len(r.col.get_note(nid).card_ids()) == 21
    assert len(r.restored) == 1
    r.apply('add_tags', {'note_ids': [nid], 'tags': ['afterexport']})
    assert 'afterexport' in r.col.get_note(nid).tags


def test_deck_children_siblings_and_shared_options(runtime):
    r = runtime
    for name in ('A', 'A::Child', 'B'):
        r.apply('create_deck', {'name': name})
    nid = add(r, 'Basic (and reversed card)', {'Front': 'first', 'Back': 'second'}, 'A::Child')
    cards = r.col.get_note(nid).card_ids()
    r.apply('move_cards', {'card_ids': [cards[1]], 'deck_name': 'B'})
    _, _ = r.apply('update_deck_options', {'deck_name': 'A', 'changes': {'new.perDay': 25}})
    assert r.adapter.deck_options('B')['options']['new.perDay'] == 25
    preview, _ = r.apply('delete_decks', {'deck_names': ['A']})
    assert preview['summary']['cards_to_remove'] == 1 and preview['summary']['notes_to_remove'] == 0
    assert r.col.get_note(nid).card_ids() == [cards[1]]
    assert r.col.decks.by_name('A') is None and r.col.decks.by_name('A::Child') is None
    r.apply('delete_notes', {'note_ids': [nid]})
    assert r.col.note_count() == 0


def test_model_members_and_media(runtime):
    r = runtime
    nid = add(r)
    r.apply('model_field_add', {'model_name': 'Basic', 'field_name': 'Extra', 'index': 1}, schema=True)
    r.apply('model_field_rename', {'model_name': 'Basic', 'field_name': 'Extra', 'new_name': 'Memo'}, schema=True)
    r.apply('model_field_reposition', {'model_name': 'Basic', 'field_name': 'Memo', 'index': 2}, schema=True)
    r.apply('model_field_remove', {'model_name': 'Basic', 'field_name': 'Memo'}, schema=True)
    assert r.col.get_note(nid)['Front'] == 'front' and r.col.get_note(nid)['Back'] == 'back'
    r.apply('model_template_add', {'model_name': 'Basic', 'template_name': 'Extra', 'front': '{{Back}}', 'back': '{{Front}}'}, schema=True)
    assert len(r.col.get_note(nid).card_ids()) == 2
    r.apply('model_template_update', {'model_name': 'Basic', 'template_name': 'Extra', 'front': '{{Back}}!', 'back': '{{Front}}!'}, schema=True)
    extra = r.col.get_note(nid).card_ids()[1]
    r.apply('set_due_date', {'card_ids': [extra], 'days': '1'})
    reviews = r.col.db.all('select * from revlog where cid=?', extra)
    r.apply('model_template_remove', {'model_name': 'Basic', 'template_name': 'Extra'}, schema=True)
    assert len(r.col.get_note(nid).card_ids()) == 1
    assert r.col.db.all('select * from revlog where cid=?', extra) == reviews
    r.apply('model_css_update', {'model_name': 'Basic', 'css': ''})
    assert r.adapter.model_info('Basic')['css'] == ''
    data = base64.b64encode(b'synthetic-media').decode()
    r.apply('store_media', {'filename': 'fixture.txt', 'data': data})
    r.apply('store_media', {'filename': 'fixture.txt', 'data': data})
    with pytest.raises(r.error, match='media-exists-with-different-content'):
        r.ops.prepare('store_media', {'filename': 'fixture.txt', 'data': base64.b64encode(b'different').decode()})
    assert (Path(r.col.media.dir()) / 'fixture.txt').read_bytes() == b'synthetic-media'


def test_export_failure_reopens_collection(runtime):
    r = runtime
    nid = add(r)
    # An overlong output filename fails inside the real export backend after
    # Python closes the DB. The parent is valid, so preparation succeeds.
    target = r.root / 'restore-points' / ('x' * 260 + '.colpkg')
    with pytest.raises(Exception):
        r.helper._export(str(target), False, False)
    assert r.col.get_note(nid)['Front'] == 'front'
