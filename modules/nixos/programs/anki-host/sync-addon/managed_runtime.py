"""Anki integration for the deliberately single-type managed ledger.

Every entry is called on the Anki main thread under the existing mutation lock.
Git supplies candidate bytes, never enrollment authority. Operator enrollment
and a conversationally confirmed, previously verified restore are distinct APIs.
"""
from __future__ import annotations

import json
import os
import re
import secrets
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from .managed_bundle import build_bundle, load_bundle, read_assets
from .managed_drift import ManagedTypeStore
from .operations import OperationError, atomic_json, digest, identifier

MODEL_NAME = "CS 재활 Basic"
GITHUB_REPOSITORY = "https://api.github.com/repos/greenheadHQ/nixos-config"
VERSION_PATH = "modules/nixos/programs/anki-host/managed-types/version.json"


def notify_drift(credential_file: Path, incident: dict) -> dict:
    """Fixed notification copy: no raw template, field, filename or private diff."""
    values = {}
    try:
        for line in credential_file.read_text().splitlines():
            if line.startswith(("PUSHOVER_TOKEN=", "PUSHOVER_USER=")):
                key, value = line.split("=", 1)
                values[key] = value.strip().strip('"').strip("'")
    except OSError:
        return {"state": "failed"}
    if not values.get("PUSHOVER_TOKEN") or not values.get("PUSHOVER_USER"):
        return {"state": "failed"}
    body = urllib.parse.urlencode({
        "token": values["PUSHOVER_TOKEN"], "user": values["PUSHOVER_USER"], "priority": "0",
        "title": "Anki 카드 형식 변경 확인 필요",
        "message": "‘CS 재활 Basic’의 카드 형식이 마지막 검증본과 달라졌습니다. "
                   "이 유형의 AI 노트 추가·내용 수정은 확인할 때까지 보류됩니다. "
                   "Anki에서 복습은 계속할 수 있습니다. LLM에게 카드 형식 상태를 확인해 달라고 요청해 주세요.",
    }).encode()
    try:
        with urllib.request.urlopen("https://api.pushover.net/1/messages.json", data=body, timeout=10) as response:
            result = json.loads(response.read(65536))
        return {"state": "sent" if result.get("status") == 1 else "failed" if result.get("status") == 0 else "unknown"}
    except urllib.error.HTTPError as error:
        try:
            return {"state": "failed" if json.loads(error.read(65536)).get("status") == 0 else "unknown"}
        except (ValueError, OSError):
            return {"state": "unknown"}
    except (OSError, ValueError):
        return {"state": "unknown"}


def github_latest(baseline_digest: str | None) -> dict:
    """A commit-bound, CI-checked content identity; network failure is independent.

    The version file is recomputed from the complete definition/assets in CI.
    SHA is provenance only: a squash or unrelated commit cannot be an update.
    This lookup neither selects a restore target nor enrolls received content.
    """
    def read(url):
        request = urllib.request.Request(url, headers={"User-Agent": "anki-managed-types", "Accept": "application/vnd.github+json"})
        with urllib.request.urlopen(request, timeout=3) as response:
            return json.loads(response.read(65536))
    try:
        commit = read(GITHUB_REPOSITORY + "/commits/main")["sha"]
        if not isinstance(commit, str) or re.fullmatch(r"[0-9a-f]{40}", commit) is None:
            raise ValueError("invalid-commit")
        version = read("https://raw.githubusercontent.com/greenheadHQ/nixos-config/" + commit + "/" + VERSION_PATH)
        content = version["digest"]
        if version.get("schema_version") != 1 or re.fullmatch(r"[0-9a-f]{64}", content) is None:
            raise ValueError("invalid-version")
        return {"state": "available", "commit": commit, "digest": content,
                "update_pending": content != baseline_digest if baseline_digest else None,
                "observed_at": time.time()}
    except (OSError, ValueError, TypeError, KeyError):
        return {"state": "unavailable", "update_pending": None, "observed_at": time.time()}


