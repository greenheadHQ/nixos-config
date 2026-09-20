"""Private managed baselines: real disk receipts, injected reads/delivery failures."""

import copy
import json
import stat

import pytest

from anki_host_fixture.managed_bundle import build_bundle
from anki_host_fixture.managed_drift import ManagedDriftError, ManagedTypeStore


NAME = "CS 재활 Basic"


def native():
    fields = [dict(name=name, ord=i, sticky=False, rtl=False, font="Arial", size=20,
                   description="", plainText=False, collapsed=False, excludeFromSearch=False,
                   id=10 + i, tag=None, preventDeletion=False)
              for i, name in enumerate(("Front", "Back"))]
    return dict(id=123, name=NAME, type=0, mod=1, usn=1, sortf=0, did=None, flds=fields,
                tmpls=[dict(name="Card", ord=0, qfmt="{{Front}}", afmt="{{Back}}",
                            bqfmt="", bafmt="", did=None, bfont="", bsize=0, id=20)],
                css=".card { color: black; }", latexPre="", latexPost="", latexsvg=False,
                req=[[0, "any", [0]]], originalStockKind=1)


class Runtime:
    def __init__(self, tmp_path):
        self.path = tmp_path / "managed"
        self.model = native()
        self.assets = {"_managed.js": b"const x = 1;\r\n", "_managed.css": b"a { color:red; }"}
        self.expected = build_bundle(self.model, self.assets)
        self.binding = {"instance_uuid": "private-token", "collection_created": 1234}
        self.time = 10000.0
        self.sent = []
        self.send_state = "sent"
        self.error = None
        self.latest = copy.deepcopy(self.expected)
        self.sync = {"state": "success", "at": 9999.0}
        self.observations = 0
        self.store = self.new_store()

    def observe(self, name, model_id, names):
        self.observations += 1
        assert name == NAME
        assert model_id == 123
        if self.error:
            raise self.error
        assets = {name: self.assets[name] for name in names if name in self.assets}
        return {"model_id": self.model["id"], "bundle": build_bundle(self.model, assets),
                "asset_bytes": assets, "missing": sorted(set(names) - set(assets))}

    def notify(self, payload):
        self.sent.append(copy.deepcopy(payload))
        if isinstance(self.send_state, BaseException):
            raise self.send_state
        return {"state": self.send_state}

    def source(self, name):
        assert name == NAME
        if isinstance(self.latest, Exception):
            raise self.latest
        return self.latest

    def new_store(self, **kwargs):
        options = dict(instance="lab", collection_binding=lambda: self.binding,
                       managed_specs=[NAME], observe=self.observe, last_sync=lambda: self.sync,
                       notify=self.notify, latest_bundle=self.source, clock=lambda: self.time)
        options.update(kwargs)
        return ManagedTypeStore(self.path, **options)

    def register(self, **kwargs):
        options = dict(evidence={"operator_approval": "explicit", "test_result": "passed"},
                       verify_registration=lambda *args: True)
        options.update(kwargs)
        return self.store.register_verified(NAME, 123, self.expected, self.assets, **options)

    def incident(self, report):
        return json.loads((self.path / "incidents" / (report["incident_id"] + ".json")).read_text())


@pytest.fixture
def runtime(tmp_path):
    return Runtime(tmp_path)


def test_first_registration_requires_evidence_independent_verification_and_fresh_readback(runtime):
    assert runtime.store.inspect(NAME)["status"] == "unavailable"
    with pytest.raises(ManagedDriftError, match="evidence-required"):
        runtime.register(evidence={})
    with pytest.raises(ManagedDriftError, match="not-verified"):
        runtime.register(verify_registration=lambda *args: {"looks_correct": True})
    runtime.model["css"] += "changed"
    with pytest.raises(ManagedDriftError, match="readback-mismatch"):
        runtime.register()
    assert not list((runtime.path / "baselines").glob("*.json"))
    runtime.model = native()
    registered = runtime.register()
    baseline = runtime.new_store().get_baseline(NAME)
    assert baseline["record_id"] == registered["record_id"]
    assert baseline["asset_bytes"] == runtime.assets
    assert baseline["binding"] == runtime.binding
    assert baseline["evidence"]["operator_approval"] == "explicit"


def test_public_report_and_notification_do_not_leak_templates_assets_or_evidence(runtime):
    runtime.register()
    runtime.model["css"] = "PRIVATE_CURRENT_CSS"
    report = runtime.store.inspect(NAME)
    public = json.dumps([report, runtime.sent])
    for private in ("PRIVATE_CURRENT_CSS", "const x = 1", "operator_approval", "private-token"):
        assert private not in public
    incident = runtime.incident(report)
    assert incident["observed_bundle"]["definition"]["css"] == "PRIVATE_CURRENT_CSS"
    assert incident["baseline_record_id"] == report["baseline_record_id"]
    assert set(incident["observed_assets_base64"]) == set(runtime.assets)
    assert runtime.sent[0]["changed_paths"] == ["definition.css"]


