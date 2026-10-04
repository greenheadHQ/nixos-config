"""Host sync/export boundaries with real files and isolated Anki API doubles."""
import json
import os
from pathlib import Path
from types import SimpleNamespace

import pytest

from test_local_access import credentials, runtime, setup_normal_media


@pytest.mark.parametrize('contents', [
    '{"lastSuccessAt":', 'null', '[]', '{}',
    '{"lastSuccessAt":"prior","lastSuccessCounts":null}',
    '{"lastSuccessAt":null,"lastSuccessCounts":{"notes":100,"revlog":1000}}',
    '{"lastSuccessAt":"prior","lastSuccessCounts":{"notes":true,"revlog":1000}}',
    '{"lastSuccessAt":"prior","lastSuccessCounts":{"notes":-1,"revlog":1000}}',
    '{"lastSuccessAt":"prior","lastSuccessCounts":{"notes":100,"revlog":"1000"}}',
    '{"lastSuccessAt":"prior","lastSuccessCounts":{"notes":100,"revlog":1.5}}',
])
def test_invalid_prior_state_refuses_sync_before_backend(runtime, monkeypatch, contents):
    events, _ = setup_normal_media(runtime, monkeypatch, [], enabled=False)
    path = Path(runtime.STATE_DIR) / 'sync-status.json'
    path.parent.mkdir()
    path.write_text(contents)
    with pytest.raises(runtime.OperationError, match='sync-state-unavailable'):
        runtime._mutating('sync', runtime._sync, 'normal')
    assert events == []
    assert path.read_text() == contents


@pytest.mark.parametrize('counts,blocked', [({'notes': 100, 'revlog': 1000}, True),
                                         ({'notes': 2, 'revlog': 3}, False)])
def test_valid_prior_counts_enforce_loss_guard(runtime, monkeypatch, counts, blocked):
    events, _ = setup_normal_media(runtime, monkeypatch, [], enabled=False)
    path = Path(runtime.STATE_DIR) / 'sync-status.json'
    path.parent.mkdir()
    path.write_text(json.dumps({'lastSuccessAt': 'prior', 'lastSuccessCounts': counts}))
    result = runtime._mutating('sync', runtime._sync, 'normal')
    assert result['action'] == ('guard-tripped' if blocked else 'normal')
    assert events == ([] if blocked else [('collection', False)])


@pytest.mark.parametrize('contents', [None, '{"lastSuccessAt":null,"lastSuccessCounts":null}'])
def test_no_prior_success_keeps_initial_sync_available(runtime, monkeypatch, contents):
    events, _ = setup_normal_media(runtime, monkeypatch, [], enabled=False)
    if contents is not None:
        path = Path(runtime.STATE_DIR) / 'sync-status.json'
        path.parent.mkdir()
        path.write_text(contents)
    assert runtime._mutating('sync', runtime._sync, 'normal')['action'] == 'normal'
    assert events == [('collection', False)]


@pytest.mark.parametrize('failure', ['unreadable', 'directory', 'dangling-symlink'])
def test_unreadable_prior_state_is_not_an_initial_bootstrap(runtime, monkeypatch, failure):
    events, _ = setup_normal_media(runtime, monkeypatch, [], enabled=False)
    path = Path(runtime.STATE_DIR) / 'sync-status.json'
    path.parent.mkdir()
    if failure == 'unreadable':
        path.write_text('{"lastSuccessAt":"prior","lastSuccessCounts":{"notes":100,"revlog":1000}}')
        path.chmod(0)
        if os.access(path, os.R_OK):
            pytest.skip('process can bypass DAC; non-root fixture covers this case')
    elif failure == 'directory':
        path.mkdir()
    else:
        path.symlink_to(path.parent / 'missing-baseline')
    try:
        with pytest.raises(runtime.OperationError, match='sync-state-unavailable'):
            runtime._mutating('sync', runtime._sync, 'normal')
        assert events == []
    finally:
        if failure == 'unreadable':
            path.chmod(0o600)