class ManagedRuntime:
    def __init__(self, window, root: Path, source: Path, *, instance, snapshot, restore_point,
                 sync_status, ttl, credential_file: Path | None = None, source_revision="unknown"):
        from .managed_restore import AnkiRestoreAdapter, ManagedRestore
        self.window, self.root, self.source = window, root, source
        self.snapshot, self.restore_point, self.ttl = snapshot, restore_point, ttl
        self.source_revision = source_revision
        self.restores = None
        self.restore_error = None
        self.store = ManagedTypeStore(root, instance=instance, collection_binding=self.binding,
                                     managed_specs=(MODEL_NAME,), observe=self.observe,
                                     last_sync=sync_status,
                                     notify=(lambda incident: notify_drift(credential_file, incident)) if credential_file else None,
                                     latest_bundle=lambda _: load_bundle(source)[0])
        self.adapter = AnkiRestoreAdapter(window)
        try:
            self.restores = ManagedRestore(root / "restores", self.store, self.adapter, restore_point,
                                           snapshot, sync_status, ttl=ttl)
        except (OSError, ValueError, KeyError, TypeError):
            # An unreadable restoration record cannot establish preservation,
            # but it must not disable unrelated types, tags or scheduling.
            self.restore_error = "managed-restore-journal-unavailable-operator-repair-required"

    def binding(self):
        col = self.window.col
        # A restored copy keeps its logical collection creation identity. A new
        # collection/profile, instance or recreated model is never auto-adopted.
        return {"profile": str(self.window.pm.name), "path": str(Path(col.path).absolute()),
                "created": col.db.scalar("select crt from col")}

    def observe(self, name, model_id, names):
        if self.restore_error:
            raise OperationError(self.restore_error)
        if self.restores is not None and self.restores.has_pending(name):
            raise OperationError("managed-restore-unverified-read-status")
        self.window.col.models._clear_cache()
        model = self.window.col.models.get(model_id)
        if model is None or model["name"] != name:
            raise OperationError("managed-model-binding-changed")
        assets = read_assets(self.window.col.media.dir(), names)
        return {"model_id": model["id"], "bundle": build_bundle(model, assets["files"]),
                "asset_bytes": assets["files"], "missing": assets["missing"]}

    def check(self, name=MODEL_NAME, *, latest=False):
        result = self.store.inspect(name)
        if latest and name == MODEL_NAME:
            result["github_latest"] = github_latest(result.get("baseline_digest"))
        return result

    def guard(self, spec):
        """Fresh all-or-nothing guard, called immediately before each field write."""
        action, params = spec["action"], spec["params"]
        if action not in ("add_notes", "update_fields", "update_fields_bulk"):
            return
        col = self.window.col
        # Target identity is a deny-only index, independent of restore authority.
        # A renamed type remains protected when its baseline or collection
        # binding is damaged. This index can never authorize a restore/register.
        targets_path = self.root / "protected-targets.json"
        try:
            targets = self.store._read(targets_path)
            model_ids = set(targets["model_ids"])
            if (set(targets) != {"model_ids"} or not model_ids
                    or any(type(mid) is not int or mid <= 0 for mid in model_ids)):
                raise ValueError("invalid-target-index")
        except FileNotFoundError:
            model_ids = set()
        except (OSError, ValueError, KeyError, TypeError):
            raise OperationError("managed-target-index-unavailable-operator-repair-required") from None
        named = col.models.by_name(MODEL_NAME)
        if named:
            model_ids.add(named["id"])
        try:
            model_ids.add(self.store.get_baseline(MODEL_NAME)["model_id"])
        except (OSError, ValueError, KeyError, TypeError):
            pass  # The current managed name is still protected before enrollment.
        if action == "add_notes":
            affected = any(note["model_name"] == MODEL_NAME or
                           (col.models.by_name(note["model_name"]) or {}).get("id") in model_ids
                           for note in params["notes"])
        else:
            updates = params["notes"] if action == "update_fields_bulk" else [params]
            affected = any(col.get_note(note["note_id"]).mid in model_ids for note in updates)
        if affected and self.check()["status"] != "normal":
            raise OperationError("managed-model-write-blocked-check-status-and-split-mixed-request")

    def enrollment_prepare(self):
        """Only the schema credential reaches this operator preview."""
        bundle, assets = load_bundle(self.source)
        col = self.window.col
        col.models._clear_cache()
        model = col.models.by_name(MODEL_NAME)
        if model is None:
            raise OperationError("managed-enrollment-model-missing")
        current = self.observe(MODEL_NAME, model["id"], list(assets))
        if current["missing"] or current["bundle"]["digest"] != bundle["digest"]:
            raise OperationError("managed-enrollment-source-does-not-match-runtime")
        operation_id = secrets.token_hex(16)
        before = self.snapshot()
        backup = self.restore_point(operation_id)
        baseline = {"model_id": model["id"], "model_name": MODEL_NAME, "bundle": bundle, "asset_bytes": assets}
        evidence = self.adapter.verify_backup(backup, baseline, self.adapter.capture(baseline))
        if evidence.get("state") != "verified":
            raise OperationError("managed-enrollment-verification-failed")
        if before != self.snapshot():
            raise OperationError("managed-enrollment-state-changed")
        record = {"operation_id": operation_id, "preview_token": secrets.token_hex(32),
                  "expires_at": time.time() + self.ttl, "snapshot": before,
                  "binding": self.binding(), "model_id": model["id"], "digest": bundle["digest"],
                  "source": {"git_revision": self.source_revision,
                             "repository": "https://github.com/greenheadHQ/nixos-config"},
                  "backup": backup, "evidence": evidence}
        atomic_json(self.root / ("enroll-" + operation_id + ".json"), record)
        return {**{k: v for k, v in record.items() if k not in ("snapshot", "binding", "evidence")},
                "verification": {key: evidence[key] for key in ("state", "anki_version", "preservation") if key in evidence}}

    def enrollment_apply(self, operation_id, preview_token, confirm):
        identifier(operation_id)
        record = self.store._read(self.root / ("enroll-" + operation_id + ".json"))
        if (confirm is not True or not isinstance(preview_token, str)
                or not secrets.compare_digest(record["preview_token"], preview_token)
                or time.time() > record["expires_at"]):
            raise OperationError("managed-enrollment-confirmation-expired-or-invalid")
        if record.get("result"):
            return record["result"]
        if record["snapshot"] != self.snapshot() or record["binding"] != self.binding():
            raise OperationError("managed-enrollment-preview-stale")
        bundle, assets = load_bundle(self.source)
        if bundle["digest"] != record["digest"]:
            raise OperationError("managed-enrollment-source-changed")
        # Persist before publishing authority. If registration is interrupted,
        # the explicitly confirmed target stays protected while unavailable.
        atomic_json(self.root / "protected-targets.json", {"model_ids": [record["model_id"]]})
        result = self.store.register_verified(MODEL_NAME, record["model_id"], bundle, assets,
                    evidence={"verification": record["evidence"], "backup": record["backup"], "source": record["source"],
                              "operator_confirmed_at": time.time()},
                    verify_registration=lambda *_: record["evidence"].get("state") == "verified"
                    and record["evidence"].get("anki_version") == self.adapter.version)
        record["result"] = result
        atomic_json(self.root / ("enroll-" + operation_id + ".json"), record)
        return result
