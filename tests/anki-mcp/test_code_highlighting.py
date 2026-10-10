"""Pure, byte-preserving code metadata and scoped template migration plans."""

import copy
from html.parser import HTMLParser
import json
from pathlib import Path

import pytest

from anki_host_fixture import code_highlighting as code


ASSET = "_anki-syntax-hljs-11.12.0-1234567890abcdef.min.js"
RENDERER = ('<!-- anki-code-highlight-v1 -->'
            '<script>const ASSET = __ANKI_SYNTAX_ASSET__; const CSS = __ANKI_SYNTAX_CSS__;</script>')
CSS = '.anki-code-scope pre { white-space: pre; }'
TARGETS = [
    {"template_name": "카드 1", "side": "front", "field_name": "질문"},
    {"template_name": "카드 1", "side": "back", "field_name": "답"},
    {"template_name": "카드 1", "side": "back", "field_name": "설명"},
]


def model():
    return {
        "id": 1787809609173, "name": "학습 Basic", "type": 0,
        "req": [[0, "any", [0]]],
        "flds": [{"name": name, "ord": i} for i, name in enumerate(("질문", "답", "설명", "검토 메모"))],
        "tmpls": [{"name": "카드 1", "ord": 0,
                   "qfmt": '<div class="question">{{질문}}</div><!-- existing cid widget -->',
                   "afmt": '{{FrontSide}}<hr><div class="answer">{{답}}</div>'
                           '{{#설명}}<div class="explanation linkRender">{{설명}}</div>{{/설명}}'}],
        "css": ".question { color: red; }",
    }


def plan(value=None, targets=None, **kwargs):
    return code.build_plan(value or model(), targets or TARGETS, renderer=RENDERER,
                           css=CSS, asset_filename=ASSET, **kwargs)


def test_template_plan_scopes_only_named_containers_and_binds_both_cas_directions():
    before = model()
    original = copy.deepcopy(before)
    result = plan(before)
    assert before == original
    entry = result["changes"][0]
    change = entry["change"]
    rollback = entry["original"]
    assert change["front"].startswith('<div class="question anki-code-scope">{{질문}}</div><!-- existing cid widget -->')
    assert '<div class="explanation linkRender anki-code-scope">{{설명}}</div>' in change["back"]
    for side in ("front", "back"):
        assert change[side].endswith("{{/질문}}")
        assert "{{#질문}}<!-- anki-code-highlight-v1 -->" in change[side]
        assert change["expected_" + side] == original["tmpls"][0]["qfmt" if side == "front" else "afmt"]
        assert rollback[side] == change["expected_" + side]
        assert rollback["expected_" + side] == change[side]
    assert rollback["expected_model_id"] == change["expected_model_id"] == before["id"]
    assert "css" not in change
    assert json.dumps(ASSET) in change["front"]
    assert "__ANKI_SYNTAX_" not in change["front"]


def test_public_model_metadata_is_supported():
    native = model()
    public = {"id": native["id"], "name": native["name"], "type": 0, "css": native["css"],
              "req": native["req"],
              "fields": [{"name": f["name"], "index": f["ord"]} for f in native["flds"]],
              "templates": [{"name": t["name"], "index": t["ord"], "front": t["qfmt"], "back": t["afmt"]}
                            for t in native["tmpls"]]}
    assert plan(public) == plan(native)


def test_css_json_cannot_terminate_the_inline_script():
    result = code.build_plan(model(), TARGETS, renderer=RENDERER,
                             css='/* </script><img src=x onerror=alert(1)> */', asset_filename=ASSET)
    front = result["changes"][0]["change"]["front"]
    assert front.count("</script>") == 1
    assert "\\u003c/script>" in front


@pytest.mark.parametrize("target", [
    {"template_name": "카드 1", "side": "front", "field_name": "검토 메모"},
    {"template_name": "missing", "side": "front", "field_name": "질문"},
    {"template_name": "카드 1", "side": "both", "field_name": "질문"},
])
def test_unsupported_targets_are_rejected(target):
    with pytest.raises(ValueError, match="unsupported-target"):
        plan(targets=[target])


