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
