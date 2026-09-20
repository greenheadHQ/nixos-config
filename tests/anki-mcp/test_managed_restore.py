"""Durable restore protocol, with explicit failures at mutation boundaries."""
import base64
import copy
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path

import pytest

from anki_host_fixture.managed_bundle import build_bundle, native_from_definition
from anki_host_fixture.managed_restore import ManagedRestore
from anki_host_fixture.operations import OperationError, digest
from test_managed_drift import NAME, native


class Adapter:
    version = "test-anki"

    def __init__(self):
        self.model = native()
        self.model["css"] += "/* app edit */"
        self.assets = {"_managed.js": b"bad bytes"}
        self.data = {"notes": [[1, "body", "marked", "long\n\nmemo"]],
                     "cards": [[9, 1, 30, 5, 2500]], "revlog": [[10, 9, 3]]}
        self.registered = False
        self.calls = 0
        self.stage = None
        self.crash = False
        self.clone_fails = False

    def capture(self, baseline):
        return {"model": copy.deepcopy(self.model),
                "preservation": {t: {"count": len(v), "sha256": digest(v)} for t, v in self.data.items()},
                "assets": {a["filename"]: ({"size": len(self.assets[a["filename"]]),
                                            "sha256": hashlib.sha256(self.assets[a["filename"]]).hexdigest()}
                                           if a["filename"] in self.assets else None)
                           for a in baseline["bundle"]["assets"]},
                "asset_bytes": copy.deepcopy(self.assets)}

    def verify_backup(self, backup, baseline, before):
        if self.clone_fails:
            raise OperationError("injected-generation-change")
        return {"state": "verified", "anki_version": self.version, "preservation": before["preservation"]}

    def fail(self, stage):
        if stage == self.stage:
            raise KeyboardInterrupt if self.crash else RuntimeError("injected")

    def apply(self, baseline, before, progress):
        self.calls += 1
        progress("asset:_managed.js", "applying")
        self.fail("before-asset")
        self.assets = copy.deepcopy(baseline["asset_bytes"])
        self.fail("before-registration")
        self.registered = True
        progress("asset:_managed.js", "verified")
        self.fail("after-asset")
        progress("model", "applying")
        self.model = native_from_definition(self.model, baseline["bundle"]["definition"])
        self.fail("after-model")
        progress("model", "verified")

    def media_registered(self, _baseline):
        return self.registered


class Runtime:
    def __init__(self, tmp_path):
        self.path = tmp_path
        self.adapter = Adapter()
        assets = {"_managed.js": b"approved bytes"}
        self.baseline = {"record_id": "verified-record", "model_id": 123, "model_name": NAME,
                         "binding": {"collection": "private"}, "operator_verified": True,
                         "evidence": {"passed": True}, "bundle": build_bundle(native(), assets),
                         "asset_bytes": assets}
        self.time = 10000.0
        self.sync = {}
        self.backups = 0
        self.engine = self.new_engine()

    def get_baseline(self, name):
        assert name == NAME
        return copy.deepcopy(self.baseline)

    def restore(self, opid):
        self.backups += 1
        path = self.path / (opid + ".colpkg")
        path.write_bytes(b"verified exported backup")
        return {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "mirrored": True}

    def snapshot(self):
        return {"all_collection_digest": digest({"model": self.adapter.model, "rows": self.adapter.data})}

    def new_engine(self):
        return ManagedRestore(self.path / "journal", self, self.adapter, self.restore,
                              self.snapshot, lambda: self.sync, clock=lambda: self.time)

    def prepare(self, request="restore-request-1"):
        return self.engine.prepare(NAME, request)

    def apply(self, preview=None):
        preview = preview or self.prepare()
        return self.engine.apply(preview["request_id"], preview["preview_token"], True)

    def success_sync(self, *, media="synced", started=None, result="success", action="normal"):
        timestamp = datetime.fromtimestamp(self.time if started is None else started, timezone.utc).isoformat()
        self.sync = {"runId": "real-server-owned-run", "runStartedAt": timestamp,
                     "lastSuccessAt": timestamp, "result": result, "mode": "normal",
                     "sync": {"action": action, "media": {"state": media}}}


@pytest.fixture
def runtime(tmp_path):
    return Runtime(tmp_path)


