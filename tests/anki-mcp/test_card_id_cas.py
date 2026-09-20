"""Card-ID template plans carry exact forward and rollback preimages."""

import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "modules/nixos/programs/anki-host/sync-addon/card_id.py"


def _load():
    spec = importlib.util.spec_from_file_location("anki_card_id_cas", SOURCE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_card_id_plan_binds_forward_and_rollback_to_exact_template_preimages():
    planner = _load()
    model = {
        "id": 1787809609173,
        "name": "Synthetic Basic",
        "type": 0,
        "flds": [{"name": "Front", "ord": 0}, {"name": "Back", "ord": 1}],
        "tmpls": [{
            "name": "Card 1", "ord": 0,
            "qfmt": "{{Front}}", "afmt": "{{FrontSide}}<hr>{{Back}}",
        }],
        "req": [[0, "all", [0]]],
    }
    widget = '<!-- anki-cid-copy --><button data-anki-cid="{{CardID}}">copy</button>'
    entry = planner.build_plan(model, widget)["changes"][0]

    assert entry["change"]["expected_model_id"] == model["id"]
    assert entry["change"]["expected_front"] == model["tmpls"][0]["qfmt"]
    assert entry["change"]["expected_back"] == model["tmpls"][0]["afmt"]
    assert entry["original"]["expected_model_id"] == model["id"]
    assert entry["original"]["expected_front"] == entry["change"]["front"]
    assert entry["original"]["expected_back"] == entry["change"]["back"]
