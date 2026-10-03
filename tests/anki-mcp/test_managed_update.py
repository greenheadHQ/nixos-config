"""Root source updates: exact authority, interruption and delivery boundaries."""
import copy
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path

import pytest

from anki_host_fixture.managed_bundle import build_bundle, canonical_model, native_from_definition
from anki_host_fixture.managed_drift import ManagedDriftError, ManagedTypeStore
from anki_host_fixture.managed_runtime import ManagedRuntime
from anki_host_fixture.managed_update import ManagedUpdate, native_from_update
from anki_host_fixture.operations import OperationError, digest
from test_managed_drift import NAME, native

OP = "a" * 32
NEXT = "b" * 32


def model():
    value = native()
    history = copy.deepcopy(value["flds"][1])
    history.update(name="노트 변천사", ord=2, id=12)
    value["flds"].append(history)
    return value


class Adapter:
    version = "test-anki"

    def __init__(self):
        self.model = model()
        self.assets = {"_managed.js": b"old registered content", "personal.png": b"private personal media"}
        self.rows = {"notes": [[1, "private body", "marked", "memo\n\nparagraph", "history"]],
                     "cards": [[9, 1, 30, 5, 2500, 4]], "revlog": [[10, 9, 3]]}
        self.calls = 0
        self.registered = True
        self.stage = None
        self.crash = False
        self.clone_fails = False

    def materialize(self, current, definition):
        return native_from_update(current, definition)

    def capture(self, target):
        names = [asset["filename"] for asset in target["bundle"]["assets"]]
        assets = {name: self.assets[name] for name in names if name in self.assets}
        return {"model": copy.deepcopy(self.model),
                "preservation": {table: {"count": len(rows), "sha256": digest(rows)} for table, rows in self.rows.items()},
                "assets": {name: ({"sha256": hashlib.sha256(assets[name]).hexdigest(), "size": len(assets[name])}
                                   if name in assets else None) for name in names}, "asset_bytes": assets}

    def verify_backup(self, backup, target, before):
        if self.clone_fails:
            raise OperationError("injected-isolated-preservation-failure")
        self.materialize(before["model"], target["bundle"]["definition"])
        return {"state": "verified", "anki_version": self.version, "preservation": before["preservation"]}

    def fail(self, stage):
        if self.stage == stage:
            raise KeyboardInterrupt if self.crash else RuntimeError("injected")

    def apply(self, target, before, progress):
        self.calls += 1
        self.fail("before-asset")
        for name, data in target["asset_bytes"].items():
            progress("asset:" + name, "applying")
            self.assets[name] = data
            self.registered = False
            self.fail("before-registration")
            self.registered = True
            progress("asset:" + name, "verified")
        self.fail("after-asset")
        progress("model", "applying")
        self.model = self.materialize(self.model, target["bundle"]["definition"])
        self.fail("after-model")
        progress("model", "verified")

    def media_registered(self, _target):
        return self.registered


