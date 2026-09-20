"""Pure, byte-preserving code metadata and scoped template migration plans."""

import copy
import json

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
        "id": 1787809609173, "name": "CS 재활 Basic", "type": 0,
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
    assert "window.AnkiNoteLinkerMobileVersion = 3;" in entry["change"]["back"]
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