def test_preview_backups_are_bound_private_and_idempotent(runtime):
    r = runtime
    preview = r.prepare()
    assert preview["state"] == "prepared" and preview["confirmation_required"]
    assert preview["summary"]["changed_items"] == ["definition.css", "assets._managed.js.content"]
    assert r.prepare() == preview and r.backups == 1
    record = r.engine._read(preview["request_id"])
    assert base64.b64decode(record["media_before"]["_managed.js"]) == b"bad bytes"
    assert r.engine._path(preview["request_id"]).stat().st_mode & 0o777 == 0o600
    public = json.dumps(preview)
    assert "bad bytes" not in public and "private" not in public and "colpkg" not in public
    with pytest.raises(OperationError, match="payload-mismatch"):
        r.engine.prepare("other-model", preview["request_id"])


def test_absent_asset_is_backed_up_as_absence(runtime):
    r = runtime
    r.adapter.assets.clear()
    preview = r.prepare()
    assert r.engine._read(preview["request_id"])["media_before"] == {"_managed.js": None}
    assert r.apply(preview)["state"] == "applied"


@pytest.mark.parametrize("change", ["model", "assets", "rows", "baseline", "binding", "backup", "version"])
def test_prepared_state_changes_refuse_all_writes(runtime, change):
    r = runtime
    preview = r.prepare()
    if change == "model":
        r.adapter.model["mod"] += 1
    elif change == "assets":
        r.adapter.assets["_managed.js"] += b"newer"
    elif change == "rows":
        r.adapter.data["revlog"].append([11, 9, 2])
    elif change == "baseline":
        r.baseline["record_id"] = "new-record"
    elif change == "binding":
        r.baseline["binding"] = {"collection": "other"}
    elif change == "backup":
        Path(r.engine._read(preview["request_id"])["backup"]["path"]).write_bytes(b"corrupt")
    else:
        r.adapter.version = "different-anki"
    with pytest.raises(OperationError):
        r.apply(preview)
    assert r.adapter.calls == 0


@pytest.mark.parametrize("change", ["field-order", "generation", "template-count", "browser-format", "new-setting"])
def test_structure_changes_and_unknown_settings_rejected_before_backup(runtime, change):
    r = runtime
    if change == "field-order":
        r.adapter.model["flds"][0]["name"] = "Renamed"
    elif change == "generation":
        r.adapter.model["req"] = [[0, "any", [1]]]
    elif change == "template-count":
        r.adapter.model["tmpls"].append(copy.deepcopy(r.adapter.model["tmpls"][0]))
    elif change == "browser-format":
        r.adapter.model["tmpls"][0]["bqfmt"] = "different"
    else:
        r.adapter.model["future-unknown-setting"] = True
    with pytest.raises(ValueError):
        r.prepare()
    assert r.backups == 0 and r.adapter.calls == 0


def test_unverified_baseline_and_failed_trial_cannot_restore(runtime):
    r = runtime
    r.baseline["operator_verified"] = False
    with pytest.raises(OperationError, match="baseline-not-verified"):
        r.prepare()
    r.baseline["operator_verified"] = True
    r.adapter.clone_fails = True
    with pytest.raises(OperationError, match="generation-change"):
        r.prepare()
    assert r.engine.status("restore-request-1")["state"] == "not-applied"
    assert r.adapter.calls == 0


def test_requires_confirmation_and_unexpired_exact_token(runtime):
    r = runtime
    preview = r.prepare()
    with pytest.raises(OperationError, match="explicit-confirmation"):
        r.engine.apply(preview["request_id"], preview["preview_token"])
    with pytest.raises(OperationError, match="token-mismatch"):
        r.engine.apply(preview["request_id"], "wrong", True)
    r.time = preview["expires_at"]
    assert r.apply(preview)["state"] == "expired"
    assert r.adapter.calls == 0


def test_local_success_and_request_replay_never_reapply(runtime):
    r = runtime
    preview = r.prepare()
    before = copy.deepcopy(r.adapter.data)
    result = r.apply(preview)
    assert result["state"] == "applied" and result["sync"]["state"] == "pending"
    assert r.adapter.data == before and not r.engine.has_pending(NAME)
    assert r.apply(preview) == result
    assert r.prepare() == result and r.adapter.calls == 1


