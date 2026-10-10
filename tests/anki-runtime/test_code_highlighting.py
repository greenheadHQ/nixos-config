"""Code highlighting plans against a disposable real Anki collection.

The backend validates generation, exact CAS and preservation; JavaScript and
client display still require the separate DOM suite and Mac/iPhone acceptance.
"""

import copy
import itertools
import os
from pathlib import Path

import pytest

from test_card_id_templates import _direct_add
from test_real_collection import HOST, add, load, runtime  # noqa: F401


planner = load("anki_code_highlight_runtime", HOST / "code_highlighting.py")
ASSET = "_anki-syntax-hljs-11.12.0-1234567890abcdef.min.js"
RENDERER = (HOST / "code-highlight-renderer.html").read_text(encoding="utf-8")
CSS = (HOST / "code-highlight.css").read_text(encoding="utf-8")
TARGETS = [
    {"template_name": "카드 1", "side": "front", "field_name": "질문"},
    {"template_name": "카드 1", "side": "back", "field_name": "답"},
    {"template_name": "카드 1", "side": "back", "field_name": "설명"},
]


def _model(r):
    return copy.deepcopy(r.col.models.by_name(planner.MODEL_NAME))


def _note_type(r, with_links=False):
    model = r.col.models.new(planner.MODEL_NAME)
    for name in ("질문", "답", "설명", "검토 메모"):
        r.col.models.add_field(model, r.col.models.new_field(name))
    template = r.col.models.new_template("카드 1")
    template["qfmt"] = '<div class="question">{{질문}}</div>'
    template["afmt"] = ('{{FrontSide}}<hr id="answer"><div class="answer">{{답}}</div>'
                        '{{#설명}}<div class="explanation linkRender">{{설명}}</div>{{/설명}}')
    if with_links:
        fixture_dir = Path(os.environ.get("ANKI_NOTE_LINK_FIXTURES", Path(__file__).parents[1] / "fixtures/anki-note-link"))
        previous = (fixture_dir / "renderer-v1.html").read_text(encoding="utf-8")
        template["afmt"] += previous
    r.col.models.add_template(model, template)
    model["css"] = ".question { font-weight: bold; } code { background: #eee; }"
    r.col.models.add(model)
    return model["name"]


def _plan(r):
    return planner.build_plan(_model(r), TARGETS, renderer=RENDERER, css=CSS, asset_filename=ASSET)


def _apply(r, plan, rollback=False):
    for entry in plan["changes"]:
        r.apply("model_template_update", entry["original" if rollback else "change"], schema=True)


def _rows(r):
    return {table: r.col.db.all(f"select * from {table} order by id") for table in ("notes", "cards", "revlog")}


def test_template_and_field_migration_preserve_scheduling_history_tags_and_other_content(runtime):
    r = runtime
    name = _note_type(r, with_links=True)
    original_fields = {
        "질문": '<p>문제</p><pre style="white-space:pre-wrap;overflow-wrap:anywhere"><code>const x = &quot;한글&quot;;\n\tconsole.log(x);</code></pre>',
        "답": "그대로인 답", "설명": "참고 설명", "검토 메모": "첫 문단\n\n둘째 문단",
    }
    nid = add(r, name, original_fields)
    unrelated = add(r, fields={"Front": "other type", "Back": "unmodified"})
    cid = r.col.get_note(nid).card_ids()[0]
    r.apply("set_due_date", {"card_ids": [cid], "days": "3"})
    r.apply("add_tags", {"note_ids": [nid], "tags": ["marked", "keep"]})
    r.col.set_user_flag_for_cards(4, [cid])
    before = _rows(r)
    assert before["revlog"], "Must preserve nonempty history."
    original_model = _model(r)
    original_tags = list(r.col.get_note(nid).tags)
    plan = _plan(r)
    _apply(r, plan)
    assert _rows(r) == before
    assert _model(r)["css"] == original_model["css"]
    assert _model(r)["req"] == original_model["req"]
    assert 'class="question anki-code-scope"' in r.col.get_card(cid).question()
    assert ASSET in r.col.get_card(cid).answer()
    assert "window.AnkiNoteLinkerMobileVersion = 4;" in _model(r)["tmpls"][0]["afmt"]

    patch = planner.build_field_patch(nid, original_fields, {"질문": ["javascript"]})
    r.apply("update_fields", patch["change"])
    after = _rows(r)
    assert after["cards"] == before["cards"]
    assert after["revlog"] == before["revlog"]
    assert list(r.col.get_note(nid).tags) == original_tags
    assert dict(r.col.get_note(nid).items()) == {**original_fields, **patch["change"]["fields"]}
    assert next(row for row in after["notes"] if row[0] == unrelated) == next(row for row in before["notes"] if row[0] == unrelated)

    r.apply("update_fields", patch["original"])
    _apply(r, plan, rollback=True)
    assert dict(r.col.get_note(nid).items()) == original_fields
    assert _rows(r)["cards"] == before["cards"]
    assert _rows(r)["revlog"] == before["revlog"]
    restored = _model(r)
    assert {key: value for key, value in restored.items() if key not in ("mod", "usn")} == {
        key: value for key, value in original_model.items() if key not in ("mod", "usn")}


