"""Synthetic settings only: never read the installed 1Password data."""

import contextlib
import errno
import importlib.util
import io
import json
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / "modules/darwin/programs/onepassword/apply-shortcuts.py"
SPEC = importlib.util.spec_from_file_location("onepassword_shortcuts", SOURCE)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
DESIRED = {
    "keybinds.quickAccess": "CmdOrCtrl+Alt+Control+Space",
    "keybinds.autoFill": "CmdOrCtrl+Alt+Control+\\",
}


class ShortcutTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "settings.json"
        self.original = {
            "keybinds.quickAccess": "CmdOrCtrl+Shift+Space",
            "keybinds.autoFill": "CmdOrCtrl+\\",
            "keybinds.lock": "unchanged",
            "security.authenticatedUnlock.appleTouchId": True,
            "signedSettings": {"signature": "synthetic-signature", "version": 2},
            "unknown.future.setting": ["한글", {"enabled": False}],
        }
        self.path.write_text(json.dumps(self.original), encoding="utf-8")
        self.path.chmod(0o600)
        self.running = patch.object(MODULE, "is_app_running", return_value=False)
        self.running.start()
        self.addCleanup(self.running.stop)

    def apply(self):
        return MODULE.apply_shortcuts(self.path, DESIRED)

    def test_changes_only_two_shortcuts_and_preserves_mode(self):
        self.assertIn("applied", self.apply())
        self.assertEqual(json.loads(self.path.read_text()), self.original | DESIRED)
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)
        self.assertEqual(list(self.path.parent.iterdir()), [self.path])

    def test_second_apply_keeps_bytes_inode_and_mtime(self):
        self.apply()
        before = self.path.read_bytes(), self.path.stat().st_ino, self.path.stat().st_mtime_ns
        self.assertEqual(self.apply(), "already configured")
        self.assertEqual(before, (self.path.read_bytes(), self.path.stat().st_ino, self.path.stat().st_mtime_ns))

    def test_running_app_defers_without_rewriting(self):
        before = self.path.read_bytes()
        with patch.object(MODULE, "is_app_running", return_value=True):
            self.assertIn("deferred", self.apply())
        self.assertEqual(self.path.read_bytes(), before)

    def test_already_configured_app_does_not_need_to_quit(self):
        self.apply()
        with patch.object(MODULE, "is_app_running", side_effect=AssertionError("unneeded process probe")):
            self.assertEqual(self.apply(), "already configured")

    def test_app_started_during_write_defers_and_cleans_temporary(self):
        before = self.path.read_bytes()
        with patch.object(MODULE, "is_app_running", side_effect=[False, True]):
            self.assertIn("deferred", self.apply())
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(list(self.path.parent.iterdir()), [self.path])

    def test_missing_settings_does_not_create_unsigned_defaults(self):
        self.path.unlink()
        self.assertIn("absent", self.apply())
        self.assertFalse(self.path.exists())

    def test_invalid_json_or_non_object_remains_untouched(self):
        for payload in [b"{invalid", b"[]", b"null"]:
            with self.subTest(payload=payload):
                self.path.write_bytes(payload)
                with self.assertRaises(ValueError):
                    self.apply()
                self.assertEqual(self.path.read_bytes(), payload)

    def test_symlink_is_rejected_without_touching_target(self):
        target = self.path.with_name("target.json")
        self.path.rename(target)
        before = target.read_bytes()
        self.path.symlink_to(target)
        with self.assertRaises(ValueError):
            self.apply()
        self.assertEqual(target.read_bytes(), before)

    def test_failed_atomic_replace_preserves_original_and_cleans_temporary(self):
        before = self.path.read_bytes()
        with patch.object(MODULE.os, "replace", side_effect=PermissionError("synthetic denial")):
            with self.assertRaises(PermissionError):
                self.apply()
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(list(self.path.parent.iterdir()), [self.path])

    def test_change_observed_before_replace_is_not_overwritten(self):
        read_bytes = Path.read_bytes
        reads = 0

        def read_with_external_change(path):
            nonlocal reads
            reads += 1
            if reads == 2:
                path.write_text('{"external": true}')
            return read_bytes(path)

        with patch.object(Path, "read_bytes", read_with_external_change):
            with self.assertRaises(RuntimeError):
                self.apply()
        self.assertEqual(json.loads(self.path.read_text()), {"external": True})
        self.assertEqual(list(self.path.parent.iterdir()), [self.path])

    def test_app_probe_error_does_not_write_settings(self):
        before = self.path.read_bytes()
        with patch.object(MODULE, "is_app_running", side_effect=RuntimeError("synthetic probe failure")):
            with self.assertRaises(RuntimeError):
                self.apply()
        self.assertEqual(self.path.read_bytes(), before)

    def test_app_probe_is_scoped_to_current_user(self):
        self.running.stop()
        result = MODULE.subprocess.CompletedProcess([], 1)
        with patch.object(MODULE.subprocess, "run", return_value=result) as probe:
            self.assertFalse(MODULE.is_app_running())
        arguments = probe.call_args.args[0]
        self.assertEqual(arguments[arguments.index("-U") + 1], str(MODULE.os.getuid()))


