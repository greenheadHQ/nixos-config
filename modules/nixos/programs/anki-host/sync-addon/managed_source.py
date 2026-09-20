"""Assemble the reviewed Git definition; never adopt a live collection.

The full HTML remains readable in Git, while exact feature-fragment checks keep
it from diverging from the planners that originally installed those features.
This module produces content only. Registration and restore authority live in
the host's separate applied-and-verified registry, not in these source files.
"""
from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path, PurePosixPath
import stat

from .card_id import _guard
from .code_highlighting import _script_json
from .managed_bundle import ManagedBundleError, build_bundle, canonical_model, filename

SOURCE_SCHEMA_VERSION = 1
MODEL_NAME = "CS 재활 Basic"
SOURCE_DIR = "managed-types/cs-rehab-basic"
VERSION_PATH = "managed-types/version.json"
_MODEL_FILES = ("model.json", "front.html", "back.html", "style.css", "manifest.json")
_FEATURE_FILES = (
    "sync-addon/card-id-button.html",
    "sync-addon/note-link-renderer.html",
    "sync-addon/code-highlight-renderer.html",
    "sync-addon/code-highlight.css",
    "code-highlighting/dist/manifest.json",
)


def _fail(reason: str) -> None:
    raise ManagedBundleError("managed-source-" + reason)


def _read(root: Path, relative: str) -> bytes:
    """Read an allowlisted repository input, rejecting links and special files.

    This is a build-time reader, not a media restore writer. Callers select the
    repository checkout; manifests cannot escape it or supply arbitrary paths.
    Bytes are decoded explicitly instead of read_text's newline normalization.
    """
    path = PurePosixPath(relative)
    if path.is_absolute() or not path.parts or any(part in (".", "..") for part in path.parts):
        _fail("unsafe-path")
    current = root
    try:
        if current.is_symlink() or not current.is_dir():
            _fail("unsafe-source-root")
        for part in path.parts:
            current = current / part
            if current.is_symlink():
                _fail("source-symlink")
        before = current.stat()
        if not stat.S_ISREG(before.st_mode) or before.st_size > 5 * 1024 * 1024:
            _fail("invalid-source-file")
        data = current.read_bytes()
        after = current.stat()
        identity = lambda value: (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns)
        if identity(before) != identity(after) or len(data) != after.st_size:
            _fail("source-changed-during-read")
        return data
    except OSError as exc:
        raise ManagedBundleError("managed-source-unavailable") from exc


def _text(root: Path, relative: str) -> str:
    try:
        return _read(root, relative).decode("utf-8")
    except UnicodeError as exc:
        raise ManagedBundleError("managed-source-invalid-utf8") from exc


def _json(root: Path, relative: str) -> dict:
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                _fail("duplicate-json-key")
            result[key] = value
        return result

    try:
        value = json.loads(_text(root, relative), object_pairs_hook=unique)
    except json.JSONDecodeError as exc:
        raise ManagedBundleError("managed-source-invalid-json") from exc
    if not isinstance(value, dict):
        _fail("invalid-json-object")
    return value


def _manifest(root: Path) -> dict:
    manifest = _json(root, SOURCE_DIR + "/manifest.json")
    if set(manifest) != {"source_schema_version", "model", "asset"}:
        _fail("unsupported-manifest")
    if (type(manifest["source_schema_version"]) is not int
            or manifest["source_schema_version"] != SOURCE_SCHEMA_VERSION
            or manifest["model"] != "model.json"):
        _fail("unsupported-manifest")
    asset = manifest["asset"]
    if not isinstance(asset, dict) or set(asset) != {"filename", "source"}:
        _fail("invalid-asset-reference")
    name = filename(asset["filename"])
    if asset["source"] != "code-highlighting/dist/" + name:
        _fail("invalid-asset-reference")
    return manifest


def source_paths(anki_host_path: str | Path) -> tuple[str, ...]:
    """Deterministic relative inputs, suitable for a pinned Git source snapshot."""
    manifest = _manifest(Path(anki_host_path))
    return tuple(sorted([
        *(SOURCE_DIR + "/" + name for name in _MODEL_FILES),
        *_FEATURE_FILES, VERSION_PATH, manifest["asset"]["source"],
    ]))