class Runtime:
    def __init__(self, tmp_path):
        self.root = tmp_path
        self.time = 10000.0
        self.binding = {"profile": "private profile", "created": 1234}
        self.adapter = Adapter()
        self.source = tmp_path / "source"
        (self.source / "assets").mkdir(parents=True)
        self.publishing = None
        self.engine = None
        self.sent = []
        self.backups = 0
        self.mirrored = True
        self.publish_stage = None
        self.publish_crash = False
        self.sync = self.normal_sync()
        self.store = ManagedTypeStore(tmp_path / "store", instance="fixture", collection_binding=lambda: self.binding,
                                      managed_specs=(NAME,), observe=self.observe, notify=lambda event: self.sent.append(event),
                                      clock=lambda: self.time)
        # Exercise production publication/evidence wiring without importing Qt.
        self.manager = object.__new__(ManagedRuntime)
        self.manager.root, self.manager.store = tmp_path, self.store
        self.manager._publishing_update = None
        original_assets = {"_managed.js": self.adapter.assets["_managed.js"]}
        self.original = build_bundle(self.adapter.model, original_assets)
        self.initial = self.store.register_verified(NAME, 123, self.original, original_assets,
                         evidence={"original": True}, verify_registration=lambda *_: True)
        self.target = copy.deepcopy(self.adapter.model)
        self.target["css"] += "\n/* new deployed source */"
        self.target["tmpls"][0]["qfmt"] += "\n<div>new presentation</div>"
        self.target["flds"][2].update(collapsed=True, excludeFromSearch=True)
        self.target_assets = {"_managed.js": b"new registered content"}
        self.write_source()
        self.engine = self.new_engine()

    def normal_sync(self, *, start=None, action="normal", media="synced", result="success", mode="normal"):
        stamp = datetime.fromtimestamp(self.time if start is None else start, timezone.utc).isoformat()
        return {"runId": "fresh-run", "runStartedAt": stamp, "lastSuccessAt": stamp,
                "result": result, "mode": mode, "sync": {"action": action, "media": {"state": media}}}

    def observe(self, name, model_id, names):
        if self.engine is not None and self.engine.has_pending(name, exclude_operation_id=self.publishing):
            raise OperationError("managed-update-unverified-read-status")
        assets = {name: self.adapter.assets[name] for name in names if name in self.adapter.assets}
        return {"model_id": self.adapter.model["id"], "bundle": build_bundle(self.adapter.model, assets),
                "asset_bytes": assets, "missing": sorted(set(names) - set(assets))}

    def write_source(self):
        self.candidate = build_bundle(self.target, self.target_assets)
        for name, data in self.target_assets.items():
            (self.source / "assets" / name).write_bytes(data)
        (self.source / "bundle.json").write_text(json.dumps(self.candidate))

    def backup(self, operation_id):
        self.backups += 1
        path = self.root / (operation_id + ".colpkg")
        path.write_bytes(b"fixture exported collection")
        return {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "mirrored": self.mirrored}

    def snapshot(self):
        return {"all_collection_digest": digest({"model": self.adapter.model, "rows": self.adapter.rows})}

    def publish(self, record, target):
        if self.publish_stage == "before":
            raise KeyboardInterrupt if self.publish_crash else RuntimeError("injected-before-publication")
        self.publishing = record["operation_id"]
        try:
            result = self.manager._publish_update(record, target)
        finally:
            self.publishing = None
        if self.publish_stage == "after":
            raise KeyboardInterrupt if self.publish_crash else RuntimeError("injected-after-publication")
        return result

    def new_engine(self, source_revision="unknown"):
        engine = ManagedUpdate(self.root / "updates", self.store, self.adapter, self.backup, self.snapshot, lambda: self.sync,
                               source=self.source, model_name=NAME, publish=self.publish, clock=lambda: self.time,
                               source_revision=source_revision)
        self.manager.source_revision, self.manager.updates = source_revision, engine
        return engine

    def prepare(self, operation_id=OP):
        return self.engine.prepare(operation_id, True)

    def apply(self, preview=None):
        preview = preview or self.prepare()
        return self.engine.apply(OP, preview["preview_token"], True)


@pytest.fixture
def runtime(tmp_path):
    return Runtime(tmp_path)


def test_root_materializer_preserves_ids_and_only_allows_two_history_options():
    current = model()
    target = canonical_model(current)
    target["flds"][2].update(collapsed=True, excludeFromSearch=True)
    target["css"] += "new"
    result = native_from_update(current, target)
    assert result["id"] == current["id"]
    assert [field["id"] for field in result["flds"]] == [field["id"] for field in current["flds"]]
    assert canonical_model(result) == target
    with pytest.raises(ValueError, match="structure-changed"):
        native_from_definition(current, target)


@pytest.mark.parametrize("change", ["other-collapse", "history-font", "field-name", "field-order", "field-add",
                                    "template-name", "template-add", "browser-format", "req"])
def test_root_materializer_refuses_other_options_and_structure(runtime, change):
    target = runtime.target
    if change == "other-collapse":
        target["flds"][0]["collapsed"] = True
    elif change == "history-font":
        target["flds"][2]["font"] = "Courier"
    elif change == "field-name":
        target["flds"][2]["name"] = "Renamed"
    elif change == "field-order":
        target["flds"][0], target["flds"][1] = target["flds"][1], target["flds"][0]
        for i, field in enumerate(target["flds"]):
            field["ord"] = i
    elif change == "field-add":
        added = copy.deepcopy(target["flds"][-1])
        added.update(name="New field", ord=3)
        target["flds"].append(added)
    elif change == "template-name":
        target["tmpls"][0]["name"] = "Renamed"
    elif change == "template-add":
        added = copy.deepcopy(target["tmpls"][0])
        added.update(name="Second card", ord=1)
        target["tmpls"].append(added)
        target["req"].append([1, "any", [1]])
    elif change == "browser-format":
        target["tmpls"][0]["bqfmt"] = "{{Front}}"
    else:
        target["req"] = [[0, "any", [1]]]
    runtime.write_source()
    with pytest.raises(OperationError, match="unsupported-model-change"):
        runtime.prepare()
    assert runtime.backups == runtime.adapter.calls == 0


