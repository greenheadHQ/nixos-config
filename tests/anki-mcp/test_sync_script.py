"""Run deployed shell fragments with real jq/coreutils/flock, isolated transport.

Root/non-root branches and chown calls are simulated; this does not prove Linux
UID/DAC enforcement. No systemd, production ports or real notification transport.
"""
import json
import os
import shlex
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
HOST = ROOT / 'modules/nixos/programs/anki-host/files'


@pytest.fixture
def script(tmp_path):
    required = ['bash', 'jq', 'flock', 'date']
    binaries = {name: shutil.which(name) for name in required}
    assert all(binaries.values()), 'run through tests/run-anki-mcp-tests.sh in nix develop'
    assert subprocess.run([binaries['date'], '--iso-8601=ns'], capture_output=True).returncode == 0
    source = (ROOT / 'modules/shared/scripts/lib/pushover.sh').read_text()
    source += '\n' + (HOST / 'lib/helper-call.sh').read_text()
    # Functions take precedence over binaries: no external curl/id/chown escapes.
    source += '''
fixture_count=0
id() { [ "$1" = '-u' ] || return 99; printf '%s\\n' "$FIXTURE_UID"; }
chown() { printf '%s\\n' "$*" >> "$FIXTURE_CHOWN_LOG"; }
pushover_send() { printf 'notification\\n' >> "$FIXTURE_ALERT_LOG"; }
curl() {
  local last="${!#}" argument config=''
  for argument in "$@"; do
    if [ "$config" = next ]; then
      config="$(cat "$argument")"
      break
    fi
    [ "$argument" != --config ] || config=next
  done
  [[ "$config" == *'Authorization: Bearer '* ]] || return 99
  case "$*" in *"$FIXTURE_SECRET"*) return 99 ;; esac
  printf '%s\\n' "$last" >> "$FIXTURE_CALLS_LOG"
  case "$last" in
    http://127.0.0.1:12345/status)
      printf '%s\\n200' '{"ok":true,"result":{"collection_open":true,"login":{"status":"logged-in"}}}' ;;
    http://127.0.0.1:12345/schema/apply)
      if [ "$FIXTURE_RESULT" = lost ]; then printf 'connection reset\\n000'; return 56; fi
      printf '%s\\n200' "$FIXTURE_RESPONSE" ;;
    http://127.0.0.1:12345/sync)
      printf '%s\\n200' "$FIXTURE_RESPONSE" ;;
    *) return 99 ;;
  esac
}
'''
    # Inject jq failure only into a state-construction call; all other JSON
    # parsing and production shell logic remain real.
    source += 'jq() { if [ "${FIXTURE_FAIL_STATE:-0}" = 1 ] && [ "$1" = -n ] && [ "${2:-}" = --arg ]; then return 2; fi; '
    source += shlex.quote(binaries['jq']) + ' "$@"; }\n'
    source += (HOST / 'anki-host-sync.sh').read_text()
    path = tmp_path / 'run.sh'
    path.write_text('set -euo pipefail\numask 077\n' + source)
    state, public, credentials = (tmp_path / p for p in ('state', 'public', 'credentials'))
    for folder in (state, public, credentials):
        folder.mkdir()
    for role in ('schema', 'maintenance', 'pushover'):
        (credentials / role).write_text('a' * 64)
    env = os.environ | {'STATE_DIR': str(state), 'STATUS_RUN_DIR': str(public), 'INSTANCE': 'fixture',
        'CREDENTIALS_DIRECTORY': str(credentials), 'HELPER_PORT': '12345', 'STATE_OWNER': 'anki-host', 'STATE_GROUP': 'anki-host',
        'MAX_RETRIES': '3', 'BACKOFF_SECS': '0', 'HELPER_CURL_MAX_TIME': '1', 'READY_WAIT_TRIES': '1',
        'READY_PROBE_TIMEOUT': '1', 'READY_WAIT_SECS': '0', 'BUSY_RETRIES': '1', 'BUSY_RETRY_SECS': '0',
        'FIXTURE_UID': '0', 'FIXTURE_RESULT': 'success', 'FIXTURE_SECRET': 'a' * 64,
        'FIXTURE_CHOWN_LOG': str(tmp_path / 'chown.log'), 'FIXTURE_ALERT_LOG': str(tmp_path / 'alert.log'),
        'FIXTURE_CALLS_LOG': str(tmp_path / 'calls.log')}
    counts = {'notes': 10, 'cards': 12, 'revlog': 15, 'today_reviews_by_deck': {}}
    def run(uid, action='normal', result='success', fail_state=False):
        args = [] if uid != 0 else ['--mode', 'approved-schema', '--operation-id', 'a' * 32]
        response = {'ok': True, 'result': {'action': action, 'required': 'NO_CHANGES', 'before': counts, 'after': counts}}
        proc = subprocess.run([binaries['bash'], str(path), *args], capture_output=True, text=True,
            env=env | {'FIXTURE_UID': str(uid), 'FIXTURE_RESULT': result, 'INVOCATION_ID': f'run-{uid}-{result}',
                       'FIXTURE_RESPONSE': json.dumps(response), 'FIXTURE_FAIL_STATE': str(int(fail_state))})
        return proc
    return run, state, public, tmp_path


@pytest.mark.parametrize('result', ['success', 'blocked', 'lost'])
def test_root_then_normal_writes_and_one_shot_apply(script, result):
    run, state, public, root = script
    action = 'schema-sync-blocked' if result == 'blocked' else 'approved-full-upload'
    proc = run(0, action, result)
    assert proc.returncode == (0 if result == 'success' else 1), proc.stderr
    calls = (root / 'calls.log').read_text().splitlines()
    assert calls.count('http://127.0.0.1:12345/schema/apply') == 1
    owner_calls = (root / 'chown.log').read_text()
    assert 'anki-host:anki-host' in owner_calls and '.sync.lock' in owner_calls
    assert 'sync-status.json.partial.' in owner_calls and 'fixture.json.partial.' in owner_calls
    for path, mode in ((state / 'sync-status.json', 0o600), (public / 'fixture.json', 0o640)):
        assert path.stat().st_mode & 0o777 == mode
    assert not list(state.glob('*.partial*')) and not list(public.glob('*.partial*'))
    before = len(owner_calls)
    proc = run(1001)
    assert proc.returncode == 0, proc.stderr
    assert len((root / 'chown.log').read_text()) == before
    private = json.loads((state / 'sync-status.json').read_text())
    assert private == json.loads((public / 'fixture.json').read_text())
    assert private['runId'] == 'run-1001-success' and private['result'] == 'success'
    assert private['lastSuccessCounts'] == {'notes': 10, 'revlog': 15}


def test_failed_root_state_construction_does_not_block_next_run(script):
    run, state, public, root = script
    proc = run(0, fail_state=True)
    assert proc.returncode != 0
    assert not list(state.glob('*.partial*')) and not list(public.glob('*.partial*'))
    # A hard-killed older run can leave a private unique temporary file. The
    # subsequent run uses a different name and never tries to truncate it.
    orphan = state / 'sync-status.json.partial.oldroot'
    orphan.write_text('partial')
    orphan.chmod(0)
    try:
        assert run(1001).returncode == 0
        assert orphan.exists()
    finally:
        orphan.chmod(0o600)