@pytest.mark.parametrize("stage,expected", [("before-asset", "unknown"), ("before-registration", "unknown"),
                                            ("after-asset", "partial"), ("after-model", "partial")])
def test_interrupted_components_stay_blocked_and_never_reapply(runtime, stage, expected):
    r = runtime
    preview = r.prepare()
    r.adapter.stage = stage
    receipt = r.apply(preview)
    assert receipt["state"] == expected and r.engine.has_pending(NAME)
    assert r.apply(preview) == receipt and r.adapter.calls == 1
    with pytest.raises(OperationError, match="unresolved-restore"):
        r.prepare("restore-another-request")
    assert r.engine.delivery(preview["request_id"])["state"] == expected
    diagnosed = r.engine.diagnose(preview["request_id"])
    assert diagnosed["state"] == ("applied" if stage == "after-model" else expected)
    assert r.adapter.calls == 1


def test_process_death_recovers_unknown_until_exact_readback(runtime):
    r = runtime
    preview = r.prepare()
    r.adapter.stage, r.adapter.crash = "after-model", True
    with pytest.raises(KeyboardInterrupt):
        r.apply(preview)
    r.engine = r.new_engine()
    assert r.engine.status(preview["request_id"])["state"] == "unknown"
    assert r.engine.has_pending(NAME)
    assert r.engine.diagnose(preview["request_id"])["state"] == "applied"
    assert r.adapter.calls == 1


def test_completed_bytes_without_media_registration_are_not_success(runtime):
    r = runtime
    preview = r.prepare()
    r.adapter.stage = "after-model"
    r.apply(preview)
    r.adapter.registered = False
    assert r.engine.diagnose(preview["request_id"])["state"] == "partial"
    assert r.engine.has_pending(NAME)


@pytest.mark.parametrize("table", ["notes", "cards", "revlog"])
def test_same_counts_and_ids_do_not_hide_changed_body_schedule_or_review(runtime, table, monkeypatch):
    r = runtime
    preview = r.prepare()
    original = r.adapter.apply

    def writes_with_unexpected_data_change(*args):
        original(*args)
        r.adapter.data[table][0][-1] = "unexpected changed value"

    monkeypatch.setattr(r.adapter, "apply", writes_with_unexpected_data_change)
    receipt = r.apply(preview)
    assert receipt["state"] == "partial"
    assert r.engine.diagnose(preview["request_id"])["state"] == "partial"
    assert r.engine.has_pending(NAME)


@pytest.mark.parametrize("media,result,action", [("unknown", "success", "normal"),
                                                ("disabled", "success", "normal"),
                                                ("synced", "error", "normal"),
                                                ("synced", "success", "full-sync-required")])
def test_delivery_requires_fresh_collection_and_media_proof(runtime, media, result, action):
    r = runtime
    receipt = r.apply()
    r.time += 2
    r.success_sync(media=media, result=result, action=action)
    actual = r.engine.delivery(receipt["request_id"])
    assert actual["sync"]["state"] != "synced"
    assert actual["state"] == "applied" and not actual["client_delivery_confirmed"]


def test_delivery_stale_then_fresh_and_later_reviews_allowed(runtime):
    r = runtime
    receipt = r.apply()
    r.success_sync(started=r.time - 1)
    assert r.engine.delivery(receipt["request_id"])["sync"]["state"] == "pending"
    r.time += 2
    r.adapter.data["revlog"].append([11, 9, 3])
    r.success_sync()
    delivered = r.engine.delivery(receipt["request_id"])
    assert delivered["sync"]["state"] == "synced"
    assert r.engine.delivery(receipt["request_id"]) == delivered


def test_content_changed_after_apply_is_not_delivered(runtime):
    r = runtime
    receipt = r.apply()
    r.time += 2
    r.success_sync()
    r.adapter.model["css"] += "new edit"
    assert r.engine.delivery(receipt["request_id"])["sync"]["state"] == "pending"


def test_request_ids_cannot_traverse_journal(runtime):
    with pytest.raises(OperationError):
        runtime.prepare("../arbitrary")
    with pytest.raises(OperationError, match="managed-restore-not-found"):
        runtime.engine.status("absent-request-id")
