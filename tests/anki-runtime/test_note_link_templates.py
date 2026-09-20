"""Note-link template plans against a disposable real Anki collection.

The real renderer keeps scheduling and data intact. JavaScript click behavior is
an explicit Mac/iPhone acceptance gate because Anki's Python renderer does not
execute card-template JavaScript.
"""

import copy
from pathlib import Path

import pytest

from test_real_collection import HOST, add, load, runtime  # noqa: F401


card_ids = load("anki_card_id_for_note_links", HOST / "card_id.py")
note_links = load("anki_note_link_planner", HOST / "note_links.py")
RENDERER = (HOST / "note-link-renderer.html").read_text(encoding="utf-8")


def _rows(r):
    return {table: r.col.db.all(f"select * from {table} order by id")
            for table in ("notes", "cards", "revlog")}


def _model(r, name):
    return copy.deepcopy(r.col.models.by_name(name))


def _apply(r, plan, rollback=False):
    for entry in plan["changes"]:
        r.apply("model_template_update", entry["original" if rollback else "change"], schema=True)


def _note_type(r):
    model = r.col.models.new("Note link synthetic")
    for name in ("질문", "답", "설명", "출처"):
        r.col.models.add_field(model, r.col.models.new_field(name))
    template = r.col.models.new_template("카드 1")
    template["qfmt"] = "{{질문}}"
    template["afmt"] = (
        '{{FrontSide}}<hr id="answer"><div class="answer">{{답}}</div>'
        '{{#설명}}<div class="explanation">{{설명}}</div>{{/설명}}'
        '{{#출처}}<div class="source">{{출처}}</div>{{/출처}}'
    )
    r.col.models.add_template(model, template)
    model["css"] = ".explanation { color: #246; }"
    r.col.models.add(model)
    return model["name"]


def test_card_id_and_note_link_plans_compose_without_changing_collection_rows(runtime):
    r = runtime
    name = _note_type(r)
    target = add(r, name, {"질문": "target", "답": "answer", "설명": "", "출처": ""})
    source = add(r, name, {
        "질문": "source",
        "답": "answer",
        "설명": f"[target|nid{target}]",
        "출처": f"[source|nid{target}]",
    })
    cid = r.col.get_note(source).card_ids()[0]
    r.apply("set_due_date", {"card_ids": [cid], "days": "3"})
    before = _rows(r)

    cid_plan = card_ids.build_plan(_model(r, name))
    _apply(r, cid_plan)
    after_cid_model = _model(r, name)
    link_plan = note_links.build_plan(after_cid_model, [{
        "template_name": "카드 1", "side": "back", "field_name": "설명",
    }, {
        "template_name": "카드 1", "side": "back", "field_name": "출처",
    }], renderer=RENDERER)
    _apply(r, link_plan)

    assert _rows(r) == before
    rendered = r.col.get_card(cid).answer()
    assert rendered.count("anki-cid-copy") == 1
    assert '<div class="explanation linkRender">[target|nid' in rendered
    assert '<div class="source linkRender">[source|nid' in rendered
    assert rendered.count("anki-note-link-mobile-renderer") == 1
    assert "anki://x-callback-url/search?query=nid%3A" in rendered
    assert _model(r, name)["css"] == after_cid_model["css"]

    before_rollback = _rows(r)
    _apply(r, link_plan, rollback=True)
    assert _rows(r) == before_rollback
    restored = _model(r, name)
    assert {key: value for key, value in restored.items() if key not in ("mod", "usn")} == {
        key: value for key, value in after_cid_model.items() if key not in ("mod", "usn")}


def test_note_link_plan_and_rollback_refuse_stale_real_templates(runtime):
    r = runtime
    name = _note_type(r)
    plan = note_links.build_plan(_model(r, name), [{
        "template_name": "카드 1", "side": "back", "field_name": "설명",
    }], renderer=RENDERER)
    entry = plan["changes"][0]

    current = _model(r, name)["tmpls"][0]
    r.ac.updateModelTemplates(model={"name": name, "templates": {
        "카드 1": {"Front": current["qfmt"], "Back": current["afmt"] + "<!-- newer -->"},
    }})
    with pytest.raises(r.error, match="expected-model-or-template-value-mismatch"):
        r.ops.prepare("model_template_update", entry["change"])

    r.ac.updateModelTemplates(model={"name": name, "templates": {
        "카드 1": {"Front": entry["change"]["expected_front"],
                   "Back": entry["change"]["expected_back"]},
    }})
    _apply(r, plan)
    installed = _model(r, name)["tmpls"][0]
    r.ac.updateModelTemplates(model={"name": name, "templates": {
        "카드 1": {"Front": installed["qfmt"], "Back": installed["afmt"] + "<!-- newer -->"},
    }})
    with pytest.raises(r.error, match="expected-model-or-template-value-mismatch"):
        r.ops.prepare("model_template_update", entry["original"])
