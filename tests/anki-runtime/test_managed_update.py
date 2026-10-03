"""Deployed-source updates on generated collections with the real Anki backend.

No accounts, HTTP listeners, service calls or personal collection are involved.
The source fixture starts with the shipped definition, then only its presentation,
registered asset and the two allowed history-field options become the candidate.
"""
import copy
from datetime import datetime, timezone
import hashlib
import importlib
import json
import os
from pathlib import Path
import time
import types

import pytest

from test_real_collection import add, runtime  # noqa: F401


NAME = "학습 Basic"
HISTORY = "노트 변천사"
OPERATION = "1428" + "0" * 28
NEXT_OPERATION = "1428" + "1" * 28
PERSONAL_MEDIA = "personal-update-fixture.png"
PERSONAL_BYTES = b"unrelated synthetic personal media"


def sync_success(*, age=0, run_id="fixture-normal-sync"):
    finished = time.time() - age
    timestamp = lambda value: datetime.fromtimestamp(value, timezone.utc).isoformat()
    return {"runId": run_id, "runStartedAt": timestamp(finished - 1),
            "lastSuccessAt": timestamp(finished), "result": "success", "mode": "normal",
            "sync": {"action": "normal", "media": {"state": "synced"}}}


def write_source(state, definition, assets):
    bundle = state.bundle_module.build_bundle(definition, assets)
    for name, data in assets.items():
        (state.manager.source / "assets" / name).write_bytes(data)
    (state.manager.source / "bundle.json").write_text(json.dumps(bundle), encoding="utf-8")
    return bundle


def full_state(state):
    r = state.r
    return {
        "model": state.restore_module._native(r.col, state.model_id),
        "rows": state.restore_module._rows(r.col),
        "media": {path.name: path.read_bytes() for path in Path(r.col.media.dir()).iterdir()
                  if path.is_file()},
    }


def assert_unchanged(state, before):
    assert full_state(state) == before