def test_preview_is_private_idempotent_and_binds_source_and_old_authority(runtime):
    r = runtime
    preview = r.prepare()
    assert preview["state"] == "prepared" and not preview["registered"]
    assert r.prepare() == preview and r.backups == 1
    record = r.engine._read(OP)
    assert record["authorization"]["record_id"] == r.initial["record_id"]
    assert record["summary"]["target_digest"] == r.candidate["digest"]
    assert record["media_before"] == {"_managed.js": "b2xkIHJlZ2lzdGVyZWQgY29udGVudA=="}
    assert r.engine._path(OP).stat().st_mode & 0o777 == 0o600
    public = json.dumps(preview)
    for private in ("private profile", "private body", "old registered content", "new registered content", ".colpkg"):
        assert private not in public


@pytest.mark.parametrize("condition", ["not-ready", "missing", "stale", "future", "wrong-mode", "full-upload", "media", "failure"])
def test_preview_requires_explicit_device_preparation_and_new_normal_sync(runtime, condition):
    r = runtime
    if condition == "missing":
        r.sync = {}
    elif condition == "stale":
        r.sync = r.normal_sync(start=r.time - 601)
    elif condition == "future":
        r.sync = r.normal_sync(start=r.time + 1)
    elif condition == "wrong-mode":
        r.sync = r.normal_sync(mode="approved-schema")
    elif condition == "full-upload":
        r.sync = r.normal_sync(action="approved-full-upload")
    elif condition == "media":
        r.sync = r.normal_sync(media="pending")
    elif condition == "failure":
        r.sync = r.normal_sync(result="failed")
    with pytest.raises(OperationError):
        r.engine.prepare(OP, condition != "not-ready")
    assert r.backups == r.adapter.calls == 0


@pytest.mark.parametrize("condition", ["drift", "missing-baseline", "binding"])
def test_only_normal_bound_baseline_can_authorize_update(runtime, condition):
    r = runtime
    if condition == "drift":
        r.adapter.model["css"] += "app edit"
    elif condition == "missing-baseline":
        (r.store.root / "baselines" / (r.initial["record_id"] + ".json")).unlink()
    else:
        r.binding = {"new-profile": True}
    with pytest.raises(OperationError, match="normal-baseline-required"):
        r.prepare()
    assert r.adapter.calls == 0


@pytest.mark.parametrize("condition", ["mirror", "trial"])
def test_failed_mirror_or_isolated_proof_never_reaches_live_write(runtime, condition):
    if condition == "mirror":
        runtime.mirrored = False
    else:
        runtime.adapter.clone_fails = True
    with pytest.raises(OperationError):
        runtime.prepare()
    assert runtime.engine.status(OP)["state"] == "not-applied"
    assert runtime.adapter.calls == 0 and not runtime.engine.has_pending(NAME)


@pytest.mark.parametrize("change", ["source", "source-asset", "model", "asset", "row", "binding", "baseline", "backup", "version"])
def test_changed_preview_refuses_before_any_live_write(runtime, change):
    r = runtime
    preview = r.prepare()
    if change == "source":
        r.target["css"] += "later source"
        r.write_source()
    elif change == "source-asset":
        (r.source / "assets/_managed.js").write_bytes(b"corrupt candidate")
    elif change == "model":
        r.adapter.model["mod"] += 1
    elif change == "asset":
        r.adapter.assets["_managed.js"] += b"new app content"
    elif change == "row":
        r.adapter.rows["revlog"].append([11, 9, 2])
    elif change == "binding":
        r.binding = {"another-profile": True}
    elif change == "baseline":
        r.store.register_verified(NAME, 123, r.original, {"_managed.js": r.adapter.assets["_managed.js"]},
                                  evidence={"another-authority": True}, verify_registration=lambda *_: True)
    elif change == "backup":
        Path(r.engine._read(OP)["backup"]["path"]).write_bytes(b"changed backup")
    else:
        r.adapter.version = "different-anki"
    with pytest.raises((OperationError, ManagedDriftError)):
        r.apply(preview)
    assert r.adapter.calls == 0