def test_wrong_model_duplicate_targets_and_partial_installs_are_rejected():
    changed = model()
    changed["name"] = "KaTeX and Markdown Cloze"
    with pytest.raises(ValueError, match="unsupported-model"):
        plan(changed)
    with pytest.raises(ValueError, match="duplicate-target"):
        plan(targets=TARGETS + TARGETS[:1])
    changed = model()
    changed["tmpls"][0]["qfmt"] += "<!-- anki-code-scope -->"
    with pytest.raises(ValueError, match="partial-install"):
        plan(changed)


@pytest.mark.parametrize("question", [
    "{{질문}}{{질문}}", "<script>const x='{{질문}}';</script>",
    '<div data-field="{{질문}}">text</div>', '<div>{{질문}}<span>other</span></div>',
    '<div>{{질문}}</div><script>',
])
def test_ambiguous_or_noncontent_field_containers_are_rejected(question):
    changed = model()
    changed["tmpls"][0]["qfmt"] = question
    with pytest.raises(ValueError):
        plan(changed)


def test_migration_preserves_text_entities_whitespace_and_unrelated_html_exactly():
    source = ('<p>한글 <code>inline()</code></p><!-- <pre><code>ignore</code></pre> -->'
              '<pre class="keep" style="padding: 2px;white-space:pre-wrap;overflow-wrap:anywhere;color: red">'
              '<code class="sample">const 한글 = &quot;A&amp;B&quot;;\n\t&lt;script&gt;\n'
              '[literal|nid1787809736976]  </code></pre>'
              '<details><summary>보기</summary><pre><code>file → chunk</code></pre></details>')
    expected = source.replace('padding: 2px;white-space:pre-wrap;overflow-wrap:anywhere;color: red', 'padding: 2px;color: red')
    expected = expected.replace('<code class="sample">', '<code class="sample language-javascript">')
    expected = expected.replace('<pre><code>file', '<pre><code class="language-plaintext">file')
    assert code.migrate_code_blocks(source, ["javascript", "plaintext"]) == (expected, 2)


def test_reverse_field_patch_is_bound_to_exact_migration_output():
    fields = {"질문": "<pre><code>const x = 1;</code></pre>", "답": "unchanged", "검토 메모": "keep\nmultiple paragraphs"}
    original = copy.deepcopy(fields)
    patch = code.build_field_patch(12345, fields, {"질문": ["javascript"]})
    assert fields == original
    assert patch["blocks"] == 1
    assert patch["change"]["expected_fields"] == {"질문": fields["질문"]}
    assert patch["original"]["fields"] == patch["change"]["expected_fields"]
    assert patch["original"]["expected_fields"] == patch["change"]["fields"]
    assert patch["change"]["note_id"] == patch["original"]["note_id"] == 12345
    with pytest.raises(ValueError, match="unsupported-field"):
        code.build_field_patch(12345, fields, {"검토 메모": ["plaintext"]})


@pytest.mark.parametrize("source", [
    "<pre>plain</pre>", "<pre><code>unclosed", "<pre><code>x</code></div>",
    "<pre><code>x<br>y</code></pre>", "<pre><code><span>x</span></code></pre>",
    "<pre><code><!--x-->y</code></pre>", "<pre><code><?pi?>x</code></pre>",
    "<div/><pre><code>x</code></pre>", "<pre><code>x</code><code>y</code></pre>",
    "<pre>x<code>y</code></pre>", "<pre><code>x</code>y</pre>",
    '<pre><code class="language-js">x</code></pre>',
    '<pre><code data-language="js">x</code></pre>',
    '<pre><code class="a" class="b">x</code></pre>',
    '<pre style="color: rgb(0,0,0);white-space:pre-wrap"><code>x</code></pre>',
    '<pre style="white-space:pre-wrap" style="color:red"><code>x</code></pre>',
    '<pre style=white-space:pre-wrap><code>x</code></pre>',
    '<pre><code/>x</pre>',
])
def test_ambiguous_or_malformed_migration_fails_closed(source):
    with pytest.raises(ValueError):
        code.migrate_code_blocks(source, ["javascript"])


