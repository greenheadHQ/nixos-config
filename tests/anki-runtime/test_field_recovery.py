"""Offline recovery from generated packages; never opens an operational profile."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat

import pytest
from anki.collection import Collection


ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(os.environ.get("ANKI_HOST_RECOVERY_SOURCE", ROOT / "modules/nixos/programs/anki-host/files/recover-fields.py"))
spec = importlib.util.spec_from_file_location("field_recovery_fixture", SOURCE)
recovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)


@pytest.fixture
def fixture(tmp_path):
    backups = tmp_path / "backups"
    backups.mkdir(mode=0o700)
    output = tmp_path / "private"
    output.mkdir(mode=0o700)
    live = tmp_path / "working"
    live.mkdir()
    col = Collection(str(live / "collection.anki2"))
    model = col.models.new("Historical field order")
    for name in ("Answer", "Question", "검토 메모"):
        col.models.add_field(model, col.models.new_field(name))
    template = col.models.new_template("Card")
    template.update(qfmt="{{Question}}", afmt="{{Answer}}")
    col.models.add_template(model, template)
    col.models.add(model)
    note = col.new_note(model)
    values = {"Answer": "old answer", "Question": "synthetic question",
              "검토 메모": "<p>한국어 메모 하나</p><p>두 번째 문단 &amp; 원문</p>"}
    for name, value in values.items():
        note[name] = value
    col.add_note(note, 1)

    def export(legacy=False):
        path = backups / ("legacy.colpkg" if legacy else "modern.colpkg")
        try:
            col.export_collection_package(out_path=str(path), include_media=False, legacy=legacy)
        finally:
            col.reopen(after_full_sync=False)
        return path

    yield col, note.id, values, export, backups, output
    col.close()


@pytest.mark.parametrize("legacy", [False, True])
def test_recovers_historical_fields_without_changing_source_or_current_collection(fixture, legacy, capfd, monkeypatch):
    col, nid, values, export, backups, output = fixture
    backup = export(legacy)
    before = backup.read_bytes()
    model = col.get_note(nid).note_type()
    col.models.rename_field(model, model["flds"][0], "Current Answer")
    col.models.reposition_field(model, model["flds"][0], 2)
    col.models.save(model)
    current = col.get_note(nid)
    current["Current Answer"] = "new answer"
    col.update_note(current)
    schedule = col.db.all("select * from cards where nid=?", nid)
    temporary = []
    extract = recovery._extract
    def checked_extract(package, directory, ids):
        assert stat.S_IMODE(package.stat().st_mode) == 0o600
        assert stat.S_IMODE(directory.stat().st_mode) == 0o700
        temporary.append(directory)
        return extract(package, directory, ids)
    monkeypatch.setattr(recovery, "_extract", checked_extract)
    result = recovery.recover_fields(backup, [nid], output / "fields.json", [backups], instance="fixture")
    saved = json.loads((output / "fields.json").read_text())
    assert saved["notes"] == [{"note_id": nid, "guid": current.guid, "model_id": current.mid,
                               "model_name": "Historical field order", "fields": values}]
    assert result == {"ok": True, "note_count": 1, "backup_sha256": hashlib.sha256(before).hexdigest()}
    assert backup.read_bytes() == before
    assert col.get_note(nid)["Current Answer"] == "new answer"
    assert col.db.all("select * from cards where nid=?", nid) == schedule
    assert stat.S_IMODE((output / "fields.json").stat().st_mode) == 0o600
    assert temporary and not temporary[0].exists()
    printed = capfd.readouterr()
    assert "old answer" not in printed.out + printed.err
    assert "한국어" not in printed.out + printed.err


def test_missing_note_fails_without_output(fixture):
    _, nid, _, export, backups, output = fixture
    backup = export()
    with pytest.raises(recovery.RecoveryError, match="note-not-in-backup"):
        recovery.recover_fields(backup, [nid, nid + 1], output / "fields.json", [backups], instance="fixture")
    assert not (output / "fields.json").exists()


def test_multiple_selected_notes_keep_requested_order(fixture):
    col, nid, values, export, backups, output = fixture
    second = col.new_note(col.get_note(nid).note_type())
    second["Question"] = "another synthetic question"
    second["Answer"] = "another old answer"
    col.add_note(second, 1)
    recovery.recover_fields(export(), [second.id, nid], output / "fields.json", [backups], instance="fixture")
    result = json.loads((output / "fields.json").read_text())
    assert [n["note_id"] for n in result["notes"]] == [second.id, nid]
    assert result["notes"][0]["fields"]["Answer"] == "another old answer"
    assert result["notes"][1]["fields"] == values


def test_corrupt_package_leaves_no_output(fixture):
    _, nid, _, _, backups, output = fixture
    broken = backups / "broken.colpkg"
    broken.write_bytes(b"not a collection package")
    with pytest.raises(Exception):
        recovery.recover_fields(broken, [nid], output / "fields.json", [backups], instance="fixture")
    assert broken.read_bytes() == b"not a collection package"
    assert not (output / "fields.json").exists()


@pytest.mark.parametrize("kind", ["existing", "symlink", "parent-symlink", "public-parent"])
def test_output_refuses_overwrite_links_and_public_directory(fixture, tmp_path, kind):
    _, nid, _, export, backups, output = fixture
    backup = export()
    target = output / "fields.json"
    protected = tmp_path / "protected"
    protected.write_text("keep")
    if kind == "existing":
        target.write_text("keep")
    elif kind == "symlink":
        target.symlink_to(protected)
    elif kind == "parent-symlink":
        link = tmp_path / "linked-output"
        link.symlink_to(output, target_is_directory=True)
        target = link / "fields.json"
    else:
        output.chmod(0o755)
    with pytest.raises(recovery.RecoveryError):
        recovery.recover_fields(backup, [nid], target, [backups], instance="fixture")
    assert protected.read_text() == "keep"
    if kind == "existing":
        assert target.read_text() == "keep"


@pytest.mark.parametrize("kind", ["live-db", "outside", "symlink", "parent-symlink", "fifo"])
def test_source_refuses_live_database_other_paths_and_nonregular_files(fixture, tmp_path, kind):
    col, nid, _, export, backups, output = fixture
    source = export()
    if kind == "live-db":
        source = Path(col.path)
    elif kind == "outside":
        other = tmp_path / "other.colpkg"
        other.write_bytes(source.read_bytes())
        source = other
    elif kind == "symlink":
        link = backups / "link.colpkg"
        link.symlink_to(source)
        source = link
    elif kind == "parent-symlink":
        link = tmp_path / "linked-backups"
        link.symlink_to(backups, target_is_directory=True)
        source = link / source.name
    else:
        source = backups / "fifo.colpkg"
        os.mkfifo(source)
    with pytest.raises(recovery.RecoveryError):
        recovery.recover_fields(source, [nid], output / "fields.json", [backups], instance="fixture")
    assert not (output / "fields.json").exists()


@pytest.mark.parametrize("ids", [[], [0], [-1], [True], [1, 1], [2**63], list(range(1, 102))])
def test_invalid_selection_fails_before_reading(tmp_path, ids):
    with pytest.raises(recovery.RecoveryError, match="invalid-note-ids"):
        recovery.recover_fields(tmp_path / "absent.colpkg", ids, tmp_path / "out.json", [], instance="fixture")


def test_failed_backend_never_discloses_error_body(fixture, monkeypatch, capfd):
    _, nid, _, export, backups, output = fixture
    backup = export()
    monkeypatch.setattr(os, "geteuid", lambda: 0)
    monkeypatch.setenv("ANKI_RECOVERY_INSTANCES", '["fixture"]')
    monkeypatch.setenv("ANKI_RECOVERY_STATE_ROOT", str(backups.parent))
    monkeypatch.setenv("ANKI_RECOVERY_DAILY_ROOT", str(backups.parent))
    monkeypatch.setenv("ANKI_RECOVERY_RESTORE_ROOT", str(backups.parent))
    def fail(*args, **kwargs):
        raise RuntimeError("PRIVATE-FIELD-CONTENT")
    monkeypatch.setattr(recovery, "recover_fields", fail)
    assert recovery.main(["--instance", "fixture", "--backup", str(backup),
                          "--note-id", str(nid), "--output", str(output / "out.json")]) == 1
    printed = capfd.readouterr()
    assert printed.out == ""
    assert json.loads(printed.err) == {"ok": False, "error": "backup-recovery-failed"}


def test_cli_requires_root_before_access(tmp_path, monkeypatch, capfd):
    monkeypatch.setattr(os, "geteuid", lambda: 65534)
    assert recovery.main(["--instance", "main", "--backup", str(tmp_path / "none.colpkg"),
                          "--note-id", "1", "--output", str(tmp_path / "out.json")]) == 1
    assert json.loads(capfd.readouterr().err)["error"] == "root-required"