def test_confirmation_token_and_original_expiry_are_enforced(runtime):
    r = runtime
    r.sync = r.normal_sync(start=r.time - 590)
    preview = r.prepare()
    assert preview["expires_at"] == r.time + 10
    with pytest.raises(OperationError, match="explicit-confirmation"):
        r.engine.apply(OP, preview["preview_token"])
    with pytest.raises(OperationError, match="token-mismatch"):
        r.engine.apply(OP, "c" * 64, True)
    r.time += 10
    assert r.apply(preview)["state"] == "expired"
    assert r.prepare()["state"] == "expired" and r.backups == 1 and r.adapter.calls == 0


def test_apply_and_registration_are_one_operation_without_drift_or_data_changes(runtime):
    r = runtime
    before = copy.deepcopy(r.adapter.rows)
    preview = r.prepare()
    result = r.apply(preview)
    assert result["state"] == "applied" and result["registered"] is True
    assert result["sync"]["state"] == "pending" and not result["client_delivery_confirmed"]
    baseline = r.store.get_baseline(NAME)
    assert baseline["record_id"] == OP and baseline["bundle"] == r.candidate
    assert baseline["evidence"]["source"]["git_revision"] == "unknown"
    assert r.store.inspect(NAME)["status"] == "normal" and r.sent == []
    assert r.adapter.rows == before and r.adapter.assets["personal.png"] == b"private personal media"
    assert not r.engine.has_pending(NAME)
    r.time += 1000
    assert r.apply(preview) == result and r.prepare() == result and r.adapter.calls == 1


def test_prepared_update_preserves_recorded_revision_after_restart_without_sha(runtime):
    r = runtime
    old_revision = "a" * 40
    r.engine = r.new_engine(source_revision=old_revision)
    preview = r.prepare()
    prepared = copy.deepcopy(r.engine._read(OP))
    r.engine = r.new_engine()
    assert r.manager.source_revision == "unknown"
    assert r.engine._read(OP) == prepared
    assert r.apply(preview)["state"] == "applied"
    assert r.store.get_baseline(NAME)["evidence"]["source"]["git_revision"] == old_revision
    assert r.adapter.calls == 1


@pytest.mark.parametrize("stage", ["before-asset", "before-registration", "after-asset", "after-model"])
def test_partial_unknown_stay_blocked_and_diagnosis_never_reapplies(runtime, stage):
    r = runtime
    preview = r.prepare()
    r.adapter.stage = stage
    receipt = r.apply(preview)
    assert receipt["state"] in ("unknown", "partial") and not receipt["registered"]
    assert r.engine.has_pending(NAME) and r.store.inspect(NAME)["status"] == "unavailable"
    assert r.apply(preview) == receipt and r.adapter.calls == 1
    with pytest.raises(OperationError, match="unresolved-update"):
        r.prepare(NEXT)
    r.adapter.stage = None
    diagnosed = r.engine.diagnose(OP)
    assert diagnosed["state"] == ("applied" if stage == "after-model" else "unknown")
    assert r.adapter.calls == 1


@pytest.mark.parametrize("stage", ["before", "pointer", "after"])
@pytest.mark.parametrize("crash", [False, True])
def test_baseline_publication_interruption_is_diagnosed_once_without_reapplication(runtime, stage, crash, monkeypatch):
    r = runtime
    old_revision = "a" * 40
    r.engine = r.new_engine(source_revision=old_revision)
    preview = r.prepare()
    r.publish_stage, r.publish_crash = stage, crash
    save_state = r.store._save_state
    if stage == "pointer":
        def interrupted_pointer_write(state):
            if state["baselines"].get(NAME) == OP:
                raise KeyboardInterrupt if crash else RuntimeError("injected-before-baseline-pointer")
            save_state(state)
        monkeypatch.setattr(r.store, "_save_state", interrupted_pointer_write)
    if crash:
        with pytest.raises(KeyboardInterrupt):
            r.apply(preview)
    else:
        assert r.apply(preview)["state"] == "partial"
    published = r.store.get_baseline(NAME)
    baseline_path = r.store.root / "baselines" / (OP + ".json")
    saved_baseline = r.store._read(baseline_path) if baseline_path.exists() else None
    if stage == "pointer":
        assert published["record_id"] == r.initial["record_id"]
        assert saved_baseline["evidence"]["source"]["git_revision"] == old_revision
    r.engine = r.new_engine()
    assert r.manager.source_revision == "unknown"
    assert r.engine._read(OP)["source_revision"] == old_revision
    assert r.engine.status(OP)["state"] in ("unknown", "partial")
    assert r.store.inspect(NAME)["status"] == "unavailable"
    assert r.apply(preview)["state"] in ("unknown", "partial") and r.adapter.calls == 1
    r.publish_stage = None
    monkeypatch.setattr(r.store, "_save_state", save_state)
    r.time += 1000  # Finishing an already confirmed local result is not a new mutation approval.
    outcome = r.engine.diagnose(OP)
    assert outcome["state"] == "applied" and outcome["registered"]
    assert r.store.get_baseline(NAME)["record_id"] == OP
    evidence = r.store.get_baseline(NAME)["evidence"]
    assert evidence["source"]["git_revision"] == old_revision
    if saved_baseline is not None:
        # Includes the evidence, checksum and first applied_verified_at time.
        assert r.store._read(baseline_path) == saved_baseline
    assert len(list((r.store.root / "baselines").glob("*.json"))) == 2
    assert r.adapter.calls == 1 and r.store.inspect(NAME)["status"] == "normal"


