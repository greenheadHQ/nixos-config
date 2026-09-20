"""Read-only stored-marker inventory, using synthetic note contents only."""

import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

import pytest


SOURCE = Path(__file__).resolve().parents[2] / "modules/nixos/programs/anki-host/files/audit-note-links.py"
spec = importlib.util.spec_from_file_location("note_link_audit", SOURCE)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
A, B, MISSING = 1000000000001, 1000000000002, 1000000000099


def snapshot(*fields):
    notes = [{"noteId": A + i, "modelName": "Synthetic", "fields": field}
             for i, field in enumerate(fields)]
    return {"notes": notes, "page": {"total": len(notes)}}


def test_complete_inventory_preserves_order_locations_and_input():
    data = snapshot({"Question": f"[exists|nid{B}] [missing|nid{MISSING}]",
                     "Answer": f"[again|nid{MISSING}]"},
                    {"Question": f"[self|nid{B}] [third|nid{MISSING}]"})
    original = copy.deepcopy(data)
    report = module.audit(data)
    assert report["summary"] == {"notes_scanned": 2, "stored_markers": 5,
                                 "missing_targets": 1, "missing_occurrences": 3,
                                 "missing_source_notes": 2}
    assert report["missing_targets"] == [{"target_note_id": MISSING,
                                           "occurrences": 3, "source_note_ids": [A, B]}]
    assert [item["field_name"] for item in report["occurrences"]] == [
        "Question", "Question", "Answer", "Question", "Question"]
    for item in report["occurrences"]:
        source = data["notes"][item["source_note_id"] - A]["fields"][item["field_name"]]
        assert source[item["start"]:item["end"]] == item["raw_marker"]
    assert data == original


def test_html_entities_escaped_brackets_multiline_and_literal_markers_stay_raw():
    value = f'한글 [title <b>A &amp; B</b> \\[x]\nend|nid{MISSING}]'
    literal = f'<pre><code>[example|nid{MISSING}]</code></pre>'
    report = module.audit(snapshot({"Body": value + literal}))
    assert report["summary"]["stored_markers"] == 2
    first = report["occurrences"][0]
    assert first["title_html"] == "title <b>A &amp; B</b> [x]\nend"
    assert first["raw_marker"] == value[3:]
    assert report["occurrences"][1]["title_html"] == "example"


def test_ankiconnect_full_field_shape_and_empty_collection():
    data = snapshot({"Body": {"value": f"[yes|nid{A}]", "order": 0}})
    assert module.audit(data)["summary"]["missing_targets"] == 0
    assert module.audit(snapshot())["summary"]["stored_markers"] == 0


@pytest.mark.parametrize("text", ["[title|nid123]", "[title|nid10000000000001]",
                                  "[title|cid1000000000001]", "[title|nid1000000000001"])
def test_nonmarkers_are_ignored(text):
    assert module.audit(snapshot({"Body": text}))["occurrences"] == []


@pytest.mark.parametrize("change", [
    lambda data: data.pop("page"),
    lambda data: data["page"].update(total=3),
    lambda data: data["notes"][1].update(noteId=A),
    lambda data: data["notes"][0].update(noteId=True),
    lambda data: data["notes"][0]["fields"].update(Body=None),
])
def test_incomplete_or_invalid_input_cannot_report_missing_targets(change):
    data = snapshot({"Body": "one"}, {"Body": "two"})
    change(data)
    with pytest.raises(ValueError):
        module.audit(data)


def test_cli_private_report_no_field_contents_stdout_or_overwrite(tmp_path):
    source, output = tmp_path / "notes.json", tmp_path / "report.json"
    source.write_text(json.dumps(snapshot({"Body": f"[private title|nid{MISSING}]"})))
    command = [sys.executable, str(SOURCE), "--input", str(source), "--output", str(output)]
    first = subprocess.run(command, capture_output=True, text=True)
    assert first.returncode == 0
    assert json.loads(first.stdout)["missing_occurrences"] == 1
    assert "private title" not in first.stdout + first.stderr
    assert output.stat().st_mode & 0o777 == 0o600
    before = output.read_bytes()
    second = subprocess.run(command, capture_output=True, text=True)
    assert second.returncode == 1
    assert output.read_bytes() == before
    output.unlink()
    output.symlink_to(source)
    assert subprocess.run(command, capture_output=True).returncode == 1
    assert json.loads(source.read_text())["notes"][0]["fields"]["Body"].startswith("[private")