def export_backend(runtime, statuses):
    remaining = iter(statuses)
    events = []
    def media_status():
        value = next(remaining)
        if isinstance(value, Exception):
            raise value
        return SimpleNamespace(active=value)
    def export(**args):
        events.append('export')
        Path(args['out_path']).write_bytes(b'Synthetic backend export')
    runtime.aqt.mw.col = SimpleNamespace(
        media_sync_status=media_status, export_collection_package=export,
        reopen=lambda **args: events.append('reopen'), note_count=lambda: 2, card_count=lambda: 2,
        db=SimpleNamespace(scalar=lambda *args: 0, all=lambda *args: []),
        sched=SimpleNamespace(day_cutoff=86400))
    runtime.aqt.mw.pm = SimpleNamespace(auto_syncing_enabled=lambda: False, periodic_sync_media_minutes=lambda: 0)
    runtime.aqt.mw.media_syncer = SimpleNamespace(is_syncing=lambda: False)
    runtime.aqt.mw.reset = lambda: events.append('reset')
    return events


@pytest.mark.parametrize('media', [True, RuntimeError('synthetic backend error'), False])
@pytest.mark.parametrize('include_media', [True, False])
def test_export_rechecks_media_and_preserves_media_free_restore_points(runtime, media, include_media):
    events = export_backend(runtime, [False, media])
    # A prior successful status probe cannot authorize a later media export.
    assert runtime._media_status()['active'] is False
    target = Path(runtime.STATE_DIR) / 'backups' / 'fixture.colpkg'
    if include_media and media is not False:
        with pytest.raises(runtime.OperationError, match='media-not-ready'):
            runtime._mutating('export', runtime._export, str(target), include_media, False)
        assert not target.exists() and events == []
    else:
        receipt = runtime._mutating('export', runtime._export, str(target), include_media, False)
        assert receipt['include_media'] is include_media
        assert target.read_bytes() == b'Synthetic backend export'
        assert events == ['export', 'reopen', 'reset']


def test_status_cannot_consume_a_media_error_and_make_next_export_look_ready(runtime, monkeypatch):
    events = export_backend(runtime, [RuntimeError('synthetic failed transfer'), False])
    assert runtime._media_status()['error'] == 'RuntimeError'
    target = Path(runtime.STATE_DIR) / 'backups' / 'after-status.colpkg'
    with pytest.raises(runtime.OperationError, match='media-not-ready'):
        runtime._mutating('export', runtime._export, str(target), True, False)
    assert not target.exists() and events == []

    # A new successful collection/media sync re-establishes readiness.
    setup_normal_media(runtime, monkeypatch, [False, False])
    assert runtime._mutating('sync', runtime._sync, 'normal')['media']['state'] == 'synced'
    export_backend(runtime, [False])
    assert runtime._mutating('export', runtime._export, str(target), True, False)['include_media'] is True


def test_sync_cannot_consume_a_media_error_and_make_next_export_look_ready(runtime, monkeypatch):
    setup_normal_media(runtime, monkeypatch, [False, RuntimeError('synthetic failed transfer')])
    with pytest.raises(RuntimeError, match='synthetic failed transfer'):
        runtime._mutating('sync', runtime._sync, 'normal')
    events = export_backend(runtime, [False])
    target = Path(runtime.STATE_DIR) / 'backups' / 'after-sync.colpkg'
    with pytest.raises(runtime.OperationError, match='media-not-ready'):
        runtime._mutating('export', runtime._export, str(target), True, False)
    assert not target.exists() and events == []


@pytest.mark.parametrize('monitor', ['auto', 'periodic', 'running'])
def test_media_export_requires_exclusive_helper_monitor(runtime, monitor):
    events = export_backend(runtime, [False])
    runtime.aqt.mw.pm.auto_syncing_enabled = lambda: monitor == 'auto'
    runtime.aqt.mw.pm.periodic_sync_media_minutes = lambda: 5 if monitor == 'periodic' else 0
    runtime.aqt.mw.media_syncer.is_syncing = lambda: monitor == 'running'
    target = Path(runtime.STATE_DIR) / 'backups' / 'not-exclusive.colpkg'
    with pytest.raises(runtime.OperationError, match='media-sync-monitor-not-exclusive'):
        runtime._mutating('export', runtime._export, str(target), True, False)
    assert not target.exists() and events == []
