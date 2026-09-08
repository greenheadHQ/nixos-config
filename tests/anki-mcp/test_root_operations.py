"""Real temporary-file mirror/approval checks; fchown and systemctl are isolated."""
import hashlib
import importlib.util
import json
import os
import zipfile
from pathlib import Path

import pytest


@pytest.fixture
def host(monkeypatch):
    path = Path(__file__).resolve().parents[2] / 'modules/nixos/programs/anki-host/files/operations-host.py'
    spec = importlib.util.spec_from_file_location('root_operations_fixture', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    ownership = []
    monkeypatch.setattr(module.os, 'fchown', lambda fd, uid, gid: ownership.append((uid, gid)))
    module.ownership = ownership
    return module


def package(state, opid, data=b'synthetic collection'):
    root = state / 'restore-points'
    root.mkdir(parents=True, exist_ok=True)
    path = root / (opid + '.colpkg')
    with zipfile.ZipFile(path, 'w') as out:
        out.writestr('collection.anki21b', data)
    return path


def test_mirror_real_files_and_idempotency(host, tmp_path):
    state, archive = tmp_path / 'state', tmp_path / 'hdd'
    opid = 'a' * 32
    source = package(state, opid)
    host.mirror(state, archive, 'test', opid, 2, 123)
    destination = archive / 'test' / source.name
    receipt = json.loads(source.with_suffix('.receipt.json').read_text())
    assert source.read_bytes() == destination.read_bytes()
    assert receipt['sha256'] == hashlib.sha256(source.read_bytes()).hexdigest()
    assert receipt['bytes'] == source.stat().st_size and receipt['mirrored']
    assert source.with_suffix('.receipt.json').stat().st_mode & 0o777 == 0o640
    assert host.ownership == [(0, 123)]
    host.mirror(state, archive, 'test', opid, 2, 123)
    assert not list(archive.rglob('*.partial-*'))
    package(state, opid, b'different')
    with pytest.raises(ValueError, match='existing-hdd'):
        host.mirror(state, archive, 'test', opid, 2, 123)
    assert b'different' not in destination.read_bytes()


@pytest.mark.parametrize('kind', ['invalid-zip', 'wrong-entry', 'symlink'])
def test_bad_source_has_no_receipt_or_pruning(host, tmp_path, kind):
    state, archive = tmp_path / 'state', tmp_path / 'hdd'
    old = package(state, 'b' * 32)
    host.mirror(state, archive, 'test', old.stem, 1, 123)
    source = package(state, 'a' * 32)
    if kind == 'invalid-zip':
        source.write_bytes(b'not-a-package')
    elif kind == 'wrong-entry':
        with zipfile.ZipFile(source, 'w') as out:
            out.writestr('unrelated', 'bad')
    else:
        source.unlink()
        source.symlink_to(old)
    with pytest.raises((ValueError, OSError, zipfile.BadZipFile)):
        host.mirror(state, archive, 'test', source.stem, 1, 123)
    assert old.exists() and not source.with_suffix('.receipt.json').exists()
    assert not (archive / 'test' / source.name).exists()
    assert not list(archive.rglob('*.partial-*'))


def test_prune_only_verified_durable_files_after_receipt(host, tmp_path, monkeypatch):
    state, archive = tmp_path / 'state', tmp_path / 'hdd'
    old = package(state, '1' * 32)
    host.mirror(state, archive, 'test', old.stem, 5, 123)
    unmirrored = package(state, '2' * 32)
    mismatched = package(state, '3' * 32)
    host.mirror(state, archive, 'test', mismatched.stem, 5, 123)
    package(state, mismatched.stem, b'changed SSD')
    current = package(state, '4' * 32)
    actual_atomic = host.atomic_file
    def fail_receipt(*args, **kwargs):
        raise OSError('receipt failure')
    monkeypatch.setattr(host, 'atomic_file', fail_receipt)
    with pytest.raises(OSError):
        host.mirror(state, archive, 'test', current.stem, 1, 123)
    assert old.exists() and unmirrored.exists() and mismatched.exists()
    monkeypatch.setattr(host, 'atomic_file', actual_atomic)
    host.mirror(state, archive, 'test', current.stem, 1, 123)
    assert not old.exists()
    assert current.exists() and unmirrored.exists() and mismatched.exists()
    assert (archive / 'test' / old.name).exists()


@pytest.mark.parametrize('presync', ['fresh', 'same-id', 'failed', 'wrong-mode', 'wrong-action', 'deferred'])
def test_root_approval_presync_and_bound_artifact(host, tmp_path, monkeypatch, capsys, presync):
    state, keys = tmp_path / 'state', tmp_path / 'keys'
    state.mkdir(); keys.mkdir(); (state / 'approvals').mkdir()
    (keys / 'schema').write_text('a' * 64)
    status = state / 'sync-status.json'
    status.write_text(json.dumps({'runId': 'old'}))
    opid, events = 'b' * 32, []
    def call(path, payload, key, port, timeout):
        assert payload == {'operation_id': opid} and key == 'a' * 64 and port == 12345
        events.append(path)
        if path == '/operations/status':
            if len(events) > 1 and presync != 'deferred':
                return {'state': 'applied', 'sync': {'state': 'synced'}}
            return {'state': 'prepared'}
        assert path == '/schema/backup'
        return {'snapshot_digest': 'c' * 64, 'counts': {'notes': 2, 'cards': 2, 'revlog': 3},
                'baseline': {'notes': 2, 'revlog': 3}, 'operation': {'backup': {'sha256': 'd' * 64}}}
    def start(argv, check):
        assert check is True and argv[:2] == ['systemctl', 'start']
        events.append(argv[2])
        if argv[2] == 'anki-host-sync-test.service':
            status.write_text(json.dumps({'runId': 'old' if presync == 'same-id' else 'new',
                'result': 'error' if presync == 'failed' else 'success',
                'mode': 'approved-schema' if presync == 'wrong-mode' else 'normal',
                'sync': {'action': 'full-download' if presync == 'wrong-action' else 'normal'}}))
        else:
            assert argv[2] == f'anki-host-schema-test@{opid}.service'
            approval = json.loads((state / 'approvals' / (opid + '.json')).read_text())
            assert approval['snapshot_digest'] == 'c' * 64 and approval['backup_sha256'] == 'd' * 64
            assert approval['instance'] == 'test' and approval['operation_id'] == opid
            assert approval['expires_at'] == 1600 and len(approval['nonce']) == 32
    monkeypatch.setattr(host, 'helper', call)
    monkeypatch.setattr(host.subprocess, 'run', start)
    monkeypatch.setattr(host.time, 'time', lambda: 1000)
    if presync not in ('fresh', 'deferred'):
        with pytest.raises(ValueError, match='fresh-normal-presync'):
            host.approve(state, keys, 'test', opid, 123, 12345, 600, 5)
        assert events == ['/operations/status', 'anki-host-sync-test.service']
        assert not list((state / 'approvals').iterdir())
    else:
        if presync == 'deferred':
            with pytest.raises(ValueError, match='schema-operation-not-completed'):
                host.approve(state, keys, 'test', opid, 123, 12345, 600, 5)
        else:
            host.approve(state, keys, 'test', opid, 123, 12345, 600, 5)
        assert events == ['/operations/status', 'anki-host-sync-test.service', '/schema/backup',
                          f'anki-host-schema-test@{opid}.service', '/operations/status']
        assert json.loads(capsys.readouterr().out)['state'] == ('prepared' if presync == 'deferred' else 'applied')