def test_template_install_and_rollback_reject_newer_real_template_edits(runtime):
    r = runtime
    name = _note_type(r)
    plan = _plan(r)
    entry = plan["changes"][0]
    current = _model(r)["tmpls"][0]
    r.ac.updateModelTemplates(model={"name": name, "templates": {
        "카드 1": {"Front": current["qfmt"], "Back": current["afmt"] + "<!-- user edit -->"}}})
    with pytest.raises(r.error, match="expected-model-or-template-value-mismatch"):
        r.ops.prepare("model_template_update", entry["change"])
    r.ac.updateModelTemplates(model={"name": name, "templates": {
        "카드 1": {"Front": entry["change"]["expected_front"], "Back": entry["change"]["expected_back"]}}})
    _apply(r, plan)
    installed = _model(r)["tmpls"][0]
    r.ac.updateModelTemplates(model={"name": name, "templates": {
        "카드 1": {"Front": installed["qfmt"] + "<!-- user edit -->", "Back": installed["afmt"]}}})
    with pytest.raises(r.error, match="expected-model-or-template-value-mismatch"):
        r.ops.prepare("model_template_update", entry["original"])


def test_field_install_and_rollback_reject_newer_real_field_edits(runtime):
    r = runtime
    name = _note_type(r)
    fields = {"질문": "<pre><code>const x = 1;</code></pre>", "답": "answer", "설명": "", "검토 메모": "keep"}
    nid = add(r, name, fields)
    patch = planner.build_field_patch(nid, fields, {"질문": ["javascript"]})
    r.ac.updateNoteFields(note={"id": nid, "fields": {"질문": "newer user question"}})
    with pytest.raises(r.error, match="expected-field-value-mismatch"):
        r.ops.prepare("update_fields", patch["change"])
    r.ac.updateNoteFields(note={"id": nid, "fields": {"질문": fields["질문"]}})
    r.apply("update_fields", patch["change"])
    r.ac.updateNoteFields(note={"id": nid, "fields": {"질문": "newer edit after migration"}})
    with pytest.raises(r.error, match="expected-field-value-mismatch"):
        r.ops.prepare("update_fields", patch["original"])
    assert r.col.get_note(nid)["질문"] == "newer edit after migration"


def test_empty_question_and_optional_field_combinations_preserve_card_generation(runtime):
    r = runtime
    name = _note_type(r)
    before_model = _model(r)
    # Capture baseline generation on a separate same-definition type before the
    # targeted type changes. This avoids modifying the planner's supported name.
    clone = copy.deepcopy(before_model)
    clone["id"] = 0
    clone["name"] = "Unhighlighted baseline"
    r.col.models.add(clone)
    _apply(r, _plan(r))
    assert _model(r)["req"] == before_model["req"]
    for question in ("", " ", "<br>", "<div></div>", "&nbsp;", '<img src="fixture.png">', "question"):
        for answer, explanation, memo in itertools.product(("", "populated"), repeat=3):
            fields = {"질문": question, "답": answer, "설명": explanation, "검토 메모": memo}
            baseline = r.col.get_note(_direct_add(r, clone["name"], fields)).cards()
            actual = r.col.get_note(_direct_add(r, name, fields)).cards()
            assert [c.ord for c in actual] == [c.ord for c in baseline]


@pytest.mark.parametrize("mode", ["any", "all"])
@pytest.mark.parametrize("public_metadata", [False, True])
def test_native_generation_guards_support_context_cards_without_creating_extra_cards(
        runtime, mode, public_metadata):
    r = runtime
    name = _note_type(r)
    native = _model(r)
    r.col.models.add_field(native, r.col.models.new_field("맥락"))
    native["tmpls"][0]["qfmt"] = (
        '<div>{{질문}}</div>{{#맥락}}<div>{{맥락}}</div>{{/맥락}}' if mode == "any"
        else '{{#맥락}}<div>{{질문}}</div>{{/맥락}}')
    r.col.models.update_dict(native)
    r.col.models._clear_cache()
    native = _model(r)
    assert native["req"] == [[0, mode, [0, 4]]]
    clone = copy.deepcopy(native)
    clone.update(id=0, name="Unhighlighted generation baseline")
    r.col.models.add(clone)
    metadata = r.adapter.model_info(name) if public_metadata else native
    plan = planner.build_plan(metadata, TARGETS, renderer=RENDERER, css=CSS, asset_filename=ASSET)
    _apply(r, plan)
    assert _model(r)["req"] == native["req"]
    for question, context in itertools.product(("", "populated"), repeat=2):
        fields = {"질문": question, "맥락": context,
                  "답": '<pre><code class="language-javascript">const answer = 1;</code></pre>',
                  "설명": "", "검토 메모": "keep"}
        baseline = r.col.get_note(_direct_add(r, clone["name"], fields)).cards()
        actual = r.col.get_note(_direct_add(r, name, fields)).cards()
        assert [c.ord for c in actual] == [c.ord for c in baseline]
        if (any if mode == "any" else all)((question, context)):
            assert len(actual) == 1
            assert actual[0].question().count("<!-- anki-code-highlight-v1 -->") == 1
            assert actual[0].answer().count("<!-- anki-code-highlight-v1 -->") == 2


def test_shipped_managed_context_only_card_renders_code_features_on_both_sides(runtime):
    from importlib import import_module
    r = runtime
    bundle = import_module(r.helper.__package__ + ".managed_bundle")
    shipped, _ = bundle.load_bundle(Path(os.environ["ANKI_MANAGED_SOURCE"]))
    model = r.col.models.new(planner.MODEL_NAME)
    model.update(copy.deepcopy(shipped["definition"]))
    r.col.models.add(model)
    r.col.models._clear_cache()
    assert _model(r)["req"] == [[0, "any", [0, 2]]]
    nid = _direct_add(r, planner.MODEL_NAME, {
        "질문": "", "맥락": "Synthetic context",
        "답": '<pre><code class="language-javascript">const answer = 1;</code></pre>',
    })
    cards = r.col.get_note(nid).cards()
    assert len(cards) == 1
    assert cards[0].question().count("<!-- anki-code-highlight-v1 -->") == 1
    assert cards[0].answer().count("<!-- anki-code-highlight-v1 -->") == 2
    assert "const answer = 1;" in cards[0].answer()
