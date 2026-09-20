"""Reviewed full templates must agree with feature sources and public version."""
import json
from pathlib import Path
import shutil
import subprocess
import sys

import pytest

from anki_host_fixture.managed_bundle import ManagedBundleError, load_bundle
from anki_host_fixture.managed_source import (
    SOURCE_DIR, VERSION_PATH, generated_version, load_checked_source,
    materialize, source_paths,
)

HOST = Path(__file__).resolve().parents[2] / "modules/nixos/programs/anki-host"


@pytest.fixture
def source(tmp_path):
    result = tmp_path / "source"
    shutil.copytree(HOST, result, ignore=shutil.ignore_patterns("__pycache__", "node_modules"))
    return result


def write_json(path, value):
    path.write_bytes((json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))


def refresh(root):
    write_json(root / VERSION_PATH, generated_version(root))


def test_git_source_has_full_ordered_definition_and_no_operational_identity():
    bundle, assets = load_checked_source(HOST)
    definition = bundle["definition"]
    assert definition["name"] == "CS 재활 Basic"
    assert [field["name"] for field in definition["flds"]] == ["질문", "답", "맥락", "설명", "출처", "검토 메모"]
    assert definition["req"] == [[0, "any", [0, 2]]]
    assert len(definition["tmpls"]) == 1
    assert len(assets) == 1
    for value in [definition, *definition["flds"], *definition["tmpls"]]:
        assert not {"id", "mod", "usn", "originalId"} & value.keys()
    assert definition["css"] == (HOST / SOURCE_DIR / "style.css").read_bytes().decode("utf-8")
    for key, name in (("qfmt", "front.html"), ("afmt", "back.html")):
        assert definition["tmpls"][0][key] == (HOST / SOURCE_DIR / name).read_bytes().decode("utf-8")
    assert generated_version(HOST) == json.loads((HOST / VERSION_PATH).read_bytes())


def test_build_round_trip_preserves_definition_and_actual_asset_bytes(source, tmp_path):
    expected, assets = load_checked_source(source)
    output = tmp_path / "built"
    assert materialize(source, output) == expected
    assert load_bundle(output) == (expected, assets)
    with pytest.raises(FileExistsError):
        materialize(source, output)
    assert load_bundle(output) == (expected, assets)


def test_source_inventory_is_sorted_exact_and_excludes_unmanaged_assets():
    paths = source_paths(HOST)
    assert paths == tuple(sorted(set(paths)))
    assert len(paths) == 12
    assert VERSION_PATH in paths
    assert all((HOST / path).is_file() for path in paths)
    assert not any(".license.txt" in path or "node_modules" in path for path in paths)


def test_unrelated_git_files_and_provenance_do_not_change_content(source):
    original = load_checked_source(source)
    (source / "unrelated.md").write_text("new commit\n", encoding="utf-8")
    (source / "REVISION").write_text("a" * 40, encoding="utf-8")
    assert load_checked_source(source) == original


def test_source_changes_require_explicit_version_refresh_and_preserve_line_endings(source):
    original = load_checked_source(source)[0]
    style = source / SOURCE_DIR / "style.css"
    style.write_bytes(style.read_bytes().replace(b"\n", b"\r\n"))
    with pytest.raises(ManagedBundleError, match="stale-version"):
        load_checked_source(source)
    refresh(source)
    changed = load_checked_source(source)[0]
    assert changed["digest"] != original["digest"]
    assert "\r\n" in changed["definition"]["css"]


@pytest.mark.parametrize("change", [
    {"schema_version": True}, {"schema_version": 2}, {"digest": "0" * 64},
    {"git_sha": "a" * 40},
])
def test_version_requires_exact_schema_and_digest_without_git_provenance(source, change):
    path = source / VERSION_PATH
    value = json.loads(path.read_bytes())
    value.update(change)
    write_json(path, value)
    with pytest.raises(ManagedBundleError, match="stale-version"):
        load_checked_source(source)


@pytest.mark.parametrize("relative,reason", [
    ("sync-addon/card-id-button.html", "card-id-fragment-mismatch"),
    ("sync-addon/note-link-renderer.html", "note-link-fragment-mismatch"),
    ("sync-addon/code-highlight-renderer.html", "highlight-fragment-mismatch"),
    ("sync-addon/code-highlight.css", "highlight-fragment-mismatch"),
])
def test_feature_source_change_cannot_silently_leave_full_template_stale(source, relative, reason):
    path = source / relative
    path.write_bytes(path.read_bytes() + b"\n")
    with pytest.raises(ManagedBundleError, match=reason):
        generated_version(source)