@pytest.fixture
def managed_update(runtime, tmp_path, request):
    r = runtime
    bundle_module = importlib.import_module(r.helper.__package__ + ".managed_bundle")
    restore_module = importlib.import_module(r.helper.__package__ + ".managed_restore")
    runtime_module = importlib.import_module(r.helper.__package__ + ".managed_runtime")
    drift_module = importlib.import_module(r.helper.__package__ + ".managed_drift")
    shipped, assets = bundle_module.load_bundle(Path(os.environ["ANKI_MANAGED_SOURCE"]))
    definition = copy.deepcopy(shipped["definition"])
    history = next(field for field in definition["flds"] if field["name"] == HISTORY)
    history.update(collapsed=False, excludeFromSearch=False)
    two_templates = getattr(request, "param", False)
    if two_templates:
        second = copy.deepcopy(definition["tmpls"][0])
        second.update(name="Synthetic context card", ord=1, qfmt="{{맥락}}", afmt="{{답}}")
        definition["tmpls"].append(second)
        context_index = next(field["ord"] for field in definition["flds"] if field["name"] == "맥락")
        definition["req"].append([1, "any", [context_index]])
    model = r.col.models.new(NAME)
    model.update(definition)
    r.col.models.add(model)
    model_id = model["id"]
    r.col.models._clear_cache()
    native = restore_module._native(r.col, model_id)
    for name, data in assets.items():
        assert r.col.media.write_data(name, data) == name
    assert r.col.media.write_data(PERSONAL_MEDIA, PERSONAL_BYTES) == PERSONAL_MEDIA

    fields = {"질문": "Synthetic question", "답": "Synthetic answer", "맥락": "Synthetic context",
              "설명": "Keep explanation", "출처": "Keep reference", "검토 메모": "First memo\n\nSecond memo",
              HISTORY: "[지킬 것]\nKeep this decision\n\n[기록]\nKeep this history"}
    nid = add(r, NAME, fields)
    cid = r.col.get_note(nid).card_ids()[0]
    sibling_nid = add(r, NAME, {**fields, "질문": "Second synthetic question", "맥락": ""})
    unrelated_nid = add(r, "Basic (and reversed card)", {"Front": "Unrelated", "Back": "Preserve"})
    r.apply("add_tags", {"note_ids": [nid], "tags": ["marked", "preserve"]})
    r.apply("set_due_date", {"card_ids": [cid], "days": "3"})
    r.col.set_user_flag_for_cards(4, [cid])
    before_rows = restore_module._rows(r.col)
    assert before_rows["revlog"]

    source = tmp_path / "deployed-source"
    (source / "assets").mkdir(parents=True)
    original = bundle_module.build_bundle(native, assets)
    (source / "bundle.json").write_text(json.dumps(original), encoding="utf-8")
    for name, data in assets.items():
        (source / "assets" / name).write_bytes(data)
    sync = sync_success()
    backups = []

    def backup(operation_id):
        path = r.root / "restore-points" / (operation_id + ".colpkg")
        r.helper._export(str(path), False, False)
        backups.append(path)
        return {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "mirrored": True}

    def new_manager(source_revision="unknown"):
        return runtime_module.ManagedRuntime(
            r.window, tmp_path / "managed", source, instance="fixture",
            snapshot=r.helper._collection_identity, restore_point=backup,
            sync_status=lambda: copy.deepcopy(sync), ttl=600, source_revision=source_revision)

    manager = new_manager(source_revision="synthetic-revision")
    preview = manager.enrollment_prepare()
    manager.enrollment_apply(preview["operation_id"], preview["preview_token"], True)
    assert manager.check()["status"] == "normal"
    original_baseline = manager.store.get_baseline(NAME)
    target = copy.deepcopy(original["definition"])
    target["css"] += "\n/* synthetic source update */"
    target["tmpls"][0]["qfmt"] = "<section>" + target["tmpls"][0]["qfmt"] + "</section>"
    target["tmpls"][0]["afmt"] += "<small>Synthetic updated presentation</small>"
    next(field for field in target["flds"] if field["name"] == HISTORY).update(
        collapsed=True, excludeFromSearch=True)
    target_assets = dict(assets)
    changed_asset = next(iter(target_assets))
    target_assets[changed_asset] += b"\n/* synthetic source update */\n"
    state = types.SimpleNamespace(
        r=r, manager=manager, updates=manager.updates, new_manager=new_manager, sync=sync, backups=backups,
        bundle_module=bundle_module, restore_module=restore_module,
        errors=(r.error, bundle_module.ManagedBundleError, drift_module.ManagedDriftError),
        model_id=model_id, nid=nid, cid=cid, sibling_nid=sibling_nid, unrelated_nid=unrelated_nid,
        fields=fields, original=original, original_assets=assets, original_baseline=original_baseline,
        target=target, target_assets=target_assets, changed_asset=changed_asset,
    )
    state.target_bundle = write_source(state, target, target_assets)
    assert manager.check()["status"] == "normal"  # A pending source version is not live drift.
    r.adapter.managed_guard = manager.guard
    return state


def prepare(state, operation_id=OPERATION):
    preview = state.updates.prepare(operation_id, devices_ready=True)
    assert preview["state"] == "prepared", preview
    assert preview["operation_id"] == operation_id
    return preview


