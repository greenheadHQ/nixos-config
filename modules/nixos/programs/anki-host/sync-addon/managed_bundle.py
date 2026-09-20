"""Versioned content definitions, independent of deployment authority or Git SHA.

CIR/ADR #1354: a squash/rebase changes provenance, not the managed bytes. The
content digest therefore excludes native identities and timestamps. A matching
digest grants no restore permission: the caller must verify a separately stored
instance/collection/notetype binding and applied-and-verified record.

The allowlists describe Anki 26.08's native legacy model representation. New
settings fail closed instead of silently becoming unmanaged. Only qfmt, afmt and
CSS are eligible for the separately guarded remote restore path.
"""
from __future__ import annotations

import copy
import hashlib
import json
import os
from pathlib import Path
import re
import stat
from typing import Any

SCHEMA_VERSION = 1
MAX_ASSET_BYTES = 5 * 1024 * 1024
_MODEL_KEYS = frozenset({"name", "type", "sortf", "did", "tmpls", "flds", "css", "latexPre", "latexPost", "latexsvg", "req", "originalStockKind"})
_MODEL_META = frozenset({"id", "mod", "usn", "originalId"})
_FIELD_KEYS = frozenset({"name", "ord", "sticky", "rtl", "font", "size", "description", "plainText", "collapsed", "excludeFromSearch", "tag", "preventDeletion"})
_TEMPLATE_KEYS = frozenset({"name", "ord", "qfmt", "afmt", "bqfmt", "bafmt", "did", "bfont", "bsize"})
_DIGEST_RE = re.compile(r"[0-9a-f]{64}\Z")
_FILENAME_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]*\.(?:js|css)\Z")


class ManagedBundleError(ValueError):
    """Invalid or unavailable managed content; callers must not report normal."""


def _fail(reason: str) -> None:
    raise ManagedBundleError("managed-bundle-" + reason)


def _object(value: Any, required: frozenset[str], optional: frozenset[str] = frozenset()) -> dict:
    if not isinstance(value, dict) or set(value) - required - optional or required - set(value):
        _fail("unsupported-settings")
    return value


def _text(value: Any, *, nonempty: bool = False) -> None:
    if not isinstance(value, str) or (nonempty and not value):
        _fail("invalid-text")
    try:
        value.encode("utf-8")
    except UnicodeError as exc:
        raise ManagedBundleError("managed-bundle-invalid-text") from exc


def _integer(value: Any, minimum: int, maximum: int = 2**63 - 1) -> None:
    if type(value) is not int or not minimum <= value <= maximum:
        _fail("invalid-integer")


def canonical_model(native: dict) -> dict:
    """Validate a full native model and copy just explicitly managed settings.

    Native IDs identify database objects, including fields/templates, and stay in
    the independent live binding. Nonzero deck overrides are unsupported: their
    collection-local IDs cannot be treated as portable managed definitions.
    """
    _object(native, _MODEL_KEYS, _MODEL_META)
    for name in ("name", "css", "latexPre", "latexPost"):
        _text(native[name], nonempty=name == "name")
    _integer(native["type"], 0, 1)
    _integer(native["originalStockKind"], 0, 6)
    if type(native["latexsvg"]) is not bool:
        _fail("invalid-setting")
    if native["did"] is not None and (type(native["did"]) is not int or native["did"] != 0):
        _fail("unsupported-deck-override")
    fields, templates = native["flds"], native["tmpls"]
    if not isinstance(fields, list) or not fields or not isinstance(templates, list) or not templates:
        _fail("invalid-structure")
    for index, field in enumerate(fields):
        _object(field, _FIELD_KEYS, frozenset({"id"}))
        if type(field["ord"]) is not int or field["ord"] != index:
            _fail("invalid-field-order")
        for key in ("name", "font", "description"):
            _text(field[key], nonempty=key == "name")
        _integer(field["size"], 0, 2**32 - 1)
        if field["tag"] is not None:
            _integer(field["tag"], 0, 2**32 - 1)
        for key in ("sticky", "rtl", "plainText", "collapsed", "excludeFromSearch", "preventDeletion"):
            if type(field[key]) is not bool:
                _fail("invalid-field-setting")
    if len({f["name"] for f in fields}) != len(fields):
        _fail("duplicate-field")
    _integer(native["sortf"], 0, len(fields) - 1)
    for index, template in enumerate(templates):
        _object(template, _TEMPLATE_KEYS, frozenset({"id"}))
        if type(template["ord"]) is not int or template["ord"] != index:
            _fail("invalid-template-order")
        for key in ("name", "qfmt", "afmt", "bqfmt", "bafmt", "bfont"):
            _text(template[key], nonempty=key == "name")
        _integer(template["bsize"], 0, 2**32 - 1)
        if template["did"] is not None and (type(template["did"]) is not int or template["did"] != 0):
            _fail("unsupported-deck-override")
    if len({t["name"] for t in templates}) != len(templates):
        _fail("duplicate-template")
    reqs = native["req"]
    if not isinstance(reqs, list):
        _fail("invalid-generation-rules")
    seen = set()
    for req in reqs:
        if not isinstance(req, list) or len(req) != 3:
            _fail("invalid-generation-rules")
        ordinal, kind, indices = req
        _integer(ordinal, 0, len(templates) - 1)
        if ordinal in seen or kind not in ("any", "all", "none") or not isinstance(indices, list):
            _fail("invalid-generation-rules")
        seen.add(ordinal)
        for field_index in indices:
            _integer(field_index, 0, len(fields) - 1)
        if len(indices) != len(set(indices)):
            _fail("invalid-generation-rules")
    if native["type"] == 0 and seen != set(range(len(templates))):
        _fail("incomplete-generation-rules")
    result = {key: copy.deepcopy(native[key]) for key in _MODEL_KEYS}
    result["flds"] = [{key: copy.deepcopy(field[key]) for key in _FIELD_KEYS} for field in fields]
    result["tmpls"] = [{key: copy.deepcopy(template[key]) for key in _TEMPLATE_KEYS} for template in templates]
    return result