def test_migration_binds_inventory_count_and_supported_explicit_languages():
    source = "<pre><code>x</code></pre>"
    with pytest.raises(ValueError, match="block-count-mismatch"):
        code.migrate_code_blocks(source, ["javascript", "sql"])
    with pytest.raises(ValueError, match="unsupported-language"):
        code.migrate_code_blocks(source, ["auto"])
    for language in code.LANGUAGES:
        migrated, count = code.migrate_code_blocks(source, [language])
        assert f'class="language-{language}"' in migrated and count == 1
    with pytest.raises(ValueError, match="language-already-declared"):
        code.migrate_code_blocks(migrated, [language])


def _mobile_renderers():
    from pathlib import Path
    current = Path(code.__file__).with_name("note-link-renderer.html").read_text(encoding="utf-8")
    previous = (Path(__file__).parents[1] / "fixtures/anki-note-link/renderer-v1.html").read_text(encoding="utf-8")
    return previous, current


def test_exact_legacy_mobile_renderer_is_upgraded_and_rollback_keeps_original_bytes():
    previous, current = _mobile_renderers()
    before = model()
    before["tmpls"][0]["afmt"] += previous
    entry = plan(before)["changes"][0]
    assert current in entry["change"]["back"]
    assert previous not in entry["change"]["back"]
    assert entry["original"]["back"] == before["tmpls"][0]["afmt"]
    assert entry["change"]["expected_back"] == before["tmpls"][0]["afmt"]
    current_model = model()
    current_model["tmpls"][0]["afmt"] += current
    assert plan(current_model)["changes"][0]["change"]["back"].count(current) == 1


def test_exact_version_two_mobile_renderer_can_upgrade_without_losing_rollback():
    from pathlib import Path
    previous = (Path(__file__).parents[1] / "fixtures/anki-note-link/renderer-v2.html").read_text(encoding="utf-8")
    before = model()
    before["tmpls"][0]["afmt"] += previous
    entry = plan(before)["changes"][0]
    assert "window.AnkiNoteLinkerMobileVersion = 4;" in entry["change"]["back"]
    assert entry["original"]["back"] == before["tmpls"][0]["afmt"]


@pytest.mark.parametrize("mutation", ["trailing", "modified", "duplicate", "partial"])
def test_unknown_mobile_renderer_is_not_overwritten(mutation):
    previous, _ = _mobile_renderers()
    variants = {"trailing": previous + "<!-- user addition -->", "modified": previous.replace("const pattern", "let pattern"),
                "duplicate": previous + previous, "partial": "<!-- anki-note-link-mobile-renderer -->"}
    before = model()
    before["tmpls"][0]["afmt"] += variants[mutation]
    with pytest.raises(ValueError, match="unknown-note-link-renderer"):
        plan(before)


def test_context_only_card_receives_renderer_under_the_existing_any_requirement():
    before = model()
    before["flds"].append({"name": "맥락", "ord": 4})
    before["req"] = [[0, "any", [0, 4]]]
    before["tmpls"][0]["qfmt"] += '{{#맥락}}<div>{{맥락}}</div>{{/맥락}}'
    changed = plan(before)["changes"][0]["change"]
    rendered = RENDERER.replace("__ANKI_SYNTAX_ASSET__", json.dumps(ASSET)).replace(
        "__ANKI_SYNTAX_CSS__", json.dumps(CSS))
    expected = ("{{#질문}}" + rendered + "{{/질문}}"
                + "{{^질문}}{{#맥락}}" + rendered + "{{/맥락}}{{/질문}}")
    for side in ("front", "back"):
        assert changed[side].endswith(expected)