@pytest.mark.parametrize("managed_update", [False, True], indirect=True, ids=["single-template", "multiple-templates"])
def test_source_update_preserves_rows_native_ids_and_personal_media_and_publishes_baseline(managed_update, monkeypatch):
    s = managed_update
    before = full_state(s)
    preview = prepare(s)
    assert_unchanged(s, before)
    backup_count = len(s.backups)
    assert s.updates.prepare(OPERATION, devices_ready=True) == preview
    assert len(s.backups) == backup_count
    receipt = s.updates.apply(OPERATION, preview["preview_token"], True)
    assert receipt["state"] == "applied", receipt
    assert receipt["sync"]["state"] == "pending"
    after = full_state(s)
    assert after["rows"] == before["rows"]
    assert s.restore_module._identities(after["model"]) == s.restore_module._identities(before["model"])
    assert after["model"]["req"] == before["model"]["req"]
    assert s.bundle_module.canonical_model(after["model"]) == s.target_bundle["definition"]
    assert after["media"] == {**before["media"], **s.target_assets}
    assert after["media"][PERSONAL_MEDIA] == PERSONAL_BYTES
    assert dict(s.r.col.get_note(s.nid).items()) == s.fields
    assert set(s.r.col.get_note(s.nid).tags) >= {"marked", "preserve"}
    assert s.r.col.get_card(s.cid).flags == 4
    baseline = s.manager.store.get_baseline(NAME)
    assert baseline["model_id"] == s.model_id
    assert baseline["record_id"] != s.original_baseline["record_id"]
    assert baseline["bundle"] == s.target_bundle
    assert baseline["asset_bytes"] == s.target_assets
    assert s.updates.adapter.media_registered(baseline)
    assert s.manager.check()["status"] == "normal"
    assert s.manager.check()["changed_paths"] == []
    monkeypatch.setattr(s.updates.adapter, "apply", lambda *args: pytest.fail("must not apply twice"))
    assert s.updates.apply(OPERATION, preview["preview_token"], True) == receipt
    assert s.updates.status(OPERATION) == receipt
    assert_unchanged(s, after)


def test_source_update_delivery_needs_new_normal_sync_and_does_not_change_collection(managed_update):
    s = managed_update
    preview = prepare(s)
    receipt = s.updates.apply(OPERATION, preview["preview_token"], True)
    assert receipt["state"] == "applied", receipt
    before = full_state(s)
    assert s.updates.delivery(OPERATION)["sync"]["state"] != "synced"
    s.sync.clear()
    s.sync.update(sync_success(run_id="fixture-after-update-sync"))
    s.sync["runStartedAt"] = s.sync["lastSuccessAt"]
    assert s.updates.delivery(OPERATION)["sync"]["state"] == "synced"
    assert_unchanged(s, before)


@pytest.mark.parametrize("condition", ["not-ready", "missing", "expired", "failed", "not-normal", "full-upload", "media-pending"])
def test_source_update_requires_devices_and_fresh_normal_sync(managed_update, condition):
    s = managed_update
    if condition == "missing":
        s.sync.clear()
    elif condition == "expired":
        s.sync.clear()
        s.sync.update(sync_success(age=601))
    elif condition == "failed":
        s.sync["result"] = "failed"
    elif condition == "not-normal":
        s.sync["mode"] = "approved-schema"
    elif condition == "full-upload":
        s.sync["sync"]["action"] = "approved-full-upload"
    elif condition == "media-pending":
        s.sync["sync"]["media"]["state"] = "pending"
    before = full_state(s)
    backups = len(s.backups)
    with pytest.raises(s.errors):
        s.updates.prepare(OPERATION, devices_ready=condition != "not-ready")
    assert len(s.backups) == backups
    assert_unchanged(s, before)


@pytest.mark.parametrize("damage", ["drift", "missing-baseline"])
def test_source_update_only_starts_from_normal_registered_state(managed_update, damage):
    s = managed_update
    if damage == "drift":
        current = s.restore_module._native(s.r.col, s.model_id)
        current["css"] += "\n/* unreviewed app edit */"
        s.r.col.models.update_dict(current)
    else:
        (s.manager.root / "baselines" / (s.original_baseline["record_id"] + ".json")).unlink()
    before = full_state(s)
    with pytest.raises(s.errors):
        prepare(s)
    assert_unchanged(s, before)


