"""Same-version exported copies and actual media registration, no accounts."""
import copy
import hashlib
import importlib
from pathlib import Path
import types

import pytest

from test_real_collection import add, runtime  # noqa: F401


NAME = "CS 재활 Basic"
ASSET = "_managed-restore-fixture.js"


def setup(r):
    module = importlib.import_module(r.helper.__package__ + ".managed_restore")
    bundle_module = importlib.import_module(r.helper.__package__ + ".managed_bundle")
    model = copy.deepcopy(r.col.models.by_name("Basic"))
    model["name"] = NAME
    r.col.models.add_field(model, r.col.models.new_field("검토 메모"))
    r.col.models.update_dict(model)
    nid = add(r, NAME, {"Front": "Synthetic front", "Back": "Synthetic back",
                        "검토 메모": "First paragraph\n\nSecond paragraph"})
    cid = r.col.get_note(nid).card_ids()[0]
    r.apply("add_tags", {"note_ids": [nid], "tags": ["marked", "preserve"]})
    r.apply("set_due_date", {"card_ids": [cid], "days": "3"})
    r.col.set_user_flag_for_cards(4, [cid])
    unrelated = add(r, "Cloze", {"Text": "{{c1::unrelated}}", "Back Extra": "unchanged"})
    asset_bytes = {ASSET: b"const managed = 'original';\n"}
    assert r.col.media.write_data(ASSET, asset_bytes[ASSET]) == ASSET
    native = module._native(r.col, model["id"])
    baseline = {"model_id": model["id"], "model_name": NAME,
                "bundle": bundle_module.build_bundle(native, asset_bytes), "asset_bytes": asset_bytes,
                "record_id": "operator-verified-fixture", "binding": {"collection": "fixture"},
                "operator_verified": True, "evidence": {"test": "fixture"}}
    adapter = module.AnkiRestoreAdapter(r.window)

    def restore(opid):
        receipt = r.helper._export(str(r.root / "restore-points" / (opid + ".colpkg")), False, False)
        return {"path": receipt["path"], "mirrored": True,
                "sha256": hashlib.sha256(Path(receipt["path"]).read_bytes()).hexdigest()}

    engine = module.ManagedRestore(r.root / "managed-journal", types.SimpleNamespace(get_baseline=lambda name: baseline),
                                   adapter, restore, r.helper._collection_identity, lambda: {})
    return types.SimpleNamespace(module=module, adapter=adapter, baseline=baseline, engine=engine,
                                 nid=nid, cid=cid, unrelated=unrelated, native=native)


def drift(r, state):
    native = state.module._native(r.col, state.baseline["model_id"])
    native["css"] += "\n/* accidental app edit */"
    native["tmpls"][0]["qfmt"] = "<div>" + native["tmpls"][0]["qfmt"] + "</div>"
    native["tmpls"][0]["afmt"] += "<small>accidental</small>"
    r.col.models.update_dict(native)
    (Path(r.col.media.dir()) / ASSET).write_bytes(b"accidentally changed asset")


def test_full_restore_exact_rows_tags_memo_flags_and_registered_asset(runtime):
    r = runtime
    state = setup(r)
    drift(r, state)
    before = state.module._rows(r.col)
    assert before["revlog"]
    preview = state.engine.prepare(NAME, "real-restoration-1")
    assert preview["verification"]["anki_version"] == state.adapter.version
    assert state.module._rows(r.col) == before  # Preparing only mutates a discarded copy.
    receipt = state.engine.apply(preview["request_id"], preview["preview_token"], True)
    assert receipt["state"] == "applied", receipt
    assert receipt["sync"]["state"] == "pending"
    assert state.module._rows(r.col) == before
    assert state.adapter.media_registered(state.baseline)
    actual = state.adapter.capture(state.baseline)
    assert actual["asset_bytes"] == state.baseline["asset_bytes"]
    assert state.module.canonical_model(actual["model"]) == state.baseline["bundle"]["definition"]
    assert actual["model"]["req"] == state.native["req"]
    assert r.col.get_note(state.nid)["검토 메모"] == "First paragraph\n\nSecond paragraph"
    assert set(r.col.get_note(state.nid).tags) >= {"marked", "preserve"}
    assert r.col.get_card(state.cid).flags == 4
    assert [path.name for path in Path(r.col.media.dir()).iterdir()] == [ASSET]
    assert state.engine.apply(preview["request_id"], preview["preview_token"], True) == receipt


