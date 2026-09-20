"""External metadata/notification failures never supply local restore authority."""
import json
import urllib.error
from contextlib import contextmanager

import pytest

from anki_host_fixture import managed_runtime as managed


class Response:
    def __init__(self, data):
        self.data = json.dumps(data).encode()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass

    def read(self, limit):
        return self.data[:limit]


def test_github_commit_change_without_content_change_is_not_update(monkeypatch):
    calls = []
    def request(req, **kwargs):
        calls.append(req.full_url)
        return Response({'ref': 'refs/heads/main', 'object': {'type': 'commit', 'sha': 'a' * 40}} if req.full_url.endswith('/main') else
                        {'schema_version': 1, 'digest': 'b' * 64})
    monkeypatch.setattr(managed.urllib.request, 'urlopen', request)
    result = managed.github_latest('b' * 64)
    assert result['state'] == 'available'
    assert not result['update_pending']
    assert ('a' * 40) in calls[-1]
    assert managed.github_latest('c' * 64)['update_pending']
    assert managed.github_latest(None)['update_pending'] is None


def test_github_large_commit_uses_small_ref_and_pinned_version(monkeypatch):
    calls = []
    commit = 'a' * 40
    digest = 'b' * 64
    version_url = f'https://raw.githubusercontent.com/greenheadHQ/nixos-config/{commit}/{managed.VERSION_PATH}'
    def request(req, **kwargs):
        calls.append(req.full_url)
        if req.full_url == managed.GITHUB_REPOSITORY + '/commits/main':
            # A normal commit response grows with its patches. The old 64 KiB
            # read truncated valid JSON and reported GitHub as unavailable.
            return Response({'sha': commit, 'files': [{'patch': 'x' * 70000}]})
        if req.full_url == managed.GITHUB_REPOSITORY + '/git/ref/heads/main':
            return Response({'ref': 'refs/heads/main', 'object': {'type': 'commit', 'sha': commit}})
        assert req.full_url == version_url
        return Response({'schema_version': 1, 'digest': digest})
    monkeypatch.setattr(managed.urllib.request, 'urlopen', request)
    result = managed.github_latest(digest)
    assert result['state'] == 'available'
    assert result['commit'] == commit
    assert result['digest'] == digest
    assert result['update_pending'] is False
    assert calls == [managed.GITHUB_REPOSITORY + '/git/ref/heads/main', version_url]


@pytest.mark.parametrize('reference', [
    {'ref': 'refs/heads/other', 'object': {'type': 'commit', 'sha': 'a' * 40}},
    {'ref': 'refs/heads/main', 'object': {'type': 'tag', 'sha': 'a' * 40}},
    {'ref': 'refs/heads/main', 'object': {'type': 'commit', 'sha': '../main'}},
    {'ref': 'refs/heads/main', 'object': {'type': 'commit', 'sha': None}},
    {'ref': 'refs/heads/main', 'object': None},
    {}, [], None,
])
def test_github_invalid_ref_is_unavailable_without_version_fetch(monkeypatch, reference):
    calls = []
    def request(req, **kwargs):
        calls.append(req.full_url)
        return Response(reference)
    monkeypatch.setattr(managed.urllib.request, 'urlopen', request)
    result = managed.github_latest('b' * 64)
    assert result['state'] == 'unavailable'
    assert result['update_pending'] is None
    assert len(calls) == 1


def test_github_failure_not_local_drift(monkeypatch):
    def unavailable(*args, **kwargs):
        raise OSError('offline')
    monkeypatch.setattr(managed.urllib.request, 'urlopen', unavailable)
    result = managed.github_latest('b' * 64)
    assert result['state'] == 'unavailable'
    assert result['update_pending'] is None


@pytest.mark.parametrize('failure', ['network', 'oversized-json'])
def test_github_version_failure_never_reuses_ref_as_content_version(monkeypatch, failure):
    def request(req, **kwargs):
        if req.full_url.endswith('/git/ref/heads/main'):
            return Response({'ref': 'refs/heads/main', 'object': {'type': 'commit', 'sha': 'a' * 40}})
        if failure == 'network':
            raise urllib.error.URLError('version unavailable')
        return Response({'schema_version': 1, 'digest': 'b' * 64, 'padding': 'x' * 70000})
    monkeypatch.setattr(managed.urllib.request, 'urlopen', request)
    result = managed.github_latest('b' * 64)
    assert result['state'] == 'unavailable'
    assert result['update_pending'] is None


def test_notification_is_safe_and_uncertain_delivery_is_not_failed(monkeypatch, tmp_path):
    secret = tmp_path / 'credential'
    secret.write_text('PUSHOVER_TOKEN=token\nPUSHOVER_USER=user\n')
    captured = []
    def send(url, data, **kwargs):
        captured.append(data.decode())
        raise TimeoutError('lost response')
    monkeypatch.setattr(managed.urllib.request, 'urlopen', send)
    outcome = managed.notify_drift(secret, {'raw': 'PRIVATE', 'changed_paths': ['PRIVATE']})
    assert outcome == {'state': 'unknown'}
    assert 'PRIVATE' not in captured[0]
    monkeypatch.setattr(managed.urllib.request, 'urlopen', lambda *a, **kw: Response({'status': 1}))
    assert managed.notify_drift(secret, {}) == {'state': 'sent'}
    monkeypatch.setattr(managed.urllib.request, 'urlopen', lambda *a, **kw: Response({'status': 0}))
    assert managed.notify_drift(secret, {}) == {'state': 'failed'}