@pytest.mark.parametrize("change", ["field-order", "field-name", "other-field-option", "history-font", "template-name", "browser-format", "req"])
def test_source_update_rejects_other_field_and_structural_changes_before_live_write(managed_update, change, monkeypatch):
    s = managed_update
    target = copy.deepcopy(s.target)
    if change == "field-order":
        # Swap two actual fields and repair their ordinals, so this is a valid
        # canonical definition with a forbidden new order, not malformed JSON.
        target["flds"][0], target["flds"][1] = target["flds"][1], target["flds"][0]
        for ordinal, field in enumerate(target["flds"]):
            field["ord"] = ordinal
    elif change == "field-name":
        target["flds"][-1]["name"] = "Renamed history"
    elif change == "other-field-option":
        target["flds"][0]["collapsed"] = True
    elif change == "history-font":
        next(field for field in target["flds"] if field["name"] == HISTORY)["font"] = "Courier"
    elif change == "template-name":
        target["tmpls"][0]["name"] = "Renamed card"
    elif change == "browser-format":
        target["tmpls"][0]["bqfmt"] = "{{질문}}"
    else:
        target["req"] = [[0, "all", [0, 1]]]
    write_source(s, target, s.target_assets)
    before = full_state(s)
    monkeypatch.setattr(s.updates.adapter, "apply", lambda *args: pytest.fail("invalid structure reached live apply"))
    with pytest.raises(s.errors):
        prepare(s)
    assert_unchanged(s, before)


def assert_rejected_in_real_trial(state, monkeypatch):
    before = full_state(state)
    entered = []
    verify_backup = state.updates.adapter.verify_backup

    def observed_trial(*args, **kwargs):
        entered.append(True)
        return verify_backup(*args, **kwargs)

    monkeypatch.setattr(state.updates.adapter, "verify_backup", observed_trial)
    with pytest.raises(state.errors, match="preservation|generation"):
        prepare(state)
    assert entered == [True]
    assert_unchanged(state, before)


def test_source_update_rejects_backend_recomputed_req_even_when_all_rows_would_be_preserved(managed_update, monkeypatch):
    s = managed_update
    target = copy.deepcopy(s.target)
    target["tmpls"][0]["qfmt"] = "{{답}}"
    assert target["req"] == s.original["definition"]["req"]
    write_source(s, target, s.target_assets)
    assert_rejected_in_real_trial(s, monkeypatch)


@pytest.mark.parametrize("managed_update", [True], indirect=True)
def test_source_update_rejects_front_change_that_would_generate_another_card(managed_update, monkeypatch):
    s = managed_update
    assert len(s.r.col.get_note(s.sibling_nid).card_ids()) == 1
    target = copy.deepcopy(s.target)
    target["tmpls"][1]["qfmt"] = "{{질문}}"
    assert target["req"] == s.original["definition"]["req"]
    write_source(s, target, s.target_assets)
    assert_rejected_in_real_trial(s, monkeypatch)


@pytest.mark.parametrize("change", ["source", "source-asset", "note", "review", "model", "binding", "baseline", "backup", "anki-version"])
def test_source_update_rejects_stale_preview_without_writing(managed_update, change, monkeypatch):
    s = managed_update
    preview = prepare(s)
    if change == "source":
        target = copy.deepcopy(s.target)
        target["css"] += "\n/* another deployed revision */"
        write_source(s, target, s.target_assets)
    elif change == "source-asset":
        write_source(s, s.target, {**s.target_assets, s.changed_asset: b"another deployed asset"})
    elif change == "note":
        note = s.r.col.get_note(s.nid)
        note[HISTORY] += "\nNew decision since preview"
        s.r.col.update_note(note)
    elif change == "review":
        s.r.apply("set_due_date", {"card_ids": [s.cid], "days": "5"})
    elif change == "model":
        current = s.restore_module._native(s.r.col, s.model_id)
        current["css"] += "\n/* app edit after preview */"
        s.r.col.models.update_dict(current)
    elif change == "binding":
        s.r.window.pm.name = "another-profile"
    elif change == "baseline":
        old = s.original_baseline
        replacement = s.manager.store.register_verified(
            NAME, s.model_id, old["bundle"], old["asset_bytes"], evidence=old["evidence"],
            verify_registration=lambda *_: True)
        assert replacement["record_id"] != old["record_id"]
    elif change == "backup":
        with s.backups[-1].open("ab") as stream:
            stream.write(b"corrupted after verification")
    else:
        monkeypatch.setattr(type(s.updates.adapter), "version", property(lambda _: "different-anki-version"))
    before = full_state(s)
    monkeypatch.setattr(s.updates.adapter, "apply", lambda *args: pytest.fail("stale preview reached live apply"))
    with pytest.raises(s.errors):
        s.updates.apply(OPERATION, preview["preview_token"], True)
    assert_unchanged(s, before)


