"""Daily backup request/copy contract; transport is fake, shell/file logic is real.

Modern collection/media roundtrips use the real backend in test_field_recovery.py.
No production helper, systemd service, credentials or notifications are accessed.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import zipfile

import pytest


ROOT = Path(__file__).resolve().parents[2]
HOST = ROOT / "modules/nixos/programs/anki-host/files"


@pytest.mark.parametrize("media_active", [False, True])
def test_daily_export_requests_modern_media_and_preserves_existing_backups(tmp_path, media_active):
    assert all(shutil.which(name) for name in ("bash", "jq", "python3", "find", "stat"))
    assert subprocess.run(["stat", "--version"], capture_output=True).returncode == 0
    state = tmp_path / "state" / "fixture"
    local = state / "backups"
    destination = tmp_path / "hdd" / "fixture"
    restore = state / "restore-points"
    credentials = tmp_path / "credentials"
    for folder in (local, destination, restore, credentials):
        folder.mkdir(parents=True)
    existing = [local / "anki-host-fixture-existing.colpkg",
                destination / "anki-host-fixture-existing.colpkg", restore / "protected.colpkg"]
    for path in existing:
        path.write_bytes(b"existing backup must remain unchanged")
    fixture_package = tmp_path / "fixture.colpkg"
    with zipfile.ZipFile(fixture_package, "w") as package:
        package.writestr("fixture", b"Transport fixture only; format validated by real-engine tests.")
    (credentials / "maintenance-fixture").write_text("a" * 64)
    calls = tmp_path / "calls.jsonl"
    # Only HTTP transport is replaced. jq payload generation, ZIP integrity,
    # copy, permissions and unchanged retention all run as deployed.
    source = (HOST / "lib/helper-call.sh").read_text() + r'''
curl() {
  local last="${!#}" argument payload='' after_data=0
  for argument in "$@"; do
    if [ "$after_data" = 1 ]; then payload="$argument"; break; fi
    [ "$argument" != -d ] || after_data=1
  done
  case "$last" in
    http://127.0.0.1:12345/status)
      printf '%s\n200' '{"ok":true,"result":{"collection_open":true,"login":{"status":"not-configured"}}}' ;;
    http://127.0.0.1:12345/status/full)
      printf '{"ok":true,"result":{"media":{"active":%s}}}\n200' "$FIXTURE_MEDIA_ACTIVE" ;;
    http://127.0.0.1:12345/export)
      printf '%s\n' "$payload" | jq -c . >> "$FIXTURE_CALLS"
      cp "$FIXTURE_PACKAGE" "$(printf '%s' "$payload" | jq -r .path)"
      printf '%s\n200' '{"ok":true,"result":{}}' ;;
    *) return 99 ;;
  esac
}
pushover_send() { return 99; }
'''
    source += (HOST / "anki-host-backup.sh").read_text()
    script = tmp_path / "run.sh"
    script.write_text("set -euo pipefail\numask 077\n" + source)
    env = os.environ | {
        "INSTANCES": "fixture:12345", "STATE_ROOT": str(state.parent), "BACKUP_DIR": str(destination.parent),
        "CREDENTIALS_DIRECTORY": str(credentials), "RETENTION_DAYS": "14", "LOCAL_KEEP": "2",
        "HELPER_CURL_MAX_TIME": "1", "READY_WAIT_TRIES": "1", "READY_WAIT_SECS": "0",
        "READY_PROBE_TIMEOUT": "1", "BUSY_RETRIES": "1", "BUSY_RETRY_SECS": "0",
        "FIXTURE_MEDIA_ACTIVE": str(media_active).lower(), "FIXTURE_CALLS": str(calls),
        "FIXTURE_PACKAGE": str(fixture_package),
    }
    result = subprocess.run(["bash", str(script)], env=env, capture_output=True, text=True)
    assert result.returncode == (1 if media_active else 0), result.stderr
    for path in existing:
        assert path.read_bytes() == b"existing backup must remain unchanged"
    if media_active:
        assert not calls.exists()
        assert "media sync in progress" in result.stderr
        assert sorted(destination.iterdir()) == [existing[1]]
    else:
        requests = [json.loads(line) for line in calls.read_text().splitlines()]
        assert len(requests) == 1
        package = Path(requests[0]["path"])
        assert requests[0] == {"path": str(package), "include_media": True, "legacy": False}
        assert package.parent == local and package.suffix == ".colpkg"
        mirrored = destination / package.name
        assert package.read_bytes() == mirrored.read_bytes() == fixture_package.read_bytes()
        assert mirrored.stat().st_mode & 0o777 == 0o600
        assert not list(destination.glob("*.partial"))


@pytest.fixture
def backup_script(tmp_path):
    state, destination, credentials = (tmp_path / name for name in ('state', 'hdd', 'credentials'))
    for path in (state / 'fixture' / 'backups', state / 'healthy' / 'backups', destination, credentials):
        path.mkdir(parents=True)
    for role in ('maintenance-fixture', 'maintenance-healthy', 'pushover'):
        (credentials / role).write_text('a' * 64)
    package = tmp_path / 'fixture.colpkg'
    with zipfile.ZipFile(package, 'w') as archive:
        archive.writestr('fixture', b'Synthetic ZIP; real package verification is separate.')
    calls, alarms = tmp_path / 'calls', tmp_path / 'alarms'
    source = (HOST / 'lib/helper-call.sh').read_text() + r'''
curl() {
  local last="${!#}" argument payload='' after_data=0
  printf '%s\n' "$last" >> "$FIXTURE_CALLS"
  for argument in "$@"; do
    if [ "$after_data" = 1 ]; then payload="$argument"; break; fi
    [ "$argument" != -d ] || after_data=1
  done
  case "$last" in
    */status) printf '%s\n200' '{"ok":true,"result":{"collection_open":true,"login":{"status":"not-configured"}}}' ;;
    */status/full)
      printf '%s\n%s' "$FIXTURE_MEDIA_BODY" "$FIXTURE_MEDIA_HTTP"
      return "$FIXTURE_MEDIA_RC" ;;
    */export)
      cp "$FIXTURE_PACKAGE" "$(printf '%s' "$payload" | jq -r .path)"
      printf '%s\n200' '{"ok":true,"result":{}}' ;;
    *) return 99 ;;
  esac
}
pushover_send() { printf '%s\n' "$*" >> "$FIXTURE_ALARMS"; }
chmod() { [ "$FIXTURE_FAILURE" != chmod ] || return 1; command chmod "$@"; }
find() {
  [ "$FIXTURE_FAILURE" != prune ] || return 1
  if [ "$FIXTURE_FAILURE" = retention ] && [[ "$1" == *'/hdd/'* ]]; then return 1; fi
  command find "$@"
}
mv() { [ "$FIXTURE_FAILURE" != move ] || return 1; command mv "$@"; }
stat() { [ "$FIXTURE_FAILURE" != stat ] || return 1; command stat "$@"; }
date() { [ "$FIXTURE_FAILURE" != unexpected ] || return 1; command date "$@"; }
'''
    script = tmp_path / 'run.sh'
    script.write_text('set -euo pipefail\numask 077\n' + source + (HOST / 'anki-host-backup.sh').read_text())
    env = os.environ | {
        'INSTANCES': 'fixture:12345', 'STATE_ROOT': str(state), 'BACKUP_DIR': str(destination),
        'CREDENTIALS_DIRECTORY': str(credentials), 'RETENTION_DAYS': '14', 'LOCAL_KEEP': '2',
        'HELPER_CURL_MAX_TIME': '1', 'READY_WAIT_TRIES': '1', 'READY_WAIT_SECS': '0',
        'READY_PROBE_TIMEOUT': '1', 'BUSY_RETRIES': '1', 'BUSY_RETRY_SECS': '0',
        'FIXTURE_PACKAGE': str(package), 'FIXTURE_CALLS': str(calls), 'FIXTURE_ALARMS': str(alarms),
    }
    def run(*, failure='', body=None, http='200', rc='0', instances='fixture:12345'):
        if failure == 'mkdir':
            (destination / 'fixture').write_text('Destination is a file, not a directory.')
        return subprocess.run(['bash', str(script)], capture_output=True, text=True, env=env | {
            'FIXTURE_FAILURE': failure, 'INSTANCES': instances,
            'FIXTURE_MEDIA_BODY': body if body is not None else '{"ok":true,"result":{"media":{"active":false}}}',
            'FIXTURE_MEDIA_HTTP': http, 'FIXTURE_MEDIA_RC': rc,
        })
    return run, calls, alarms, destination


@pytest.mark.parametrize('failure', ['mkdir', 'chmod', 'prune', 'move', 'stat', 'retention', 'unexpected'])
def test_file_failure_still_sends_one_immediate_backup_alert(backup_script, failure):
    run, _calls, alarms, _destination = backup_script
    result = run(failure=failure)
    assert result.returncode == 1, result.stderr
    assert len(alarms.read_text().splitlines()) == 1
    assert 'Anki 백업 실패' in alarms.read_text()


def test_one_instance_file_failure_does_not_skip_other_backups(backup_script):
    run, _calls, alarms, destination = backup_script
    result = run(failure='mkdir', instances='fixture:12345 healthy:12346')
    assert result.returncode == 1, result.stderr
    assert len(list((destination / 'healthy').glob('*.colpkg'))) == 1
    assert len(alarms.read_text().splitlines()) == 1
    assert 'fixture(destination)' in alarms.read_text()
    assert 'healthy(' not in alarms.read_text()


@pytest.mark.parametrize('body,http,rc', [
    ('{"ok":false,"error":"unavailable"}', '503', '0'),
    ('{"ok":false,"error":"busy","busy":"sync"}', '409', '0'),
    ('connection reset', '000', '56'), ('not json', '200', '0'),
    ('{"ok":true,"result":{"media":{"active":false,"error":"NetworkError"}}}', '200', '0'),
    ('{"ok":true,"result":{"media":{"active":true}}}', '200', '0'),
    ('{"ok":true,"result":{"media":{"active":"false"}}}', '200', '0'),
    ('{"ok":true,"result":{"media":{}}}', '200', '0'),
    ('{"ok":true,"result":{}}', '200', '0'),
])
def test_media_readiness_must_be_confirmed_before_daily_export(backup_script, body, http, rc):
    run, calls, alarms, destination = backup_script
    result = run(body=body, http=http, rc=rc)
    assert result.returncode == 1, result.stderr
    assert not any(url.endswith('/export') for url in calls.read_text().splitlines())
    assert not list(destination.rglob('*.colpkg'))
    assert len(alarms.read_text().splitlines()) == 1