@pytest.mark.parametrize("requirements", [
    None, [], [[0, "none", []]], [[0, "all", []]], [[True, "any", [0]]],
    [[0, "any", [True]]], [[0, "any", [0, 0]]], [[0, "any", [-1]]],
    [[0, "any", [4]]], [[1, "any", [0]]], [[0, "any", [0]], [0, "any", [1]]],
])
def test_missing_or_unsupported_native_generation_is_not_guessed(requirements):
    before = model()
    before["req"] = requirements
    with pytest.raises(ValueError, match="requirement"):
        plan(before)


def test_all_requirement_does_not_enable_the_renderer_for_only_one_required_field():
    before = model()
    before["req"] = [[0, "all", [0, 2]]]
    for side in ("front", "back"):
        result = plan(before)["changes"][0]["change"][side]
        assert "{{#질문}}{{#설명}}<!-- anki-code-highlight-v1 -->" in result
        assert result.endswith("{{/설명}}{{/질문}}")


def _fenced_model():
    value = model()
    names = ("질문", "답", "맥락", "설명", "출처", "검토 메모", "노트 변천사")
    value["flds"] = [{"name": name, "ord": i} for i, name in enumerate(names)]
    value["req"] = [[0, "any", [0, 2]]]
    value["tmpls"][0]["qfmt"] = (
        '<div class="question">{{질문}}</div>'
        '{{#맥락}}<div class="context">{{맥락}}</div>{{/맥락}}'
        '{{#검토 메모}}<aside>{{검토 메모}}</aside>{{/검토 메모}}')
    value["tmpls"][0]["afmt"] = (
        '{{FrontSide}}<hr><div class="answer">{{답}}</div>'
        '{{#설명}}<div class="explanation linkRender">{{설명}}</div>{{/설명}}'
        '{{#출처}}<div class="source linkRender">{{출처}}</div>{{/출처}}'
        '{{#노트 변천사}}<aside>{{노트 변천사}}</aside>{{/노트 변천사}}')
    return value


class _FieldScopes(HTMLParser):
    """Inspect public plan HTML independently of the planner's container parser."""

    def __init__(self, source):
        super().__init__()
        self.fields = {}
        self.feed(source)

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        field = values.get("data-anki-fence-field")
        if field is not None:
            assert field not in self.fields
            self.fields[field] = values


def test_default_renderer_plan_enables_only_four_fields_and_preserves_cas_rollback():
    before = _fenced_model()
    original = copy.deepcopy(before)
    targets = [{"template_name": "카드 1", "side": side, "field_name": field}
               for side, field in (("front", "질문"), ("front", "맥락"),
                                   ("back", "답"), ("back", "설명"), ("back", "출처"))]
    entry = code.build_plan(before, targets)["changes"][0]
    changed, rollback = entry["change"], entry["original"]
    front, back = changed["front"], changed["back"]
    assert before == original
    front_scopes, back_scopes = _FieldScopes(front).fields, _FieldScopes(back).fields
    assert set(front_scopes) == {"질문"}
    assert set(back_scopes) == {"답", "설명", "출처"}
    scopes = {**front_scopes, **back_scopes}
    assert all(values.get("data-anki-fence-pending") == "" and
               "anki-code-scope" in values.get("class", "").split()
               for values in scopes.values())
    assert '<div class="context anki-code-scope">{{맥락}}</div>' in front
    assert '<aside>{{검토 메모}}</aside>' in front
    assert '<aside>{{노트 변천사}}</aside>' in back
    for side, key in (("front", "qfmt"), ("back", "afmt")):
        assert "window.AnkiFencedCodeV1" in changed[side]
        assert "__ANKI_FENCED_CODE__" not in changed[side]
        assert "__ANKI_SYNTAX_" not in changed[side]
        assert rollback[side] == changed["expected_" + side] == original["tmpls"][0][key]
        assert rollback["expected_" + side] == changed[side]
    assert changed["expected_model_id"] == rollback["expected_model_id"] == original["id"]
    assert "css" not in changed and "fields" not in changed


