#!/usr/bin/env python3
"""실제 실행 파일 경계에서 SA 조회·알림 계약을 검사한다 (네트워크/실제 자격 없음)."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "modules/shared/scripts/opnix-health-check.py"


class HealthCheckTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.client = self.root / "client"
        self.client.write_text(f"#!{sys.executable}\n" + '''
import json, os, pathlib, sys, time
root = pathlib.Path(__file__).parent
calls = root / 'calls'
calls.write_text(calls.read_text() + 'call\\n' if calls.exists() else 'call\\n')
assert not any(k.startswith('OP_SESSION') for k in os.environ)
assert 'OP_CONNECT_HOST' not in os.environ and 'OP_CONNECT_TOKEN' not in os.environ
assert 'OP_ACCOUNT' not in os.environ
mode = (root / 'mode').read_text()
if mode == 'transient' and len(calls.read_text().splitlines()) == 1:
    sys.exit(1)
if mode == 'timeout':
    time.sleep(5)
if mode == 'failure':
    print('FAKE_SECRET must never reach logs', file=sys.stderr)
    sys.exit(1)
if sys.argv[1] == 'read':
    assert os.environ['OP_SERVICE_ACCOUNT_TOKEN'] == 'ops_FAKE_SECRET'
    print('' if mode == 'empty' else 'FAKE_SECRET')
else:
    assert 'OP_SERVICE_ACCOUNT_TOKEN' not in os.environ
    assert pathlib.Path(sys.argv[sys.argv.index('-token-file') + 1]).read_text().strip() == 'ops_FAKE_SECRET'
    config = json.loads(sys.argv[sys.argv.index('-config-json') + 1])
    assert config['vars'][0]['reference'] == 'op://Automation/github-pat/token'
    assert not config['vars'][0].get('optional')
    print(json.dumps({'TOKEN': '' if mode == 'empty' else 'FAKE_SECRET'}))
''')
        self.client.chmod(0o700)
        self.notify = self.root / "notify"
        self.notify.write_text(f"#!{sys.executable}\n" + '''
import json, pathlib, sys
root = pathlib.Path(__file__).parent
if (root / 'notify-fail').exists():
    sys.exit(1)
with (root / 'notifications').open('a') as f:
    f.write(json.dumps(sys.argv[1:]) + '\\n')
''')
        self.notify.chmod(0o700)
        (self.root / "token").write_text("ops_FAKE_SECRET\n")
        self.config = {
            "backend": "op", "program": str(self.client),
            "tokenFile": str(self.root / "token"),
            "stateDir": str(self.root / "state"),
            "notifier": str(self.notify), "hostLabel": "Mac",
            "reference": "op://Automation/github-pat/token",
            "timeoutSeconds": 1, "retryDelaySeconds": 0,
            "reminderSeconds": 86400,
        }

    def run_check(self, mode="success"):
        (self.root / "mode").write_text(mode)
        config = self.root / "config.json"
        config.write_text(json.dumps(self.config))
        env = dict(os.environ, OP_SERVICE_ACCOUNT_TOKEN="WRONG_TOKEN",
                   OP_CONNECT_HOST="wrong", OP_CONNECT_TOKEN="wrong",
                   OP_ACCOUNT="wrong", OP_SESSION_wrong="wrong")
        r = subprocess.run([sys.executable, str(SCRIPT), str(config)],
                           env=env, capture_output=True, text=True, timeout=3)
        self.assertNotIn("FAKE_SECRET", r.stdout + r.stderr)
        return r

    def state(self):
        return json.loads((self.root / "state/status.json").read_text())

    def notifications(self):
        path = self.root / "notifications"
        return [json.loads(x) for x in path.read_text().splitlines()] if path.exists() else []

    def test_success_is_silent_and_scrubs_environment(self):
        self.assertEqual(self.run_check().returncode, 0)
        self.assertEqual(self.notifications(), [])
        self.assertGreater(self.state()["last_success"], 0)
        self.assertEqual((self.root / "state/status.json").stat().st_mode & 0o777, 0o600)

    def test_corrupt_state_does_not_block_successful_probe(self):
        state_file = self.root / "state/status.json"
        state_file.parent.mkdir()
        cases = (b'{"FAKE_SECRET":', b'null', b'[]', b'"FAKE_SECRET"', b'\xff', b'{}')
        for index, contents in enumerate(cases, 1):
            with self.subTest(contents=contents):
                state_file.write_bytes(contents)
                result = self.run_check()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len((self.root / "calls").read_text().splitlines()), index)
                self.assertEqual(self.state()["last_result"], "ok")
                self.assertFalse(self.state()["alert_open"])
                self.assertIn("invalid local state", result.stderr)
                self.assertEqual(self.notifications(), [])
                self.assertEqual(state_file.stat().st_mode & 0o777, 0o600)
        self.assertNotIn("invalid local state", self.run_check().stderr)

    def test_invalid_state_fields_do_not_block_failure_alert(self):
        state_file = self.root / "state/status.json"
        state_file.parent.mkdir()
        baseline = {"last_success": 0, "last_checked": 0, "last_result": "unknown",
                    "alert_open": False, "last_alert_at": 0}
        cases = ({"alert_open": "false"}, {"last_result": 42},
                 {"last_alert_at": "yesterday"}, {"last_checked": None},
                 {"last_success": []}, {"last_success": True},
                 {"last_success": -1}, {"last_success": float("nan")},
                 {"last_success": 1e300})
        for index, fields in enumerate(cases, 1):
            with self.subTest(fields=fields):
                state_file.write_text(json.dumps({**baseline, **fields}))
                result = self.run_check("failure")
                self.assertEqual(result.returncode, 1)
                self.assertEqual(len((self.root / "calls").read_text().splitlines()), 2 * index)
                self.assertEqual(len(self.notifications()), index)
                self.assertEqual(self.state()["last_result"], "read_failed")
                self.assertTrue(self.state()["alert_open"])
                self.assertIn("invalid local state", result.stderr)

    def test_failure_reminder_and_recovery(self):
        self.assertEqual(self.run_check("failure").returncode, 1)
        self.assertEqual(len(self.notifications()), 1)
        self.assertIn("조회 실패", self.notifications()[0][0])
        self.assertNotIn("만료", str(self.notifications()))
        self.run_check("failure")
        self.assertEqual(len(self.notifications()), 1)
        state = self.state()
        state["last_alert_at"] = time.time() - 86401
        (self.root / "state/status.json").write_text(json.dumps(state))
        self.run_check("failure")
        self.assertEqual(len(self.notifications()), 2)
        self.assertEqual(self.run_check().returncode, 0)
        self.assertIn("복구", self.notifications()[2][0])
        self.run_check()
        self.assertEqual(len(self.notifications()), 3)

    def test_transient_failure_retries_without_alert(self):
        self.assertEqual(self.run_check("transient").returncode, 0)
        self.assertEqual(len((self.root / "calls").read_text().splitlines()), 2)
        self.assertEqual(self.notifications(), [])

    def test_timeout_is_bounded_and_named(self):
        self.config["timeoutSeconds"] = 0.15
        self.assertEqual(self.run_check("timeout").returncode, 1)
        self.assertEqual(self.state()["last_result"], "timeout")
        self.assertEqual(len(self.notifications()), 1)

    def test_failed_notification_is_retried(self):
        (self.root / "notify-fail").touch()
        self.assertEqual(self.run_check("failure").returncode, 1)
        self.assertFalse(self.state()["alert_open"])
        (self.root / "notify-fail").unlink()
        self.run_check("failure")
        self.assertEqual(len(self.notifications()), 1)
        (self.root / "notify-fail").touch()
        self.assertEqual(self.run_check().returncode, 1)
        self.assertTrue(self.state()["alert_open"])
        (self.root / "notify-fail").unlink()
        self.assertEqual(self.run_check().returncode, 0)
        self.assertEqual(len(self.notifications()), 2)

    def test_missing_token_never_falls_back_to_desktop(self):
        (self.root / "token").unlink()
        self.assertEqual(self.run_check().returncode, 1)
        self.assertFalse((self.root / "calls").exists())
        self.assertEqual(self.state()["last_result"], "credential_unavailable")

    def test_opnix_reads_the_explicit_file_and_rejects_empty_secret(self):
        self.config["backend"] = "opnix"
        self.config["hostLabel"] = "MiniPC"
        self.assertEqual(self.run_check().returncode, 0)
        self.assertEqual(self.run_check("empty").returncode, 1)
        self.assertEqual(self.state()["last_result"], "empty_result")


if __name__ == "__main__":
    unittest.main()