@pytest.mark.parametrize("after_writes", [False, True], ids=["unknown-before-write", "partial-after-model"])
def test_source_update_uncertain_outcome_survives_restart_and_blocks_writes_and_enrollment(managed_update, monkeypatch, after_writes):
    s = managed_update
    preview = prepare(s)
    original_apply = s.updates.adapter.apply
    calls = []

    def interrupted(*args):
        calls.append(True)
        if after_writes:
            original_apply(*args)
        raise RuntimeError("injected lost response")

    monkeypatch.setattr(s.updates.adapter, "apply", interrupted)
    receipt = s.updates.apply(OPERATION, preview["preview_token"], True)
    assert receipt["state"] == ("partial" if after_writes else "unknown"), receipt
    assert len(calls) == 1
    assert s.manager.store.get_baseline(NAME)["record_id"] == s.original_baseline["record_id"]
    s.manager = s.new_manager()
    s.updates = s.manager.updates
    assert s.manager.source_revision == "unknown"
    assert s.updates._read(OPERATION)["source_revision"] == "synthetic-revision"
    assert s.updates.status(OPERATION)["state"] in ("partial", "unknown")
    s.r.adapter.managed_guard = s.manager.guard
    assert s.manager.check()["write_blocked"]
    with pytest.raises(s.errors):
        s.manager.enrollment_prepare()
    with pytest.raises(s.errors):
        s.r.ops.prepare("update_fields", {"note_id": s.nid, "fields": {HISTORY: "must not replace history"}})
    with pytest.raises(s.errors):
        s.updates.prepare(NEXT_OPERATION, devices_ready=True)
    before = full_state(s)
    monkeypatch.setattr(s.updates.adapter, "apply", lambda *args: pytest.fail("uncertain update must not repeat"))
    assert s.updates.apply(OPERATION, preview["preview_token"], True)["state"] in ("partial", "unknown")
    assert_unchanged(s, before)
    if after_writes:
        diagnosed = s.updates.diagnose(OPERATION)
        assert diagnosed["state"] == "applied", diagnosed
        assert s.manager.store.get_baseline(NAME)["bundle"] == s.target_bundle
        assert s.manager.store.get_baseline(NAME)["evidence"]["source"]["git_revision"] == "synthetic-revision"
        assert s.manager.check()["status"] == "normal"
        assert_unchanged(s, before)


@pytest.mark.parametrize("option", ["collapsed", "excludeFromSearch"])
def test_mcp_restore_still_rejects_history_option_changes(managed_update, option):
    s = managed_update
    current = s.restore_module._native(s.r.col, s.model_id)
    field = next(field for field in current["flds"] if field["name"] == HISTORY)
    field[option] = True
    s.r.col.models.update_dict(current)
    before = full_state(s)
    with pytest.raises(s.errors):
        s.manager.restores.prepare(NAME, "ordinary-restore-must-not-change-history-options")
    assert_unchanged(s, before)
