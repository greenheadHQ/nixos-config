"""Desktop hook contract tests; native collection/Undo tests live in anki-runtime."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
ADDON = ROOT / "modules/shared/programs/anki-addons/difficulty-badge"
POLICY = ROOT / "modules/nixos/programs/anki-host/sync-addon/difficulty.py"


class DesktopBadgeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.package = Path(self.tmp.name) / "nixos-difficulty-badge"
        self.package.mkdir()
        if source := os.environ.get("ANKI_DESKTOP_DIFFICULTY_SOURCE"):
            for name in ("__init__.py", "manifest.json", "difficulty.py"):
                shutil.copyfile(Path(source) / name, self.package / name)
        else:
            shutil.copyfile(ADDON / "__init__.py", self.package / "__init__.py")
            shutil.copyfile(ADDON / "manifest.json", self.package / "manifest.json")
            shutil.copyfile(POLICY, self.package / "difficulty.py")
        self.hooks = SimpleNamespace(card_will_show=[])
        aqt = ModuleType("aqt")
        aqt.gui_hooks = self.hooks
        self.modules = patch.dict(sys.modules, {"aqt": aqt})
        self.modules.start()
        self.addCleanup(self.modules.stop)
        name = "nixos-difficulty-badge"
        spec = importlib.util.spec_from_file_location(
            name, self.package / "__init__.py", submodule_search_locations=[str(self.package)])
        self.addon = importlib.util.module_from_spec(spec)
        sys.modules[name] = self.addon
        spec.loader.exec_module(self.addon)
        self.card = SimpleNamespace(id=123, col=object(),
                                    note=lambda: SimpleNamespace(note_type=lambda: {"name": "학습 Basic"}))

    def payload(self, html):
        prefix = "<script>window.AnkiDifficultyCurrent="
        self.assertTrue(html.startswith(prefix))
        encoded, text = html[len(prefix):].split(";</script>", 1)
        self.assertEqual(text, "<div>question</div>")
        return json.loads(encoded)

    def test_hook_registered_once_and_policy_matches_host_source(self):
        self.assertEqual(self.hooks.card_will_show, [self.addon.card_will_show])
        self.assertEqual((self.package / "difficulty.py").read_bytes(), POLICY.read_bytes())
        manifest = json.loads((self.package / "manifest.json").read_text())
        self.assertEqual(manifest["package"], "nixos-difficulty-badge")

    def test_each_review_side_reads_a_fresh_payload_before_template(self):
        with patch.object(self.addon.difficulty, "card_payload", side_effect=[
                {"card_id": "123", "signals": [{"kind": "review"}]},
                {"card_id": "123", "signals": []},
                {"card_id": "456", "signals": []},
        ]) as evaluate:
            first = self.payload(self.addon.card_will_show("<div>question</div>", self.card, "reviewQuestion"))
            second = self.payload(self.addon.card_will_show("<div>question</div>", self.card, "reviewAnswer"))
            self.card.id = 456
            third = self.payload(self.addon.card_will_show("<div>question</div>", self.card, "reviewQuestion"))
        self.assertTrue(first["signals"])
        self.assertEqual(second["signals"], [])
        self.assertEqual(third["card_id"], "456")
        self.assertEqual([call.args for call in evaluate.call_args_list],
                         [(self.card.col, 123), (self.card.col, 123), (self.card.col, 456)])

    def test_preview_and_unmanaged_card_clear_previous_payload_without_evaluating(self):
        with patch.object(self.addon.difficulty, "card_payload", side_effect=AssertionError("evaluated")):
            for kind in ("previewQuestion", "previewAnswer", "clayoutQuestion", "clayoutAnswer"):
                with self.subTest(kind=kind):
                    result = self.payload(self.addon.card_will_show("<div>question</div>", self.card, kind))
                    self.assertEqual(result["signals"], [])
                    self.assertEqual(result["card_id"], "123")
            self.card.note = lambda: SimpleNamespace(note_type=lambda: {"name": "Unmanaged"})
            result = self.payload(self.addon.card_will_show("<div>question</div>", self.card, "reviewQuestion"))
            self.assertEqual(result["signals"], [])

    def test_evaluation_error_hides_badge_and_redacts_private_error_text(self):
        for error in (self.addon.difficulty.DifficultyError("invalid-reassessment-anchor"),
                      RuntimeError("private-collection-path-or-note-content")):
            with self.subTest(error=type(error).__name__), \
                    patch.object(self.addon.difficulty, "card_payload", side_effect=error), \
                    self.assertLogs(self.addon.__name__, "WARNING") as logs:
                result = self.payload(self.addon.card_will_show("<div>question</div>", self.card, "reviewAnswer"))
                self.assertEqual(result["signals"], [])
                self.assertNotIn(str(error), "\n".join(logs.output))

    def test_payload_cannot_terminate_inline_script(self):
        with patch.object(self.addon.difficulty, "card_payload", return_value={
                "card_id": "123", "signals": [], "unexpected": "</script><script>evil()&"}):
            html = self.addon.card_will_show("<div>question</div>", self.card, "reviewQuestion")
        self.assertEqual(html.count("</script>"), 1)
        self.assertNotIn("<script>evil", html)
        self.assertEqual(self.payload(html)["unexpected"], "</script><script>evil()&")


if __name__ == "__main__":
    unittest.main()