def _check_features(root: Path, definition: dict, asset_name: str) -> None:
    templates = definition["tmpls"]
    if definition["name"] != MODEL_NAME or definition["type"] != 0 or len(templates) != 1:
        _fail("unsupported-managed-model")
    front, back = templates[0]["qfmt"], templates[0]["afmt"]
    widget = _text(root, "sync-addon/card-id-button.html")
    mode, indices = definition["req"][0][1:]
    names = [definition["flds"][index]["name"] for index in indices]
    if mode not in ("any", "all") or not names:
        _fail("unsupported-card-generation")
    guarded = _guard(widget, mode, names)
    if (front.count(guarded) != 1 or "anki-cid-copy" in front.replace(guarded, "")
            or "anki-cid-copy" in back or back.count("{{FrontSide}}") != 1):
        _fail("card-id-fragment-mismatch")

    note_links = _text(root, "sync-addon/note-link-renderer.html")
    if (back.count(note_links) != 1
            or "anki-note-link-mobile-renderer" in back.replace(note_links, "")
            or "anki-note-link-mobile-renderer" in front):
        _fail("note-link-fragment-mismatch")

    renderer = _text(root, "sync-addon/code-highlight-renderer.html")
    css = _text(root, "sync-addon/code-highlight.css")
    if (renderer.count("__ANKI_SYNTAX_ASSET__") != 1
            or renderer.count("__ANKI_SYNTAX_CSS__") != 1):
        _fail("invalid-highlight-fragment")
    rendered = renderer.replace("__ANKI_SYNTAX_ASSET__", _script_json(asset_name)).replace(
        "__ANKI_SYNTAX_CSS__", _script_json(css))
    guarded_highlight = "{{#질문}}" + rendered + "{{/질문}}"
    for side in (front, back):
        if (side.count(guarded_highlight) != 1
                or "anki-code-highlight-v1" in side.replace(guarded_highlight, "")):
            _fail("highlight-fragment-mismatch")


def _assemble(anki_host_path: str | Path) -> tuple[dict, dict[str, bytes]]:
    root = Path(anki_host_path)
    manifest = _manifest(root)
    definition = copy.deepcopy(_json(root, SOURCE_DIR + "/model.json"))
    if definition.get("css") != {"file": "style.css"}:
        _fail("invalid-css-reference")
    definition["css"] = _text(root, SOURCE_DIR + "/style.css")
    templates = definition.get("tmpls")
    if not isinstance(templates, list) or len(templates) != 1 or not isinstance(templates[0], dict):
        _fail("invalid-template-reference")
    for key, name in (("qfmt", "front.html"), ("afmt", "back.html")):
        if templates[0].get(key) != {"file": name}:
            _fail("invalid-template-reference")
        templates[0][key] = _text(root, SOURCE_DIR + "/" + name)
    # Reject operational metadata in Git, rather than silently stripping it.
    if canonical_model(definition) != definition:
        _fail("operational-metadata-in-source")

    asset = manifest["asset"]
    dist_manifest = _json(root, "code-highlighting/dist/manifest.json")
    registered = dist_manifest.get("asset")
    if not isinstance(registered, dict) or registered.get("filename") != asset["filename"]:
        _fail("asset-manifest-mismatch")
    data = _read(root, asset["source"])
    if (registered.get("sha256") != hashlib.sha256(data).hexdigest()
            or type(registered.get("bytes")) is not int or registered["bytes"] != len(data)):
        _fail("asset-content-mismatch")
    _check_features(root, definition, asset["filename"])
    assets = {asset["filename"]: data}
    return build_bundle(definition, assets), assets


def generated_version(anki_host_path: str | Path) -> dict:
    """Generate the public content version after all source checks succeed."""
    bundle, _ = _assemble(anki_host_path)
    return {"schema_version": bundle["schema_version"], "digest": bundle["digest"]}


def load_checked_source(anki_host_path: str | Path) -> tuple[dict, dict[str, bytes]]:
    """Verify the complete Git source and its advertised content version."""
    bundle, assets = _assemble(anki_host_path)
    version = _json(Path(anki_host_path), VERSION_PATH)
    if (type(version.get("schema_version")) is not int or version != {
            "schema_version": bundle["schema_version"], "digest": bundle["digest"]}):
        _fail("stale-version")
    return bundle, assets


def materialize(anki_host_path: str | Path, output_path: str | Path) -> dict:
    """Build the offline bundle format into a new directory, without authority."""
    bundle, assets = load_checked_source(anki_host_path)
    output = Path(output_path)
    # Never overwrite a baseline or partially built directory implicitly.
    output.mkdir(parents=True, exist_ok=False)
    (output / "assets").mkdir()
    for name, content in assets.items():
        (output / "assets" / name).write_bytes(content)
    (output / "bundle.json").write_bytes(
        (json.dumps(bundle, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8"))
    return bundle
