"""External metadata/notification failures never supply local restore authority."""
import json
import urllib.error
from contextlib import contextmanager

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
        return Response({'sha': 'a' * 40} if req.full_url.endswith('/main') else
                        {'schema_version': 1, 'digest': 'b' * 64})
    monkeypatch.setattr(managed.urllib.request, 'urlopen', request)
    result = managed.github_latest('b' * 64)
    assert result['state'] == 'available'
    assert not result['update_pending']
    assert ('a' * 40) in calls[-1]
    assert managed.github_latest('c' * 64)['update_pending']


def test_github_failure_not_local_drift(monkeypatch):
    def unavailable(*args, **kwargs):
        raise OSError('offline')
    monkeypatch.setattr(managed.urllib.request, 'urlopen', unavailable)
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
