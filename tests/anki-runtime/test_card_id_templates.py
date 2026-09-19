"""Card-ID plans against disposable, real Anki collections.

These checks exercise template rendering/card generation, not JavaScript or
the macOS/iPhone clipboard. Device paste readback is a separate acceptance gate.
"""

import copy
from html.parser import HTMLParser
import itertools
from pathlib import Path

import pytest

from test_real_collection import HOST, add, load, runtime  # noqa: F401
from test_review_memos import _case as memo_case


planner = load("anki_card_id_planner", HOST / "card_id.py")
WIDGET = (HOST / "card-id-button.html").read_text(encoding="utf-8")


def _rows(r):
    return {table: r.col.db.all(f"select * from {table} order by id")
            for table in ("notes", "cards", "revlog")}


def _sides(r, cid):
    card = r.col.get_card(cid)
    return card.question(), card.answer()


def _model(r, name):
    return copy.deepcopy(r.col.models.by_name(name))


def _custom(r, mode):
    model = r.col.models.new("Card-ID synthetic " + mode)
    for name in ("Question", "Answer", "Gate"):
        r.col.models.add_field(model, r.col.models.new_field(name))
    template = r.col.models.new_template("Question")
    template["qfmt"] = ("{{#Gate}}{{Question}}{{/Gate}}" if mode == "all"
                        else "{{Question}}{{Answer}}")
    template["afmt"] = "{{Answer}}<hr>{{Question}}"
    r.col.models.add_template(model, template)
    model["css"] = ".card { color: #246; } hr { opacity: .4; }"
    r.col.models.add(model)
    model = _model(r, model["name"])
    assert model["req"][0][1] == mode
    return model["name"], {"Question": "질문", "Answer": "답변", "Gate": "yes"}, 1


def _case(r, kind):
    if kind in ("all", "any"):
        return _custom(r, kind)
    if kind == "optional-reversed":
        return "Basic (optional reversed card)", {"Front": "사과", "Back": "apple", "Add Reverse": "1"}, 2
    return memo_case(r, kind)


def _direct_add(r, name, fields):
    note = r.col.new_note(r.col.models.by_name(name))
    for key, value in fields.items():
        note[key] = value
    r.col.add_note(note, 1)
    return note.id


def _apply(r, plan, rollback=False):
    for entry in plan["changes"]:
        r.apply("model_template_update", entry["original" if rollback else "change"], schema=True)