def filename(value: Any) -> str:
    if not isinstance(value, str) or not _FILENAME_RE.fullmatch(value) or len(value.encode("utf-8")) > 240 or ".." in value:
        _fail("unsafe-asset-filename")
    return value


def _json_bytes(value: Any) -> bytes:
    try:
        return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    except (TypeError, ValueError, UnicodeError) as exc:
        raise ManagedBundleError("managed-bundle-invalid-json") from exc


def build_bundle(native: dict, assets: dict[str, bytes]) -> dict:
    if not isinstance(assets, dict):
        _fail("invalid-assets")
    for name in assets:
        filename(name)
    entries = []
    for name in sorted(assets):
        value = assets[name]
        if not isinstance(value, bytes) or len(value) > MAX_ASSET_BYTES:
            _fail("invalid-asset-bytes")
        entries.append({"filename": name, "size": len(value), "sha256": hashlib.sha256(value).hexdigest()})
    body = {"schema_version": SCHEMA_VERSION, "definition": canonical_model(native), "assets": entries}
    return {**body, "digest": hashlib.sha256(_json_bytes(body)).hexdigest()}


def validate_bundle(bundle: dict, assets: dict[str, bytes] | None = None) -> None:
    _object(bundle, frozenset({"schema_version", "definition", "assets", "digest"}))
    if type(bundle["schema_version"]) is not int or bundle["schema_version"] != SCHEMA_VERSION:
        _fail("unsupported-schema")
    if canonical_model(bundle["definition"]) != bundle["definition"]:
        _fail("noncanonical-definition")
    if not isinstance(bundle["assets"], list):
        _fail("invalid-assets")
    names = []
    for asset in bundle["assets"]:
        _object(asset, frozenset({"filename", "size", "sha256"}))
        names.append(filename(asset["filename"]))
        _integer(asset["size"], 0, MAX_ASSET_BYTES)
        if not isinstance(asset["sha256"], str) or not _DIGEST_RE.fullmatch(asset["sha256"]):
            _fail("invalid-asset-hash")
    if names != sorted(set(names)):
        _fail("noncanonical-assets")
    body = {key: bundle[key] for key in ("schema_version", "definition", "assets")}
    if bundle["digest"] != hashlib.sha256(_json_bytes(body)).hexdigest():
        _fail("digest-mismatch")
    if assets is not None and build_bundle(bundle["definition"], assets) != bundle:
        _fail("asset-content-mismatch")


def structural_definition(definition: dict) -> dict:
    """Everything a limited restore must preserve, including generation rules."""
    result = canonical_model(definition)
    result.pop("css")
    for template in result["tmpls"]:
        template.pop("qfmt")
        template.pop("afmt")
    return result


def native_from_definition(current: dict, definition: dict) -> dict:
    """Materialize an already approved definition without copying foreign IDs.

    Structure must match; this function grants no authority and performs no
    writes. Keeping browser formats frozen intentionally narrows remote restore.
    """
    target = canonical_model(definition)
    if structural_definition(current) != structural_definition(target):
        _fail("restore-structure-changed")
    result = copy.deepcopy(current)
    result["css"] = target["css"]
    for destination, source in zip(result["tmpls"], target["tmpls"]):
        destination["qfmt"] = source["qfmt"]
        destination["afmt"] = source["afmt"]
    return result


