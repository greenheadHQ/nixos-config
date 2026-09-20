import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "manage", ROOT / "modules/shared/programs/anki-addons/manage.py"
)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class AddonsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.manager = m.Manager(self.root / "Anki2")
        self.source = self.root / "source"
        self.source.mkdir()
        (self.source / "__init__.py").write_text("version = 1\n")
        (self.source / "config.json").write_text('{"color": "default"}')
        self.manifest = {"123": {"source": str(self.source), "name": "Fixture",
                                 "mod": 1, "config": {"color": "red"}, "enabled": True}}
        self.closed = patch.object(m, "running_anki", return_value=False)
        self.closed.start()
        self.addCleanup(self.closed.stop)

    def apply(self, manifest=None):
        with self.manager.lock():
            self.manager.apply(self.manifest if manifest is None else manifest)

    def seed(self):
        addon = self.manager.target / "123"
        (addon / "user_files").mkdir(parents=True)
        (addon / "user_files/state.db").write_bytes(b"precious state")
        (addon / "__init__.py").write_text("old version")
        m.write_json(addon / "meta.json", {"config": {"color": "blue", "runtime": 42},
                                           "custom_meta": True})
        (self.manager.target / "999").mkdir()
        (self.manager.target / "999/__init__.py").write_text("unmanaged")
        (self.manager.base / "collection.anki2").write_bytes(b"do not touch")
        return addon

    def test_adoption_preserves_runtime_unmanaged_and_collection(self):
        addon = self.seed()
        before = m.fingerprint(self.manager.target)
        self.apply()
        meta = m.read_json(addon / "meta.json")
        self.assertEqual(meta["config"], {"color": "red", "runtime": 42})
        self.assertTrue(meta["custom_meta"])
        self.assertFalse(meta["update_enabled"])
        self.assertFalse(meta["disabled"])
        self.assertEqual((addon / "user_files/state.db").read_bytes(), b"precious state")
        self.assertEqual((self.manager.target / "999/__init__.py").read_text(), "unmanaged")
        self.assertEqual((self.manager.base / "collection.anki2").read_bytes(), b"do not touch")
        snapshots = [p for p in self.manager.state.iterdir() if p.is_dir()]
        self.assertEqual(len(snapshots), 1)
        self.assertEqual(m.fingerprint(snapshots[0]), before)

    def test_idempotent_no_new_backup_or_target_replacement(self):
        self.apply()
        inode = self.manager.target.stat().st_ino
        before = list(self.manager.state.iterdir())
        self.apply()
        self.assertEqual(self.manager.target.stat().st_ino, inode)
        self.assertEqual(list(self.manager.state.iterdir()), before)

    def test_upgrade_removes_obsolete_code_but_keeps_runtime(self):
        (self.source / "obsolete.py").write_text("old")
        self.apply()
        addon = self.manager.target / "123"
        (addon / "runtime.json").write_text("keep")
        (self.source / "obsolete.py").unlink()
        (self.source / "__init__.py").write_text("version = 2")
        self.apply()
        self.assertFalse((addon / "obsolete.py").exists())
        self.assertEqual((addon / "runtime.json").read_text(), "keep")
        self.assertEqual((addon / "__init__.py").read_text(), "version = 2")

    def test_removing_declared_setting_reverts_to_package_default(self):
        self.seed()
        self.apply()
        self.manifest["123"]["config"] = {}
        self.apply()
        meta = m.read_json(self.manager.target / "123/meta.json")
        self.assertEqual(meta["config"], {"runtime": 42})

    def test_user_files_seed_only_and_disabled(self):
        addon = self.seed()
        (self.source / "user_files").mkdir()
        (self.source / "user_files/state.db").write_bytes(b"default")
        (self.source / "user_files/new.txt").write_text("new")
        self.manifest["123"]["enabled"] = False
        self.apply()
        self.assertEqual((addon / "user_files/state.db").read_bytes(), b"precious state")
        self.assertEqual((addon / "user_files/new.txt").read_text(), "new")
        self.assertTrue(m.read_json(addon / "meta.json")["disabled"])

    def test_remove_only_owned_and_restore_exact_tree(self):
        self.seed()
        self.apply()
        before = m.fingerprint(self.manager.target)
        self.apply({})
        self.assertFalse((self.manager.target / "123").exists())
        self.assertTrue((self.manager.target / "999").exists())
        backup = next(p for p in self.manager.state.iterdir()
                      if p.is_dir() and (p / m.MARKER).exists())
        with self.manager.lock():
            self.manager.restore(backup.name)
        self.assertEqual(m.fingerprint(self.manager.target), before)
        self.assertTrue(backup.exists())

    def test_executable_helpers_survive_apply_and_restore(self):
        addon = self.seed()
        helpers = [addon / "user_files/helper", self.manager.target / "999/helper"]
        for helper in helpers:
            helper.write_text("#!/bin/sh\nexit 0\n")
            helper.chmod(0o700)
        (self.source / "helper").write_text("#!/bin/sh\nexit 0\n")
        (self.source / "helper").chmod(0o755)
        self.apply()
        for helper in [*helpers, addon / "helper"]:
            self.assertTrue(os.access(helper, os.X_OK))
        backup = next(p for p in self.manager.state.iterdir() if p.is_dir())
        with self.manager.lock():
            self.manager.restore(backup.name)
        for helper in helpers:
            self.assertTrue(os.access(helper, os.X_OK))

    def test_source_executable_bit_change_is_applied(self):
        (self.source / "helper").write_text("#!/bin/sh\nexit 0\n")
        (self.source / "helper").chmod(0o644)
        self.apply()
        target = self.manager.target / "123/helper"
        self.assertFalse(os.access(target, os.X_OK))
        (self.source / "helper").chmod(0o755)
        self.apply()
        self.assertTrue(os.access(target, os.X_OK))

    def test_stage_error_leaves_original_untouched(self):
        self.seed()
        before = m.fingerprint(self.manager.target)
        self.manifest["124"] = dict(self.manifest["123"], source="/missing")
        with self.assertRaises(ValueError):
            self.apply()
        self.assertEqual(m.fingerprint(self.manager.target), before)
        self.assertFalse(self.manager.journal.exists())

    def test_rename_failure_restores_original(self):
        self.seed()
        before = m.fingerprint(self.manager.target)
        rename = Path.rename

        def fail_stage(path, target):
            if path.parent.name.startswith("stage-"):
                raise OSError("simulated disk failure")
            return rename(path, target)

        with patch.object(Path, "rename", fail_stage), self.assertRaises(OSError):
            self.apply()
        self.assertEqual(m.fingerprint(self.manager.target), before)
        self.assertFalse(self.manager.journal.exists())

    def test_interrupted_swap_requires_explicit_recovery(self):
        self.seed()
        before = m.fingerprint(self.manager.target)
        with self.manager.lock():
            backup = "a" * 32
            self.manager.target.rename(self.manager.state / backup)
            m.write_json(self.manager.journal, {"backup": backup, "had_target": True})
            with self.assertRaisesRegex(RuntimeError, "recover"):
                self.manager.apply(self.manifest)
            self.manager.recover()
        self.assertEqual(m.fingerprint(self.manager.target), before)

    def test_recovery_preserves_installed_tree_as_another_backup(self):
        self.seed()
        with self.manager.lock():
            backup = "a" * 32
            m.copy_writable(self.manager.target, self.manager.state / backup)
            (self.manager.target / "123/__init__.py").write_text("new")
            m.write_json(self.manager.journal, {"backup": backup, "had_target": True})
            self.manager.recover()
        self.assertEqual((self.manager.target / "123/__init__.py").read_text(), "old version")
        self.assertTrue(any((p / "123/__init__.py").read_text() == "new"
                            for p in self.manager.state.iterdir() if p.is_dir()))

    def test_invalid_id_or_owned_path_cannot_escape(self):
        self.seed()
        before = m.fingerprint(self.manager.target)
        with self.assertRaises(ValueError):
            self.apply({"../escape": self.manifest["123"]})
        self.assertEqual(m.fingerprint(self.manager.target), before)
        m.write_json(self.manager.target / m.MARKER,
                     {"123": {"files": ["../../collection.anki2"], "config_keys": []}})
        with self.assertRaises(ValueError):
            self.apply()
        self.assertEqual((self.manager.base / "collection.anki2").read_bytes(), b"do not touch")

    def test_symlink_rejected_without_touching_destination(self):
        addon = self.seed()
        outside = self.root / "outside"
        outside.write_text("keep")
        (addon / "link").symlink_to(outside)
        with self.assertRaises(ValueError):
            self.apply()
        self.assertEqual(outside.read_text(), "keep")

    def test_second_manager_cannot_enter_lock(self):
        with self.manager.lock(), self.assertRaises(BlockingIOError):
            with self.manager.lock():
                pass

    def test_running_anki_blocks_final_swap(self):
        self.seed()
        before = m.fingerprint(self.manager.target)
        with patch.object(m, "running_anki", return_value=True), self.assertRaises(RuntimeError):
            self.apply()
        self.assertEqual(m.fingerprint(self.manager.target), before)

    def test_cli_defers_for_real_named_process_without_creating_base(self):
        # Exercise ps/CLI together, always against a disposable base. Never use
        # the installed wrapper's live default directory to test deferral.
        binary = self.root / "Anki"
        shutil.copyfile("/bin/sleep", binary)
        binary.chmod(0o700)
        proc = subprocess.Popen([str(binary), "30"])
        try:
            manifest = self.root / "manifest.json"
            m.write_json(manifest, self.manifest)
            result = subprocess.run(
                [sys.executable, str(ROOT / "modules/shared/programs/anki-addons/manage.py"),
                 "--manifest", str(manifest), "--base", str(self.manager.base),
                 "apply", "--defer-if-running"],
                text=True, capture_output=True, timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("deferred", result.stdout)
            self.assertFalse(self.manager.base.exists())
        finally:
            proc.terminate()
            proc.wait(timeout=5)

    def test_process_detection_avoids_test_runner_false_positive(self):
        uid = os.getuid()
        # Temporarily remove the fixture mock to exercise the actual parser.
        self.closed.stop()
        for command in ["/Applications/Anki.app/Contents/MacOS/Anki",
                        "/Applications/A path with spaces/Anki"]:
            with patch.object(m.subprocess, "check_output", return_value=f"{uid} 1 {command}\n"):
                self.assertTrue(m.running_anki())
        for args, expected in [("python /store/bin/anki -b /tmp/test", True),
                               ("python -m aqt", True),
                               ("python -m pytest tests/anki-addons", False)]:
            with patch.object(m.subprocess, "check_output", side_effect=[
                f"{uid} 1 /bin/bash\n{uid} 2 /bin/python\n",
                f"{uid} 1 bash tests/anki-addons/run.sh\n{uid} 2 {args}\n",
            ]) as ps:
                self.assertEqual(m.running_anki(), expected)
                self.assertEqual(ps.call_args_list[0].args[0][-1], "uid=,pid=,comm=")
        self.closed.start()


if __name__ == "__main__":
    unittest.main()