@pytest.mark.parametrize("name,old,new,reason", [
    ("front.html", "function validCardId", "function changedValidCardId", "card-id-fragment-mismatch"),
    ("back.html", "const inline =", "const inlineChanged =", "note-link-fragment-mismatch"),
    ("back.html", "ignoreIllegals: true", "ignoreIllegals: false", "highlight-fragment-mismatch"),
    ("front.html", "{{^질문}}{{#맥락}}", "{{#맥락}}", "card-id-fragment-mismatch"),
])
def test_full_template_cannot_silently_fork_feature_or_generation_guards(source, name, old, new, reason):
    path = source / SOURCE_DIR / name
    path.write_bytes(path.read_bytes().replace(old.encode(), new.encode()))
    with pytest.raises(ManagedBundleError, match=reason):
        generated_version(source)


def test_coordinated_feature_and_full_template_update_can_be_reviewed(source):
    original = load_checked_source(source)[0]
    feature = source / "sync-addon/note-link-renderer.html"
    old = feature.read_bytes()
    new = old.replace(b"const inline =", b"/* reviewed */ const inline =")
    feature.write_bytes(new)
    back = source / SOURCE_DIR / "back.html"
    back.write_bytes(back.read_bytes().replace(old, new))
    refresh(source)
    assert load_checked_source(source)[0]["digest"] != original["digest"]


@pytest.mark.parametrize("mutation,reason", [
    (lambda model: model.update(id=123), "operational-metadata-in-source"),
    (lambda model: model["flds"][0].update(id=123), "operational-metadata-in-source"),
    (lambda model: model["tmpls"][0].update(id=123), "operational-metadata-in-source"),
    (lambda model: model.update(futureSetting=True), "unsupported-settings"),
    (lambda model: model.update(css={"file": "../../private.css"}), "invalid-css-reference"),
    (lambda model: model["tmpls"][0].update(qfmt={"file": "/tmp/private.html"}), "invalid-template-reference"),
])
def test_metadata_and_arbitrary_source_paths_are_rejected(source, mutation, reason):
    path = source / SOURCE_DIR / "model.json"
    model = json.loads(path.read_bytes())
    mutation(model)
    write_json(path, model)
    with pytest.raises(ManagedBundleError, match=reason):
        generated_version(source)


@pytest.mark.parametrize("filename,relative", [
    ("../secret.js", "code-highlighting/dist/../secret.js"),
    ("_safe.js", "/tmp/secret.js"),
    ("_safe.js", "code-highlighting/dist/../secret.js"),
    ("private.png", "code-highlighting/dist/private.png"),
])
def test_manifest_cannot_read_arbitrary_files(source, filename, relative):
    path = source / SOURCE_DIR / "manifest.json"
    manifest = json.loads(path.read_bytes())
    manifest["asset"] = {"filename": filename, "source": relative}
    write_json(path, manifest)
    with pytest.raises(ManagedBundleError):
        generated_version(source)


def test_registered_asset_bytes_and_name_must_match_build_manifest(source):
    manifest = json.loads((source / SOURCE_DIR / "manifest.json").read_bytes())
    asset = source / manifest["asset"]["source"]
    asset.write_bytes(asset.read_bytes() + b"\n")
    with pytest.raises(ManagedBundleError, match="asset-content-mismatch"):
        generated_version(source)


def test_source_symlinks_missing_files_invalid_json_and_duplicate_keys_fail_closed(source, tmp_path):
    path = source / SOURCE_DIR / "style.css"
    original = path.read_bytes()
    other = tmp_path / "outside.css"
    other.write_bytes(original)
    path.unlink()
    path.symlink_to(other)
    with pytest.raises(ManagedBundleError, match="source-symlink"):
        generated_version(source)
    path.unlink()
    with pytest.raises(ManagedBundleError, match="unavailable"):
        generated_version(source)
    path.write_bytes(original)
    manifest = source / SOURCE_DIR / "manifest.json"
    manifest.write_bytes(b'{"source_schema_version":1,"source_schema_version":1}')
    with pytest.raises(ManagedBundleError, match="duplicate-json-key"):
        generated_version(source)
    manifest.write_bytes(b'{')
    with pytest.raises(ManagedBundleError, match="invalid-json"):
        generated_version(source)


def test_materializer_cli_needs_no_anki_or_qt_import(source, tmp_path):
    output = tmp_path / "cli-output"
    result = subprocess.run([sys.executable, "-B", str(source / "managed-types/build.py"),
                             str(source), str(output)], check=True, capture_output=True, text=True)
    assert result.stdout.strip() == load_bundle(output)[0]["digest"]