def diff_bundle(expected: dict, observed: dict) -> list[str]:
    """Return safe setting paths only; original values stay in private storage."""
    validate_bundle(expected)
    validate_bundle(observed)
    changed = []

    def walk(before, after, path):
        if type(before) is not type(after):
            changed.append(path)
        elif isinstance(before, dict):
            for key in sorted(set(before) | set(after)):
                if key not in before or key not in after:
                    changed.append(path + "." + key)
                else:
                    walk(before[key], after[key], path + "." + key)
        elif isinstance(before, list):
            if len(before) != len(after):
                changed.append(path + ".length")
            for index, (a, b) in enumerate(zip(before, after)):
                walk(a, b, f"{path}[{index}]")
        elif before != after:
            changed.append(path)

    walk(expected["definition"], observed["definition"], "definition")
    old = {entry["filename"]: entry for entry in expected["assets"]}
    new = {entry["filename"]: entry for entry in observed["assets"]}
    for name in sorted(set(old) | set(new)):
        if name not in new:
            changed.append("assets." + name + ".missing")
        elif name not in old:
            changed.append("assets." + name + ".added")
        elif old[name] != new[name]:
            changed.append("assets." + name + ".content")
    return changed


def read_assets(media_dir: str | Path, names: list[str]) -> dict:
    """Read exact registered files; only an absent file is a confirmed absence.

    The directory is server-selected. A directory FD and O_NOFOLLOW prevent
    filename replacement with a symlink from escaping it; inode/mtime checks
    reject concurrent changes instead of returning a stale successful snapshot.
    """
    if not isinstance(names, list):
        _fail("invalid-asset-list")
    for name in names:
        filename(name)
    if len(names) != len(set(names)):
        _fail("invalid-asset-list")
    try:
        directory = os.open(media_dir, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError as exc:
        raise ManagedBundleError("managed-bundle-asset-directory-unavailable") from exc
    files, missing = {}, []
    try:
        for name in sorted(names):
            try:
                fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
            except FileNotFoundError:
                missing.append(name)
                continue
            except OSError as exc:
                raise ManagedBundleError("managed-bundle-asset-read-unavailable") from exc
            try:
                initial = os.fstat(fd)
                if not stat.S_ISREG(initial.st_mode) or initial.st_size > MAX_ASSET_BYTES:
                    _fail("unsafe-asset-file")
                with os.fdopen(fd, "rb", closefd=False) as stream:
                    data = stream.read(MAX_ASSET_BYTES + 1)
                final = os.fstat(fd)
                named = os.stat(name, dir_fd=directory, follow_symlinks=False)
                identity = lambda value: (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
                if identity(initial) != identity(final) or identity(final) != identity(named) or len(data) != final.st_size:
                    _fail("asset-changed-during-read")
                files[name] = data
            except OSError as exc:
                raise ManagedBundleError("managed-bundle-asset-read-unavailable") from exc
            finally:
                os.close(fd)
    finally:
        os.close(directory)
    return {"files": files, "missing": missing}


def load_bundle(source_dir: str | Path) -> tuple[dict, dict[str, bytes]]:
    """Load a materialized, reviewable bundle.json + assets/ directory.

    Source assembly belongs to the repository generator. The materialized JSON
    contains definitions and hashes only; registered bytes remain separate files.
    This same format is suitable for an offline applied-version archive.
    """
    root = Path(source_dir)
    directory = None
    descriptor = None
    try:
        directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        descriptor = os.open("bundle.json", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_size > MAX_ASSET_BYTES:
            _fail("unsafe-definition-file")
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            raw = stream.read(MAX_ASSET_BYTES + 1)
        after = os.fstat(descriptor)
        named = os.stat("bundle.json", dir_fd=directory, follow_symlinks=False)
        identity = lambda value: (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
        if identity(before) != identity(after) or identity(after) != identity(named) or len(raw) != after.st_size:
            _fail("definition-changed-during-read")

        def unique_keys(pairs):
            result = {}
            for key, value in pairs:
                if key in result:
                    _fail("duplicate-json-key")
                result[key] = value
            return result

        bundle = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_keys)
        validate_bundle(bundle)
        assets = read_assets(root / "assets", [entry["filename"] for entry in bundle["assets"]])
        if assets["missing"]:
            _fail("baseline-asset-missing")
        validate_bundle(bundle, assets["files"])
    except (OSError, json.JSONDecodeError, UnicodeError) as exc:
        raise ManagedBundleError("managed-bundle-source-unavailable") from exc
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if directory is not None:
            os.close(directory)
    return bundle, assets["files"]