def test_local_normal_update_pending_and_github_unavailable_are_independent(runtime):
    runtime.register()
    report = runtime.store.inspect(NAME)
    assert report["status"] == "normal" and report["write_blocked"] is False
    assert report["last_sync"] == runtime.sync
    assert report["source"]["update_pending"] is False
    # A different source commit with identical bytes has no distinct version.
    runtime.latest = copy.deepcopy(runtime.expected)
    assert runtime.store.inspect(NAME)["source"]["update_pending"] is False
    new = native()
    new["css"] += " /* later Git version */"
    runtime.latest = build_bundle(new, runtime.assets)
    report = runtime.store.inspect(NAME)
    assert report["source"]["update_pending"] is True and report["status"] == "normal"
    runtime.latest = ConnectionError("private GitHub access detail")
    report = runtime.store.inspect(NAME)
    assert report["status"] == "normal"
    assert report["source"] == {"state": "unavailable", "update_pending": None}
    assert report["github_latest"] == {"state": "not-checked"}


def test_every_inspection_rereads_instead_of_reusing_old_normal_cache(runtime):
    runtime.register()
    assert runtime.store.inspect(NAME)["status"] == "normal"
    observations = runtime.observations
    runtime.assets["_managed.js"] = b"changed after prior inspection"
    report = runtime.store.inspect(NAME)
    assert runtime.observations == observations + 1
    assert report["status"] == "drift" and report["write_blocked"]
    assert report["changed_paths"] == ["assets._managed.js.content"]


@pytest.mark.parametrize("kind", ["missing", "corrupt", "asset-corrupt", "collection", "instance", "recreated"])
def test_missing_corrupt_baseline_or_changed_binding_fail_closed(runtime, kind):
    runtime.register()
    path = next((runtime.path / "baselines").glob("*.json"))
    if kind == "missing":
        path.unlink()
    elif kind == "corrupt":
        path.write_text("{")
    elif kind == "asset-corrupt":
        record = json.loads(path.read_text())
        record["assets_base64"]["_managed.js"] = "brokenbase64"
        path.write_text(json.dumps(record))
    elif kind == "collection":
        runtime.binding = {"instance_uuid": "different-collection"}
    elif kind == "instance":
        runtime.store = runtime.new_store(instance="main")
    elif kind == "recreated":
        runtime.model["id"] = 456
    result = runtime.store.inspect(NAME)
    assert result["status"] == "unavailable" and result["write_blocked"] is True
    assert runtime.sent == []


def test_recreated_model_cannot_register_over_existing_binding(runtime):
    runtime.register()
    with pytest.raises(ManagedDriftError, match="rebinding-forbidden"):
        runtime.store.register_verified(NAME, 456, runtime.expected, runtime.assets,
                                        evidence={"approved": True}, verify_registration=lambda *args: True)


def test_missing_registered_asset_is_drift_but_read_errors_are_unavailable(runtime):
    runtime.register()
    del runtime.assets["_managed.js"]
    result = runtime.store.inspect(NAME)
    assert result["status"] == "drift"
    assert result["changed_paths"] == ["assets._managed.js.missing"]
    runtime.error = PermissionError("secret local directory")
    result = runtime.store.inspect(NAME)
    assert result["status"] == "unavailable"
    assert "secret" not in json.dumps(result)


def test_partial_or_inconsistent_observation_does_not_fabricate_absence(runtime):
    runtime.register()
    original = runtime.store.observe
    def incomplete(*args):
        value = original(*args)
        value["missing"] = ["_managed.js"]
        return value
    runtime.store.observe = incomplete
    assert runtime.store.inspect(NAME)["status"] == "unavailable"


def test_collection_switch_during_fresh_read_and_custom_error_fail_closed(runtime):
    runtime.register()
    original = runtime.store.observe
    def changed(*args):
        value = original(*args)
        runtime.binding = {"instance_uuid": "new-collection"}
        return value
    runtime.store.observe = changed
    assert runtime.store.inspect(NAME)["status"] == "unavailable"
    runtime.binding = {"instance_uuid": "private-token", "collection_created": 1234}
    runtime.store.observe = original
    runtime.error = ManagedDriftError("secret template: <div>private</div>")
    result = runtime.store.inspect(NAME)
    assert result["status"] == "unavailable" and "private</div>" not in json.dumps(result)