class MainMessageTests(unittest.TestCase):
    """CLI boundary: each failure cause gets its own stderr guidance and exit code 1."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "settings.json"
        self.path.write_text(
            json.dumps({"signedSettings": {"signature": "synthetic-signature"}}), encoding="utf-8"
        )
        self.running = patch.object(MODULE, "is_app_running", return_value=False)
        self.running.start()
        self.addCleanup(self.running.stop)

    def run_main(self):
        stderr = io.StringIO()
        argv = ["apply-shortcuts.py", str(self.path), *DESIRED.values()]
        with patch.object(MODULE.sys, "argv", argv), contextlib.redirect_stderr(stderr), contextlib.redirect_stdout(
            io.StringIO()
        ):
            code = MODULE.main()
        return code, stderr.getvalue()

    def test_permission_denied_explains_terminal_app_access(self):
        denial = PermissionError(errno.EPERM, "Operation not permitted")
        with patch.object(Path, "read_bytes", side_effect=denial):
            code, message = self.run_main()
        self.assertEqual(code, 1)
        for expected in (
            "denied",
            "access data from other apps",
            "Full Disk Access",
            "launchctl procinfo $$",
            "references/tcc.md",
            "ACL",
            "launched this shell",
        ):
            self.assertIn(expected, message)
        self.assertNotIn("synthetic-signature", message)

    def test_invalid_json_is_reported_as_invalid_json(self):
        self.path.write_bytes(b"{invalid")
        code, message = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn("not valid JSON", message)
        self.assertNotIn("access data from other apps", message)

    def test_undecodable_bytes_are_reported_as_invalid_json(self):
        self.path.write_bytes(b"\xff\xfe{")
        code, message = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn("not valid JSON", message)
        self.assertNotIn("0x", message)

    def test_symlink_rejection_names_the_symlink(self):
        target = self.path.with_name("target.json")
        self.path.rename(target)
        self.path.symlink_to(target)
        code, message = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn("not a symlink", message)
        self.assertNotIn("not valid JSON", message)

    def test_non_object_settings_names_the_shape(self):
        self.path.write_bytes(b"[]")
        code, message = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn("JSON object", message)
        self.assertNotIn("not valid JSON", message)

    def test_process_probe_failure_is_reported_verbatim(self):
        probe_error = RuntimeError("could not determine whether 1Password is running")
        with patch.object(MODULE, "is_app_running", side_effect=probe_error):
            code, message = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn("could not determine whether 1Password is running", message)
        self.assertNotIn("access data from other apps", message)

    def test_change_during_apply_is_reported_verbatim(self):
        read_bytes = Path.read_bytes
        reads = 0

        def read_with_external_change(path):
            nonlocal reads
            reads += 1
            if reads == 2:
                path.write_text('{"external": true}')
            return read_bytes(path)

        with patch.object(Path, "read_bytes", read_with_external_change):
            code, message = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn("settings changed during apply", message)
        self.assertNotIn("access data from other apps", message)

    def test_other_os_errors_name_the_errno(self):
        with patch.object(Path, "read_bytes", side_effect=OSError(errno.EIO, "Input/output error")):
            code, message = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn("EIO", message)
        self.assertNotIn("access data from other apps", message)


if __name__ == "__main__":
    unittest.main()
