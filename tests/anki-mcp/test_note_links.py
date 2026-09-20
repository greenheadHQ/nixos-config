"""Pure contracts for neutral note links and targeted template planning."""

import copy
import importlib.util
import json
from pathlib import Path
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "modules/nixos/programs/anki-host/sync-addon"


def _load():
    spec = importlib.util.spec_from_file_location("anki_note_links", SOURCE / "note_links.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


links = _load()
RENDERER = (SOURCE / "note-link-renderer.html").read_text(encoding="utf-8")


def _model(back='{{FrontSide}}<hr><div class="explanation">{{설명}}</div>'):
    return {
        "id": 1787809609173,
        "name": "CS 재활 Basic",
        "type": 0,
        "flds": [
            {"name": "질문", "ord": 0},
            {"name": "답", "ord": 1},
            {"name": "설명", "ord": 2},
            {"name": "출처", "ord": 3},
        ],
        "tmpls": [{
            "name": "카드 1",
            "ord": 0,
            "qfmt": '{{질문}}<!-- anki-cid-copy --><button data-anki-cid="{{CardID}}">copy</button>',
            "afmt": back,
        }],
    }


TARGET = [
    {"template_name": "카드 1", "side": "back", "field_name": "설명"},
    {"template_name": "카드 1", "side": "back", "field_name": "출처"},
]


def test_note_link_format_and_strict_legacy_conversion():
    assert links.format_note_link(1787809736976, "프로그램 [카운터]") == (
        r"[프로그램 \[카운터]|nid1787809736976]"
    )
    source = (
        '앞 <a href="anki://x-callback-url/search?query=nid%3A1787809736976">프로그램 카운터</a> 뒤 '
        "<a href='anki://x-callback-url/search?query=nid%3a1787809736977'>인터럽트</a>"
    )
    converted, count = links.convert_legacy_mobile_links(source)
    assert count == 2
    assert converted == (
        "앞 [프로그램 카운터|nid1787809736976] 뒤 "
        "[인터럽트|nid1787809736977]"
    )
    assert links.convert_legacy_mobile_links(converted) == (converted, 0)


def test_legacy_conversion_only_rewrites_real_plain_anchor_elements():
    anchor = '<a href="anki://x-callback-url/search?query=nid%3A1787809736976">target</a>'
    source = (
        f"<!-- {anchor} -->"
        f"<script>const sample = {anchor!r};</script>"
        f'<div data-sample="{anchor.replace(chr(34), "&quot;")}">keep</div>'
        f"<p>{anchor}</p>"
    )
    converted, count = links.convert_legacy_mobile_links(source)
    assert count == 1
    assert converted == source[:-len("</p>") - len(anchor)] + "[target|nid1787809736976]</p>"


def test_legacy_conversion_normalizes_entities_before_note_link_parsing():
    source = (
        '<a href="anki://x-callback-url/search?query=nid%3A1787809736976">'
        'A &#91;B&#93; &amp; C &lt; D</a>'
    )
    converted, count = links.convert_legacy_mobile_links(source)
    assert count == 1
    assert converted == r"[A \[B] &amp; C &lt; D|nid1787809736976]"

    ambiguous = source.replace("A &#91;B&#93; &amp; C &lt; D", "first&#124;nid1787809736977] tail")
    with pytest.raises(ValueError, match="note-link-ambiguous-title"):
        links.convert_legacy_mobile_links(ambiguous)


def test_note_link_format_rejects_a_title_that_can_terminate_the_desktop_marker_early():
    with pytest.raises(ValueError, match="note-link-ambiguous-title"):
        links.format_note_link(1787809736977, "first|nid1787809736976] tail")


@pytest.mark.parametrize("note_id", [True, 0, -1, 123, "178780973697", "17878097369760", "not-an-id"])
def test_note_link_format_rejects_non_13_digit_ids(note_id):
    with pytest.raises(ValueError, match="note-link-invalid-note-id"):
        links.format_note_link(note_id, "title")


def test_targeted_plan_preserves_unrelated_template_bytes_and_is_reversible():
    model = _model('{{FrontSide}}<hr><div class="explanation">{{설명}}</div><div>{{출처}}</div>')
    original = copy.deepcopy(model)
    plan = links.build_plan(model, TARGET, renderer=RENDERER)
    assert model == original
    assert plan["model_id"] == model["id"]
    assert plan["targets"] == TARGET
    assert len(plan["changes"]) == 1
    change = plan["changes"][0]
    assert change["original"] == {
        "model_name": model["name"],
        "template_name": "카드 1",
        "front": model["tmpls"][0]["qfmt"],
        "back": model["tmpls"][0]["afmt"],
        "expected_model_id": model["id"],
        "expected_front": change["change"]["front"],
        "expected_back": change["change"]["back"],
    }
    assert change["change"]["expected_model_id"] == model["id"]
    assert change["change"]["expected_front"] == model["tmpls"][0]["qfmt"]
    assert change["change"]["expected_back"] == model["tmpls"][0]["afmt"]
    assert change["change"]["front"] == model["tmpls"][0]["qfmt"]
    assert change["change"]["back"].startswith(
        '{{FrontSide}}<hr><div class="explanation linkRender">{{설명}}</div>'
        '<div class="linkRender">{{출처}}</div>'
    )
    assert change["change"]["back"].endswith(RENDERER)
    assert change["change"]["back"].count("anki-note-link-mobile-renderer") == 1


def test_plan_accepts_the_public_anki_model_info_projection():
    native = _model('{{FrontSide}}<div>{{설명}}</div><div>{{출처}}</div>')
    public = {
        "id": native["id"],
        "name": native["name"],
        "type": native["type"],
        "fields": [{"name": field["name"], "index": field["ord"]} for field in native["flds"]],
        "templates": [{
            "name": template["name"],
            "index": template["ord"],
            "front": template["qfmt"],
            "back": template["afmt"],
        } for template in native["tmpls"]],
    }
    original = copy.deepcopy(public)
    plan = links.build_plan(public, TARGET, renderer=RENDERER)
    assert public == original
    assert plan["changes"][0]["original"]["front"] == public["templates"][0]["front"]
    changed = plan["changes"][0]["change"]["back"]
    assert changed.count('class="linkRender"') == 2


def test_real_class_attribute_is_added_without_touching_class_text_inside_other_attributes():
    model = _model(
        '{{FrontSide}}<div data-note=" class=\'demo\'">{{설명}}</div><div>{{출처}}</div>'
    )
    changed = links.build_plan(model, TARGET, renderer=RENDERER)["changes"][0]["change"]["back"]
    assert 'data-note=" class=\'demo\'" class="linkRender"' in changed


@pytest.mark.parametrize(
    "model,targets,error",
    [
        (_model('{{FrontSide}}<div>{{설명}}</div><aside>{{설명}}</aside><div>{{출처}}</div>'), TARGET,
         "note-link-field-occurrence-ambiguous"),
        (_model('{{FrontSide}}<div data-value="{{설명}}">x</div><div>{{출처}}</div>'), TARGET,
         "note-link-field-unsupported-container"),
        (_model('{{FrontSide}}<script>{{설명}}</script><div>{{출처}}</div>'), TARGET,
         "note-link-field-unsupported-container"),
        (_model('{{FrontSide}}<noscript><div>{{설명}}</div></noscript><div>{{출처}}</div>'), TARGET,
         "note-link-field-unsupported-container"),
        (_model('{{FrontSide}}<span>{{설명}}</span><div>{{출처}}</div>'), TARGET,
         "note-link-field-unsupported-container"),
        (_model('{{FrontSide}}<div data-note=>{{설명}}</div><div>{{출처}}</div>'), TARGET,
         "note-link-unsupported-class-attribute"),
        (_model('{{FrontSide}}<div class="linkRender">{{설명}}</div><div>{{출처}}</div>'), TARGET,
         "note-link-partial-install"),
        (_model('{{FrontSide}}<div>{{설명}}</div><div>{{출처}}</div><!-- anki-note-link-mobile-renderer -->'), TARGET,
         "note-link-partial-install"),
        (_model(), [{"template_name": "카드 1", "side": "front", "field_name": "없는 필드"}],
         "note-link-unknown-field"),
        (_model('{{FrontSide}}<div>{{설명}}</div><div>{{출처}}</div>'), TARGET + TARGET,
         "note-link-duplicate-target"),
    ],
)
def test_unsafe_or_stale_targets_fail_closed(model, targets, error):
    original = copy.deepcopy(model)
    with pytest.raises(ValueError, match=error):
        links.build_plan(model, targets, renderer=RENDERER)
    assert model == original


def test_renderer_contract_is_mobile_only_idempotent_and_avoids_inner_html_rewrites():
    assert "window.AnkiNoteLinkerIsActive" in RENDERER
    assert "anki-note-link-mobile-renderer" in RENDERER
    assert "iphone" in RENDERER and "ipad" in RENDERER
    assert "createRange" in RENDERER and "createElement" in RENDERER
    assert "extractContents" in RENDERER
    assert "innerHTML" not in RENDERER
    assert "anki://x-callback-url/search?query=nid%3A" in RENDERER
    assert "ankiuser.net" not in RENDERER
    assert r"\[((?:[^\[]|\\\[)*?)\|nid(\d{13})\]" in RENDERER


def test_renderer_javascript_uses_the_first_delimiter_and_handles_multiple_markers():
    script = r"""
const fs = require("fs");
const source = fs.readFileSync(process.argv[1], "utf8");
const literal = source.match(/const pattern = \/(.*)\/g;/);
if (!literal) throw new Error("renderer pattern not found");
const pattern = new RegExp(literal[1], "g");
const inputs = [
  "[first|nid1111111111111] tail |nid2222222222222]",
  "[first|nid1111111111111] tail [second|nid2222222222222]",
];
const result = inputs.map(input => Array.from(input.matchAll(pattern), match => [match[0], match[1], match[2]]));
process.stdout.write(JSON.stringify(result));
"""
    completed = subprocess.run(
        ["node", "-e", script, str(SOURCE / "note-link-renderer.html")],
        check=True, capture_output=True, text=True,
    )
    assert json.loads(completed.stdout) == [
        [["[first|nid1111111111111]", "first", "1111111111111"]],
        [
            ["[first|nid1111111111111]", "first", "1111111111111"],
            ["[second|nid2222222222222]", "second", "2222222222222"],
        ],
    ]