def test_same_unresolved_difference_deduplicates_across_restart_and_recurrence_is_new(runtime):
    runtime.register()
    runtime.store.inspect(NAME)
    runtime.time += 1
    runtime.model["css"] += " altered"
    first = runtime.store.inspect(NAME)
    saved = runtime.incident(first)
    assert saved["last_normal_at"] == 10000.0
    runtime.time += 20
    again = runtime.new_store().inspect(NAME)
    assert again["incident_id"] == first["incident_id"]
    assert len(runtime.sent) == 1
    assert runtime.incident(first) == saved  # no duplicate snapshots/timestamp churn
    assert len(list((runtime.path / "incidents").glob("*.json"))) == 1
    runtime.model = native()
    assert runtime.store.inspect(NAME)["status"] == "normal"
    resolved = runtime.incident(first)
    assert resolved["resolved_at"] == runtime.time
    assert resolved["resolution"] == "observed-applied-baseline"
    runtime.model["css"] += " altered"
    recurrence = runtime.store.inspect(NAME)
    assert recurrence["incident_id"] != first["incident_id"]
    assert len(runtime.sent) == 2


def test_different_unresolved_diffs_have_distinct_records_but_revisiting_deduplicates(runtime):
    runtime.register()
    runtime.model["css"] = "A"
    first = runtime.store.inspect(NAME)
    runtime.model["css"] = "B"
    second = runtime.store.inspect(NAME)
    runtime.model["css"] = "A"
    assert runtime.store.inspect(NAME)["incident_id"] == first["incident_id"]
    assert first["incident_id"] != second["incident_id"]
    assert len(runtime.sent) == 2
    runtime.model = native()
    runtime.store.inspect(NAME)
    assert all(runtime.incident(report)["resolved_at"] is not None for report in (first, second))


def test_interrupted_resolution_index_write_cannot_absorb_recurrence(runtime, monkeypatch):
    runtime.register()
    runtime.model["css"] = "drift-A"
    first = runtime.store.inspect(NAME)
    original_save = runtime.store._save_state
    def fail(_):
        raise OSError("interruption after durable incident resolution")
    monkeypatch.setattr(runtime.store, "_save_state", fail)
    runtime.model = native()
    assert runtime.store.inspect(NAME)["status"] == "unavailable"
    assert runtime.incident(first)["resolved_at"] == runtime.time
    monkeypatch.setattr(runtime.store, "_save_state", original_save)
    runtime.model["css"] = "drift-A"
    recurrence = runtime.new_store().inspect(NAME)
    assert recurrence["incident_id"] != first["incident_id"]
    assert len(runtime.sent) == 2


@pytest.mark.parametrize("outcome", ["failed", "unknown", RuntimeError("provider secret")])
def test_failed_and_unknown_notifications_do_not_auto_retry(runtime, outcome):
    runtime.register()
    runtime.send_state = outcome
    runtime.model["css"] += " drift"
    first = runtime.store.inspect(NAME)
    expected = outcome if isinstance(outcome, str) else "unknown"
    assert first["notification"]["state"] == expected
    assert runtime.new_store().inspect(NAME)["notification"]["state"] == expected
    assert len(runtime.sent) == 1
    if expected == "failed":
        runtime.send_state = "sent"
        retry = runtime.store.retry_notification(first["incident_id"])
        assert retry["notification"]["state"] == "sent"
        assert len(runtime.sent) == 2
    else:
        with pytest.raises(ManagedDriftError, match="retry-not-allowed"):
            runtime.store.retry_notification(first["incident_id"])
    assert "secret" not in json.dumps(first)


def test_process_exit_during_send_becomes_unknown_and_is_not_resent(runtime):
    runtime.register()
    runtime.model["css"] += " drift"
    runtime.send_state = SystemExit("crash between provider acceptance and durable receipt")
    with pytest.raises(SystemExit):
        runtime.store.inspect(NAME)
    runtime.send_state = "sent"
    result = runtime.new_store().inspect(NAME)
    assert result["notification"]["state"] == "unknown"
    assert len(runtime.sent) == 1


def test_notification_suppression_retains_pending_until_next_enabled_check(runtime):
    runtime.register()
    runtime.model["css"] += " drift"
    report = runtime.store.inspect(NAME, notify=False)
    assert report["notification"]["state"] == "pending" and not runtime.sent
    assert runtime.new_store().inspect(NAME)["notification"]["state"] == "sent"
    assert len(runtime.sent) == 1


def test_unverified_restore_or_sync_read_failure_never_clears_existing_drift(runtime):
    runtime.register()
    runtime.model["css"] += " drift"
    report = runtime.store.inspect(NAME)
    runtime.model = native()
    runtime.error = ManagedDriftError("managed-restore-pending-verification")
    runtime.sync = {"state": "blocked", "action": "full-sync-required"}
    pending = runtime.store.inspect(NAME)
    assert pending["status"] == "unavailable" and pending["write_blocked"]
    assert pending["last_sync"]["state"] == "blocked"
    assert runtime.incident(report)["resolved_at"] is None
    runtime.error = None
    assert runtime.store.inspect(NAME)["status"] == "normal"