class _Controls(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "anki-cid-copy" in attrs.get("class", "").split():
            assert tag == "div"
            self.ids.append(attrs.get("data-anki-cid"))


def _assert_controls(r, nid):
    ids = r.col.get_note(nid).card_ids()
    for cid in ids:
        for rendered in _sides(r, cid):
            parser = _Controls()
            parser.feed(rendered)
            assert parser.ids == [str(cid)]
            assert "{{CardID}}" not in rendered
    return ids


def _without_widget(rendered, cid):
    return rendered.replace(WIDGET.replace("{{CardID}}", str(cid)), "")


KINDS = ["basic", "reversed", "optional-reversed", "cloze", "image-occlusion", "all", "any"]


@pytest.mark.parametrize("kind", KINDS)
def test_current_card_identity_original_content_and_rows_survive_apply_and_rollback(runtime, kind):
    r = runtime
    name, fields, count = _case(r, kind)
    nid = add(r, name, fields)
    # Avoid a false-positive test where note.id happens to equal card.id.
    # This is a disposable fixture before review rows are generated.
    r.col.db.execute("update cards set id=id+1000000 where nid=?", nid)
    ids = r.col.get_note(nid).card_ids()
    assert len(ids) == count and all(cid != nid for cid in ids)
    r.apply("set_due_date", {"card_ids": ids, "days": "3"})
    unrelated = add(r, fields={"Front": "unrelated fixture", "Back": "keep"})
    source = _model(r, name)
    source_copy = copy.deepcopy(source)
    before = _rows(r)
    assert before["revlog"], "Exercise preservation of actual scheduling history."
    original_render = {cid: _sides(r, cid) for cid in ids}
    unrelated_render = {cid: _sides(r, cid) for cid in r.col.get_note(unrelated).card_ids()}
    scm = r.col.db.scalar("select scm from col")
    io_indexes = (r.col._backend.get_image_occlusion_fields(source["id"])
                  if kind == "image-occlusion" else None)
    plan = planner.build_plan(source)
    assert source == source_copy, "Planning must not mutate caller metadata."
    assert plan["model_id"] == source["id"]
    _apply(r, plan)
    after_model = _model(r, name)
    assert _rows(r) == before
    assert r.col.db.scalar("select scm from col") == scm
    assert {key: value for key, value in after_model.items() if key not in ("tmpls", "mod", "usn")} == {
        key: value for key, value in source.items() if key not in ("tmpls", "mod", "usn")}
    if io_indexes is not None:
        assert r.col._backend.get_image_occlusion_fields(source["id"]) == io_indexes
    _assert_controls(r, nid)
    for cid in ids:
        assert tuple(_without_widget(side, cid) for side in _sides(r, cid)) == original_render[cid]
    # Basic is the subject in one parameter, so the unrelated note necessarily
    # shares its note type in that case. Its rows still remain byte-for-byte.
    if name != "Basic":
        assert {cid: _sides(r, cid) for cid in unrelated_render} == unrelated_render
    for fresh in (add(r, name, fields), _direct_add(r, name, fields)):
        assert len(_assert_controls(r, fresh)) == count
    before_rollback = _rows(r)
    _apply(r, plan, rollback=True)
    assert _rows(r) == before_rollback
    restored = _model(r, name)
    assert {key: value for key, value in restored.items() if key not in ("mod", "usn")} == {
        key: value for key, value in source.items() if key not in ("mod", "usn")}
    assert r.col.db.scalar("select scm from col") == scm
    for cid in ids:
        assert _sides(r, cid) == original_render[cid]


def _clone(r, source, suffix):
    clone = copy.deepcopy(source)
    clone["id"] = 0
    clone["name"] += suffix
    r.col.models.add(clone)
    return clone["name"]


def _compare_generation(r, original, changed, fields):
    before = r.col.get_note(_direct_add(r, original, fields)).cards()
    after = r.col.get_note(_direct_add(r, changed, fields)).cards()
    before.sort(key=lambda card: card.ord)
    after.sort(key=lambda card: card.ord)
    assert [card.ord for card in before] == [card.ord for card in after]
    for original_card, changed_card in zip(before, after, strict=True):
        # Empty Cloze/IO notes can show Anki's own error page. Preserve it;
        # do not claim that a clipboard control exists on an invalid card.
        assert tuple(_without_widget(side, changed_card.id) for side in _sides(r, changed_card.id)) == _sides(r, original_card.id)


@pytest.mark.parametrize("kind", KINDS)
def test_all_field_presence_combinations_preserve_generation(runtime, kind):
    r = runtime
    name, fields, _ = _case(r, kind)
    source = _model(r, name)
    changed = _clone(r, source, " copy-control")
    _apply(r, planner.build_plan(_model(r, changed)))
    assert _model(r, changed)["req"] == source["req"]
    # Every field combination includes optional reverse switches and all ANY
    # overlaps; a static unguarded control used to create unwanted cards here.
    names = list(fields)
    for populated in itertools.product((False, True), repeat=len(names)):
        variant = {name: fields[name] if present else ""
                   for name, present in zip(names, populated, strict=True)}
        _compare_generation(r, name, changed, variant)


@pytest.mark.parametrize("kind", ["reversed", "optional-reversed", "all", "any"])
def test_html_empty_and_media_fields_keep_card_generation_and_one_control(runtime, kind):
    r = runtime
    name, fields, _ = _case(r, kind)
    source = _model(r, name)
    changed = _clone(r, source, " media-copy-control")
    _apply(r, planner.build_plan(_model(r, changed)))
    required = {index for _, _, indexes in source["req"] for index in indexes}
    for index in required:
        field = source["flds"][index]["name"]
        for value in (" ", "\n", "<br>", "<div></div>", "&nbsp;",
                      '<img src="synthetic.png">', "[sound:synthetic.mp3]"):
            for base in (fields, {name: "" for name in fields}):
                _compare_generation(r, name, changed, {**base, field: value})


def test_known_malformed_cloze_tail_is_prefixed_without_repair(runtime):
    r = runtime
    model = _model(r, "Cloze")
    model["tmpls"][0]["afmt"] = "{{cloze:Text}}<br\n{{Back Extra}}"
    r.col.models.save(model)
    model = _model(r, "Cloze")
    nid = add(r, "Cloze", {"Text": "{{c1::answer}}", "Back Extra": "extra"})
    before = _sides(r, r.col.get_note(nid).card_ids()[0])
    plan = planner.build_plan(model)
    assert plan["changes"][0]["back_placement"] == "prefix-preserve-malformed-cloze"
    assert plan["changes"][0]["change"]["back"] == WIDGET + model["tmpls"][0]["afmt"]
    _apply(r, plan)
    cid = _assert_controls(r, nid)[0]
    assert tuple(_without_widget(side, cid) for side in _sides(r, cid)) == before


@pytest.mark.parametrize("requirement", [None, [], [[0, "none", []]], [[0, "any", []]],
                                          [[0, "all", [99]]], [[0, "any", [0, 0]]],
                                          [[0, "any", [True]]], [[1, "any", [0]]]])
def test_unknown_requirement_fails_before_producing_a_plan(runtime, requirement):
    model = _model(runtime, "Basic")
    model["req"] = requirement
    original = copy.deepcopy(model)
    with pytest.raises(ValueError, match="card-id-"):
        planner.build_plan(model)
    assert model == original


@pytest.mark.parametrize("side, html", [
    ("qfmt", "{{Front}}<script>unfinished"),
    ("qfmt", "{{Front}}<script/>"),
    ("qfmt", "{{Front}}<div title=\"unfinished"),
    ("qfmt", "{{Front}}<!-- unfinished"),
    ("qfmt", "{{Front}}<textarea>unfinished"),
    ("afmt", "{{Back}}<style>unfinished"),
    ("afmt", "{{Back}}<br"),
    ("afmt", "{{FrontSide}}{{FrontSide}}"),
    ("afmt", "{{#Back}}{{FrontSide}}{{/Back}}"),
    ("afmt", "{{text:FrontSide}}"),
    ("afmt", '<div title="{{FrontSide}}">back</div>'),
    ("afmt", "<!-- {{FrontSide}} -->"),
    ("afmt", "<script>{{FrontSide}}</script>"),
])
def test_unsupported_html_and_ambiguous_frontside_fail_closed(runtime, side, html):
    model = _model(runtime, "Basic")
    model["tmpls"][0][side] = html
    with pytest.raises(ValueError, match="card-id-"):
        planner.build_plan(model)


@pytest.mark.parametrize("tag", ["iframe", "noembed", "noframes", "noscript"])
@pytest.mark.parametrize("side", ["qfmt", "afmt"])
@pytest.mark.parametrize("ending", [">unfinished", "/>"])
def test_raw_text_tail_cannot_swallow_control(runtime, tag, side, ending):
    model = _model(runtime, "Basic")
    model["tmpls"][0][side] = "{{Front}}<" + tag + ending
    original = copy.deepcopy(model)
    with pytest.raises(ValueError, match="card-id-unfinished-"):
        planner.build_plan(model)
    assert model == original


@pytest.mark.parametrize("tag", ["iframe", "noembed", "noframes", "noscript"])
def test_raw_text_frontside_is_not_inherited(runtime, tag):
    model = _model(runtime, "Basic")
    model["tmpls"][0]["afmt"] = "<" + tag + ">{{FrontSide}}</" + tag + ">"
    with pytest.raises(ValueError, match="card-id-frontside-outside-html-content"):
        planner.build_plan(model)


@pytest.mark.parametrize("tag", ["iframe", "noembed", "noframes", "noscript"])
def test_closed_raw_text_keeps_control_outside(runtime, tag):
    r = runtime
    model = _model(r, "Basic")
    model["tmpls"][0]["qfmt"] = "{{Front}}<" + tag + ">fallback</" + tag + ">"
    model["tmpls"][0]["afmt"] = "{{Back}}<" + tag + ">fallback</" + tag + ">"
    r.col.models.save(model)
    model = _model(r, model["name"])
    nid = add(r, model["name"], {"Front": "synthetic question", "Back": "synthetic answer"})
    plan = planner.build_plan(model)
    assert plan["changes"][0]["change"]["front"].startswith(model["tmpls"][0]["qfmt"])
    assert plan["changes"][0]["change"]["back"].startswith(model["tmpls"][0]["afmt"])
    _apply(r, plan)
    _assert_controls(r, nid)


def test_double_installation_is_rejected_without_mutation(runtime):
    r = runtime
    plan = planner.build_plan(_model(r, "Basic"))
    _apply(r, plan)
    source = _model(r, "Basic")
    before = _rows(r)
    with pytest.raises(ValueError, match="card-id-already-installed"):
        planner.build_plan(source)
    assert _rows(r) == before and _model(r, "Basic") == source


def test_supplied_widget_does_not_read_a_default_file(runtime, monkeypatch):
    def forbidden_read(*args, **kwargs):
        raise AssertionError("An explicitly supplied widget must be self-contained")
    monkeypatch.setattr(Path, "read_text", forbidden_read)
    plan = planner.build_plan(_model(runtime, "Basic"), WIDGET)
    assert plan["changes"]
