"""Synthetic settings only: never read the installed 1Password data."""

import importlib.util
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

    def test_concurrent_settings_change_is_not_overwritten(self):
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


if __name__ == "__main__":
    unittest.main()