def test_retention_uses_resolution_time_keeps_unresolved_and_never_deletes_baselines(runtime):
    runtime.register()
    runtime.model["css"] += " drift"
    resolved = runtime.store.inspect(NAME)
    runtime.time += 200 * 86400
    assert runtime.store.prune_resolved() == []
    runtime.model = native()
    runtime.store.inspect(NAME)
    resolved_at = runtime.time
    runtime.model["css"] += " another"
    unresolved = runtime.store.inspect(NAME)
    runtime.time = resolved_at + 90 * 86400 - 1
    assert runtime.store.prune_resolved() == []
    runtime.time += 1
    assert runtime.store.prune_resolved() == [resolved["incident_id"]]
    assert runtime.incident(unresolved)["resolved_at"] is None
    assert runtime.store.get_baseline(NAME)["asset_bytes"] == runtime.assets
    assert runtime.store.prune_resolved() == []


def test_unmanaged_type_does_not_read_collection_or_create_baseline(runtime):
    report = runtime.store.inspect("Old KaTeX")
    assert report == {"model_name": "Old KaTeX", "status": "unmanaged", "write_blocked": False}
    assert runtime.observations == 0
    with pytest.raises(ManagedDriftError, match="not-managed"):
        runtime.store.get_baseline("Old KaTeX")


def test_permissions_are_private_and_symlinked_or_public_files_fail_closed(runtime, tmp_path):
    runtime.register()
    runtime.model["css"] += " drift"
    runtime.store.inspect(NAME)
    for path in runtime.path.rglob("*"):
        assert stat.S_IMODE(path.stat().st_mode) == (0o700 if path.is_dir() else 0o600)
    baseline = next((runtime.path / "baselines").glob("*.json"))
    baseline.chmod(0o644)
    assert runtime.store.inspect(NAME)["status"] == "unavailable"
    baseline.chmod(0o600)
    outside = tmp_path / "outside.json"
    baseline.rename(outside)
    baseline.symlink_to(outside)
    assert runtime.store.inspect(NAME)["status"] == "unavailable"
    assert outside.exists()


def test_failed_durable_state_write_does_not_return_normal(runtime, monkeypatch):
    runtime.register()
    def fail(_):
        raise OSError("disk full private details")
    monkeypatch.setattr(runtime.store, "_save_state", fail)
    result = runtime.store.inspect(NAME)
    assert result["status"] == "unavailable" and result["write_blocked"]
    assert "private details" not in json.dumps(result)


def test_history_paginates_recent_incidents_with_only_safe_metadata(runtime):
    runtime.register()
    runtime.model["css"] = "PRIVATE_CSS_A"
    first = runtime.store.inspect(NAME)
    runtime.model = native()
    runtime.store.inspect(NAME)
    runtime.time += 1
    runtime.model["css"] = "PRIVATE_CSS_B"
    second = runtime.store.inspect(NAME)
    page = runtime.new_store().history(NAME, limit=1)
    assert page["total"] == 2 and page["next_offset"] == 1
    assert page["incidents"][0]["incident_id"] == second["incident_id"]
    last = runtime.store.history(NAME, limit=1, offset=page["next_offset"])
    assert last["next_offset"] is None
    assert last["incidents"][0]["incident_id"] == first["incident_id"]
    assert last["incidents"][0]["resolution"] == "observed-applied-baseline"
    public = json.dumps([page, last])
    for private in ("PRIVATE_CSS", "assets_base64", "observed_bundle", "const x = 1", "operator_approval"):
        assert private not in public
    assert runtime.store.history(NAME, offset=20)["incidents"] == []
    assert runtime.store.history("Old KaTeX")["status"] == "unmanaged"


@pytest.mark.parametrize("pagination", [{"limit": 0}, {"limit": 101}, {"limit": True},
                                        {"offset": -1}, {"offset": 1.0}])
def test_history_rejects_invalid_pagination(runtime, pagination):
    with pytest.raises(ManagedDriftError, match="invalid-pagination"):
        runtime.store.history(NAME, **pagination)


@pytest.mark.parametrize("read", ["inspect", "history"])
def test_regular_reads_prune_expired_resolved_details_without_nested_lock(runtime, read):
    runtime.register()
    runtime.model["css"] = "old-drift"
    old = runtime.store.inspect(NAME)
    runtime.model = native()
    runtime.store.inspect(NAME)
    runtime.time += 90 * 86400
    getattr(runtime.new_store(), read)(NAME)
    assert not (runtime.path / "incidents" / (old["incident_id"] + ".json")).exists()
    assert runtime.store.get_baseline(NAME)["bundle"] == runtime.expected
