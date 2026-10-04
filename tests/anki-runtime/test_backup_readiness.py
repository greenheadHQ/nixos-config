"""Real modern exports behind the host media gate; all collections are temporary."""
from pathlib import Path
from types import SimpleNamespace
import zipfile

import pytest
from anki._backend import RustBackend
from anki.collection import Collection

from test_real_collection import runtime


def configure_export(r):
    r.window.pm.auto_syncing_enabled = lambda: False
    r.window.pm.periodic_sync_media_minutes = lambda: 0
    r.window.media_syncer = SimpleNamespace(is_syncing=lambda: False)


@pytest.mark.parametrize('include_media', [False, True])
def test_host_export_roundtrips_real_collection_and_requested_media(runtime, tmp_path, include_media):
    r = runtime
    configure_export(r)
    note = r.col.new_note(r.col.models.by_name('Basic'))
    note['Front'], note['Back'] = 'Synthetic backup question', 'Synthetic backup answer'
    r.col.add_note(note, 1)
    media = b'Synthetic offline media bytes'
    r.col.media.write_data('fixture.txt', media)
    card = note.card_ids()[0]
    r.col.sched.set_due_date([card], '3')
    before = {table: r.col.db.all(f'select * from {table} order by id') for table in ('notes', 'cards', 'revlog')}
    target = tmp_path / 'backups' / 'fixture.colpkg'
    # Genuine Rust media status: no network thread exists for this collection.
    assert r.col.media_sync_status().active is False
    receipt = r.helper._export(str(target), include_media, False)
    assert receipt['include_media'] is include_media and receipt['legacy'] is False
    with zipfile.ZipFile(target) as package:
        assert package.testzip() is None and 'collection.anki21b' in package.namelist()
    folder = tmp_path / 'restored'
    folder.mkdir()
    backend = RustBackend()
    backend.import_collection_package(col_path=str(folder / 'collection.anki2'), backup_path=str(target),
        media_folder=str(folder / 'collection.media'), media_db=str(folder / 'collection.media.db2'))
    restored = Collection(str(folder / 'collection.anki2'), backend=backend)
    try:
        assert {table: restored.db.all(f'select * from {table} order by id') for table in before} == before
        files = {p.name: p.read_bytes() for p in Path(restored.media.dir()).iterdir() if p.is_file()}
        assert files == ({'fixture.txt': media} if include_media else {})
    finally:
        restored.close()
    assert {table: r.col.db.all(f'select * from {table} order by id') for table in before} == before


@pytest.mark.parametrize('failed_status', [True, RuntimeError('synthetic media transfer failure')])
def test_media_failure_blocks_real_export_but_allows_media_free_restore_point(runtime, tmp_path, monkeypatch, failed_status):
    r = runtime
    configure_export(r)
    before = r.helper._collection_identity()
    def status():
        if isinstance(failed_status, Exception):
            raise failed_status
        return SimpleNamespace(active=failed_status)
    # Only the external media-status response is simulated; export and reopen
    # remain the real Anki backend, including the media-free control path.
    monkeypatch.setattr(r.col, 'media_sync_status', status)
    target = tmp_path / 'backups' / 'blocked.colpkg'
    with pytest.raises(r.error, match='media-not-ready'):
        r.helper._export(str(target), True, False)
    assert not target.exists() and r.helper._collection_identity() == before
    restore = tmp_path / 'restore-points' / 'allowed.colpkg'
    r.helper._export(str(restore), False, False)
    with zipfile.ZipFile(restore) as package:
        assert package.testzip() is None and 'collection.anki21b' in package.namelist()
    assert r.helper._collection_identity() == before