@pytest.mark.parametrize("mode", ["any", "all"])
def test_default_renderer_gates_static_style_and_parser_with_native_generation_conditions(mode):
    before = _fenced_model()
    before["req"] = [[0, mode, [0, 2]]]
    targets = [{"template_name": "카드 1", "side": side, "field_name": field}
               for side, field in (("front", "질문"), ("back", "답"))]
    changed = code.build_plan(before, targets)["changes"][0]["change"]
    # Empty required fields must not produce a card just because a gate/style or
    # parser was added. Only the native "any" rule admits a context-only card.
    gate = (("{{#질문}}" + code.FENCE_GATE + "{{/질문}}"
             + "{{^질문}}{{#맥락}}" + code.FENCE_GATE + "{{/맥락}}{{/질문}}")
            if mode == "any" else "{{#질문}}{{#맥락}}" + code.FENCE_GATE + "{{/맥락}}{{/질문}}")
    for side in ("front", "back"):
        assert changed[side].startswith(gate)
        if mode == "any":
            assert "{{#질문}}<!-- anki-code-highlight-v1 -->" in changed[side]
            assert "{{^질문}}{{#맥락}}<!-- anki-code-highlight-v1 -->" in changed[side]
        else:
            assert "{{#질문}}{{#맥락}}<!-- anki-code-highlight-v1 -->" in changed[side]
            assert "{{^질문}}" not in changed[side]
        assert changed[side].endswith("{{/맥락}}{{/질문}}")
    assert before["req"] == [[0, mode, [0, 2]]]


@pytest.mark.parametrize("legacy_version", [1, 2, 3])
def test_default_renderer_runs_before_mobile_note_links_and_can_roll_back_exact_legacy_source(legacy_version):
    previous, current = _mobile_renderers()
    if legacy_version != 1:
        previous = (Path(__file__).parents[1] / f"fixtures/anki-note-link/renderer-v{legacy_version}.html").read_text(encoding="utf-8")
    before = _fenced_model()
    before["tmpls"][0]["afmt"] += previous
    original_back = before["tmpls"][0]["afmt"]
    targets = [{"template_name": "카드 1", "side": "back", "field_name": field}
               for field in ("답", "설명", "출처")]
    entry = code.build_plan(before, targets)["changes"][0]
    changed = entry["change"]["back"]
    mobile_at = changed.index("<!-- anki-note-link-mobile-renderer -->")
    assert changed.index("window.AnkiFencedCodeV1") < mobile_at
    assert changed.rfind("{{/맥락}}{{/질문}}") < mobile_at
    assert changed.endswith(current)
    assert "window.AnkiNoteLinkerMobileVersion = 4;" in current
    assert changed.count(current) == 1
    assert entry["original"]["back"] == entry["change"]["expected_back"] == original_back
    assert entry["original"]["expected_back"] == changed


def test_real_renderer_rejects_duplicate_parser_slots_and_escapes_inline_script_boundaries():
    renderer = Path(code.__file__).with_name("code-highlight-renderer.html").read_text(encoding="utf-8")
    malformed = renderer.replace("__ANKI_FENCED_CODE__", "__ANKI_FENCED_CODE__;__ANKI_FENCED_CODE__")
    with pytest.raises(ValueError, match="invalid-fenced-fragment"):
        code.build_plan(model(), TARGETS, renderer=malformed)
    rendered = code.render_fragment(renderer, CSS, ASSET,
                                    fenced_source='/* </script><img src=x> */ window.testParser=true;')
    assert rendered.count("</script>") == 1
    assert "<\\/script>" in rendered
    assert "__ANKI_FENCED_CODE__" not in rendered
