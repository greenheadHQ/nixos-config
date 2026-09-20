"""Real collection integration: explicit enrollment and locked mixed writes."""
import hashlib
import json
from pathlib import Path

import pytest
from test_real_collection import runtime, add  # noqa: F401


def configured(r, tmp_path):
    from anki_real_fixture.managed_bundle import build_bundle
    from anki_real_fixture.managed_runtime import ManagedRuntime, MODEL_NAME

    model = r.col.models.by_name('Basic')
    model['name'] = MODEL_NAME
    r.col.models.update_dict(model)
    r.col.models._clear_cache()
    model = r.col.models.by_name(MODEL_NAME)
    asset = '_managed-test.js'
    r.col.media.write_data(asset, b'window.example = 1;')
    bundle = build_bundle(model, {asset: b'window.example = 1;'})
    source = tmp_path / 'source'
    (source / 'assets').mkdir(parents=True)
    (source / 'assets' / asset).write_bytes(b'window.example = 1;')
    (source / 'bundle.json').write_text(json.dumps(bundle))

    def backup(opid):
        path = r.root / 'restore-points' / (opid + '.colpkg')
        r.helper._export(str(path), False, False)
        return {'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'mirrored': True}

    manager = ManagedRuntime(r.window, tmp_path / 'managed', source, instance='fixture',
                             snapshot=r.helper._collection_identity, restore_point=backup,
                             sync_status=lambda: {'result': 'success'}, ttl=600)
    return manager, model, asset


def enroll(manager):
    preview = manager.enrollment_prepare()
    result = manager.enrollment_apply(preview['operation_id'], preview['preview_token'], True)
    assert result['digest'] == preview['digest']
    return preview


def test_registration_requires_operator_preview_and_actual_verified_copy(runtime, tmp_path):
    r = runtime
    manager, model, asset = configured(r, tmp_path)
    assert manager.check()['status'] == 'unavailable'
    preview = manager.enrollment_prepare()
    with pytest.raises(r.error, match='confirmation'):
        manager.enrollment_apply(preview['operation_id'], preview['preview_token'], False)
    assert manager.check()['status'] == 'unavailable'
    manager.enrollment_apply(preview['operation_id'], preview['preview_token'], True)
    assert manager.check()['status'] == 'normal'
    assert manager.check('Basic (and reversed card)')['status'] == 'unmanaged'
    assert not manager.check('Basic (and reversed card)')['write_blocked']


def test_mixed_field_updates_rejected_before_any_note_changes(runtime, tmp_path):
    r = runtime
    manager, model, asset = configured(r, tmp_path)
    managed = add(r, model=model['name'])
    other = add(r, model='Basic (and reversed card)', fields={'Front': 'other', 'Back': 'back'})
    enroll(manager)
    r.adapter.managed_guard = manager.guard
    preview = r.ops.prepare('update_fields_bulk', {'notes': [
        {'note_id': other, 'fields': {'Front': 'other changed'}},
        {'note_id': managed, 'fields': {'Front': 'managed changed'}},
    ]})
    # A cached healthy report/preview is insufficient: mutate only media after
    # preparation, then verify both notes remain unchanged on apply refusal.
    Path(r.col.media.dir(), asset).write_bytes(b'changed after preview')
    with pytest.raises(r.error, match='managed-model-write-blocked'):
        r.ops.apply(preview['operation_id'], preview['preview_token'], True)
    assert r.col.get_note(other)['Front'] == 'other'
    assert r.col.get_note(managed)['Front'] == 'front'
    p = r.ops.prepare('update_fields', {'note_id': other, 'fields': {'Front': 'allowed'}})
    assert r.ops.apply(p['operation_id'], p['preview_token'])['state'] == 'applied'
    assert manager.check()['status'] == 'drift'


def test_guard_covers_creation_and_renamed_bound_type(runtime, tmp_path):
    r = runtime
    manager, model, asset = configured(r, tmp_path)
    nid = add(r, model=model['name'])
    enroll(manager)
    r.adapter.managed_guard = manager.guard
    model = r.col.models.by_name(model['name'])
    model['name'] = 'renamed managed type'
    r.col.models.update_dict(model)
    r.col.models._clear_cache()
    with pytest.raises(r.error, match='managed-model-write-blocked'):
        r.ops.prepare('update_fields', {'note_id': nid, 'fields': {'Back': 'denied'}})
    with pytest.raises(r.error, match='managed-model-write-blocked'):
        r.ops.prepare('add_notes', {'notes': [{'model_name': model['name'], 'deck_name': 'Default',
                          'fields': {'Front': 'denied', 'Back': 'denied'}}], 'allow_duplicate': True})


def test_enrollment_refuses_changed_state_and_unreviewed_git_source(runtime, tmp_path):
    r = runtime
    manager, model, asset = configured(r, tmp_path)
    preview = manager.enrollment_prepare()
    add(r, model=model['name'])
    with pytest.raises(r.error, match='preview-stale'):
        manager.enrollment_apply(preview['operation_id'], preview['preview_token'], True)
    model = r.col.models.by_name(model['name'])
    model['css'] += '\n/* changed in app */'
    r.col.models.update_dict(model)
    with pytest.raises(r.error, match='source-does-not-match-runtime'):
        manager.enrollment_prepare()


def test_http_allowlist_and_strict_restore_payload(runtime):
    r = runtime
    for path in ('/managed/enrollment/prepare', '/managed/enrollment/apply', '/managed/notification/retry'):
        assert r.helper.ACCESS.allowed('POST', path, 'schema')
        for role in ('operation', 'read', 'maintenance'):
            assert not r.helper.ACCESS.allowed('POST', path, role)
    assert r.helper.ACCESS.allowed('POST', '/managed/restore/apply', 'operation')
    assert not r.helper.ACCESS.allowed('POST', '/managed/restore/apply', 'read')
    with pytest.raises(r.error, match='invalid-parameters'):
        r.helper._managed_request('/managed/restore/prepare', {'request_id': 'fixture-request',
                                 'model_name': 'CS 재활 Basic', 'digest': '0' * 64})


def test_sync_status_projection_is_serializable_inside_same_sync_result(runtime):
    r = runtime
    result = {'at': '2026-09-20T12:00:00+00:00', 'mode': 'normal', 'action': 'normal', 'required': 'NO_CHANGES'}
    r.helper._state['last_sync'] = result
    result['managed'] = {'last_sync': r.helper._managed_sync_status()}
    json.dumps({'ok': True, 'result': result})
    assert result['managed']['last_sync']['helper_last_sync'] == {
        'at': '2026-09-20T12:00:00+00:00', 'mode': 'normal', 'action': 'normal', 'required': 'NO_CHANGES'}


@pytest.mark.parametrize('damage', ['baseline', 'binding'])
def test_renamed_type_remains_protected_when_authority_unavailable(runtime, tmp_path, damage):
    r = runtime
    manager, model, _ = configured(r, tmp_path)
    nid = add(r, model=model['name'])
    other = add(r, model='Basic (and reversed card)')
    enroll(manager)
    model = r.col.models.by_name(model['name'])
    model['name'] = 'renamed managed type'
    r.col.models.update_dict(model)
    r.col.models._clear_cache()
    if damage == 'baseline':
        next((manager.root / 'baselines').glob('*.json')).write_text('{}')
    else:
        manager.store.collection_binding = lambda: {'changed': True}
    assert manager.check()['status'] == 'unavailable'
    r.adapter.managed_guard = manager.guard
    for spec in [
        ('update_fields', {'note_id': nid, 'fields': {'Back': 'denied'}}),
        ('add_notes', {'notes': [{'model_name': model['name'], 'deck_name': 'Default',
                      'fields': {'Front': 'denied', 'Back': 'denied'}}], 'allow_duplicate': True}),
    ]:
        with pytest.raises(r.error, match='managed-model-write-blocked'):
            r.ops.prepare(*spec)
    assert r.ops.prepare('update_fields', {'note_id': other, 'fields': {'Back': 'allowed'}})['state'] == 'prepared'


def test_broken_restore_journal_only_blocks_managed_type(runtime, tmp_path):
    from anki_real_fixture.managed_runtime import ManagedRuntime
    r = runtime
    manager, model, _ = configured(r, tmp_path)
    nid = add(r, model=model['name'])
    other = add(r, model='Basic (and reversed card)')
    enroll(manager)
    (manager.root / 'restores' / ('a' * 32 + '.json')).write_text('{')
    restarted = ManagedRuntime(r.window, manager.root, manager.source, instance='fixture',
                                snapshot=manager.snapshot, restore_point=manager.restore_point,
                                sync_status=lambda: {}, ttl=600)
    assert restarted.check()['status'] == 'unavailable'
    r.adapter.managed_guard = restarted.guard
    assert r.ops.prepare('update_fields', {'note_id': other, 'fields': {'Back': 'allowed'}})['state'] == 'prepared'
    with pytest.raises(r.error, match='managed-model-write-blocked'):
        r.ops.prepare('update_fields', {'note_id': nid, 'fields': {'Back': 'denied'}})
    assert r.ops.prepare('add_tags', {'note_ids': [nid], 'tags': ['allowed']})['state'] == 'prepared'