def test_saved_native_requirements_recomputed_in_trial_before_any_live_write(runtime):
    r = runtime
    state = setup(r)
    # A stored qfmt/req mismatch must be caught by the real backend even if a
    # caller copied an old req list into an otherwise valid bundle manifest.
    target = copy.deepcopy(state.native)
    target["tmpls"][0]["qfmt"] = "{{Back}}"
    state.baseline["bundle"] = state.module.build_bundle(target, state.baseline["asset_bytes"])
    before = state.module._rows(r.col)
    native_before = state.module._native(r.col, target["id"])
    with pytest.raises(r.error, match="isolated-preservation-or-generation-failed"):
        state.engine.prepare(NAME, "real-generation-reject")
    assert state.module._rows(r.col) == before
    assert state.module._native(r.col, target["id"]) == native_before


def test_missing_registered_asset_recovers_without_touching_personal_files(runtime):
    r = runtime
    state = setup(r)
    root = Path(r.col.media.dir())
    (root / ASSET).unlink()
    (root / "personal.png").write_bytes(b"personal fixture content")
    preview = state.engine.prepare(NAME, "real-missing-media-1")
    assert state.engine._read(preview["request_id"])["media_before"][ASSET] is None
    receipt = state.engine.apply(preview["request_id"], preview["preview_token"], True)
    assert receipt["state"] == "applied", receipt
    assert (root / "personal.png").read_bytes() == b"personal fixture content"
    assert state.adapter.media_registered(state.baseline)


def test_asset_symlink_is_rejected_without_changing_target(runtime):
    r = runtime
    state = setup(r)
    asset = Path(r.col.media.dir()) / ASSET
    asset.unlink()
    unrelated = r.root / "outside.js"
    unrelated.write_bytes(b"never touched")
    asset.symlink_to(unrelated)
    with pytest.raises(ValueError, match="asset-read-unavailable"):
        state.engine.prepare(NAME, "real-symlink-reject")
    assert unrelated.read_bytes() == b"never touched"


def test_native_model_read_does_not_trust_cached_dict(runtime):
    r = runtime
    state = setup(r)
    cached = r.col.models.get(state.native["id"])
    cached["css"] = "unsaved stale cache only"
    observed = state.adapter.capture(state.baseline)
    assert observed["model"]["css"] == state.native["css"]


def test_live_rows_changed_after_preview_prevents_restore(runtime):
    r = runtime
    state = setup(r)
    drift(r, state)
    preview = state.engine.prepare(NAME, "real-cas-reject")
    r.col.set_user_flag_for_cards(2, [state.cid])
    before = state.adapter.capture(state.baseline)
    with pytest.raises(r.error, match="stale-preview"):
        state.engine.apply(preview["request_id"], preview["preview_token"], True)
    assert state.adapter.capture(state.baseline) == before


def test_interrupted_after_model_commit_diagnoses_without_reapplying(runtime, monkeypatch):
    r = runtime
    state = setup(r)
    drift(r, state)
    preview = state.engine.prepare(NAME, "real-response-loss-1")
    apply = state.adapter.apply

    def lost_response(*args):
        apply(*args)
        raise RuntimeError("response lost after all commits")

    monkeypatch.setattr(state.adapter, "apply", lost_response)
    assert state.engine.apply(preview["request_id"], preview["preview_token"], True)["state"] == "partial"
    monkeypatch.setattr(state.adapter, "apply", lambda *args: pytest.fail("must not reapply"))
    assert state.engine.diagnose(preview["request_id"])["state"] == "applied"