def test_unconfirmed_postcondition_cannot_publish_or_release_protection(runtime):
    r = runtime
    preview = r.prepare()
    r.adapter.stage = "after-model"
    r.apply(preview)
    r.adapter.rows["notes"][0][1] = "changed after interruption"
    assert r.engine.diagnose(OP)["state"] == "unknown"
    assert r.store.get_baseline(NAME)["record_id"] == r.initial["record_id"]
    assert r.store.inspect(NAME)["status"] == "unavailable"


@pytest.mark.parametrize("condition", ["stale", "media", "full-sync", "full-upload", "failure"])
def test_delivery_needs_fresh_normal_and_media_receipts(runtime, condition):
    r = runtime
    result = r.apply()
    assert result["state"] == "applied"
    if condition != "stale":
        r.time += 1
    r.sync = r.normal_sync()
    if condition == "media":
        r.sync["sync"]["media"]["state"] = "pending"
    elif condition == "full-sync":
        r.sync["sync"]["action"] = "full-sync-required"
        r.sync["result"] = "full-sync-required"
    elif condition == "full-upload":
        r.sync["sync"]["action"] = "approved-full-upload"
    elif condition == "failure":
        r.sync["result"] = "failed"
    receipt = r.engine.delivery(OP)
    assert receipt["sync"]["state"] != "synced"
    if condition == "full-sync":
        assert receipt["sync"]["state"] == "blocked" and receipt["registered"]
    r.time += 1
    r.sync = r.normal_sync()
    r.adapter.rows["revlog"].append([11, 9, 3])  # Later reviews do not undo proof at the local apply boundary.
    assert r.engine.delivery(OP)["sync"]["state"] == "synced"
    assert r.adapter.calls == 1


def test_asset_removal_changes_registration_without_deleting_existing_media(runtime):
    r = runtime
    r.target = copy.deepcopy(r.adapter.model)
    r.target_assets = {}
    r.write_source()
    receipt = r.apply()
    assert receipt["state"] == "applied" and receipt["registered"]
    assert r.store.get_baseline(NAME)["bundle"]["assets"] == []
    assert r.adapter.assets["_managed.js"] == b"old registered content"


@pytest.mark.parametrize("value", ["../escape", "a" * 31, "A" * 32, None])
def test_invalid_operation_ids_never_form_a_path(runtime, value):
    with pytest.raises(OperationError, match="invalid-operation-id"):
        runtime.engine.prepare(value, True)
    assert runtime.adapter.calls == runtime.backups == 0


def test_broken_journal_cannot_start_as_a_healthy_coordinator(runtime):
    runtime.prepare()
    runtime.engine._path(OP).write_text('{')
    with pytest.raises(ValueError):
        runtime.new_engine()


def test_baseline_transition_refuses_wrong_previous_or_reused_registration_id(runtime):
    r = runtime
    arguments = dict(evidence={"update_operation_id": OP}, verify_registration=lambda *_: True,
                     registration_id=OP)
    with pytest.raises(ManagedDriftError, match="baseline-changed"):
        r.store.register_verified(NAME, 123, r.original, {"_managed.js": r.adapter.assets["_managed.js"]},
                                  previous_record_id="c" * 32, **arguments)
    with pytest.raises(ManagedDriftError, match="transition-invalid"):
        r.store.register_verified(NAME, 123, r.original, {"_managed.js": r.adapter.assets["_managed.js"]},
                                  previous_record_id=OP, **arguments)
