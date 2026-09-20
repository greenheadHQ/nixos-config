"""Pure, reversible plans for explicitly scoped code highlighting.

No collection is opened here. Template and field writes use the existing host
operations and bind both installation and rollback to exact previous values.
The stored code is never parsed as Markdown or replaced with highlighted spans.
"""

from html.parser import HTMLParser
import hashlib
import json
from pathlib import Path
import re

from . import note_links


MODEL_NAME = "CS 재활 Basic"
MARKER = "anki-code-highlight-v1"
SCOPE_CLASS = "anki-code-scope"
# Exact mobile adapters from the note-link and code-highlighting rollouts.
# Only known bytes can be upgraded; user-modified renderers remain untouched.
_LEGACY_NOTE_LINK_SHA256 = frozenset({
    "17eaddd7b9d5192b418f19ee4a80feddcb5b6a666d01d84c302d531dcdf7ebec",  # v1
    "91445a7d0c242ec9a11237079942ba867eb3ba5c898ec561db35ddad58df58fd",  # v2
})
FIELDS = frozenset({"질문", "답", "맥락", "설명", "출처"})
LANGUAGES = frozenset({
    "javascript", "js", "jsx", "typescript", "ts", "tsx", "xml", "html",
    "css", "json", "bash", "shell", "sh", "sql", "c", "python", "py",
    "java", "yaml", "yml", "http", "plaintext", "text", "txt",
})


def _script_json(value):
    # JSON quoting alone does not protect an inline script from </script>.
    return json.dumps(value, ensure_ascii=True).replace("<", "\\u003c")


def _upgrade_note_links(source):
    marker = "<!-- anki-note-link-mobile-renderer -->"
    if "anki-note-link-mobile-renderer" not in source:
        return source
    if source.count("anki-note-link-mobile-renderer") != 1 or marker not in source:
        raise ValueError("code-highlight-unknown-note-link-renderer")
    start = source.index(marker)
    suffix = source[start:]
    replacement = Path(__file__).with_name("note-link-renderer.html").read_text(encoding="utf-8")
    if suffix == replacement:
        return source
    if hashlib.sha256(suffix.encode("utf-8")).hexdigest() not in _LEGACY_NOTE_LINK_SHA256:
        raise ValueError("code-highlight-unknown-note-link-renderer")
    return source[:start] + replacement


def build_plan(model, targets, *, renderer=None, css=None, asset_filename=None):
    """Plan named containers on named sides; preserve the model's existing CSS.

    Like the note-link planner, accepts native or public model metadata and
    targets with template_name, side, field_name. The only supported note type
    is the user's explicitly selected Basic type, not legacy Markdown/Cloze.
    """
    source_dir = Path(__file__).parent
    if renderer is None:
        renderer = (source_dir / "code-highlight-renderer.html").read_text(encoding="utf-8")
    if css is None:
        css = (source_dir / "code-highlight.css").read_text(encoding="utf-8")
    if asset_filename is None:
        manifest = json.loads((source_dir.parent / "code-highlighting" / "dist" / "manifest.json").read_text(encoding="utf-8"))
        asset_filename = manifest["asset"]["filename"]
    if (not isinstance(asset_filename, str)
            or not re.fullmatch(r"_anki-syntax-hljs-[0-9.]+-[a-f0-9]{16}\.min\.js", asset_filename)):
        raise ValueError("code-highlight-invalid-asset")
    if (not isinstance(renderer, str) or MARKER not in renderer
            or renderer.count("__ANKI_SYNTAX_ASSET__") != 1
            or renderer.count("__ANKI_SYNTAX_CSS__") != 1
            or not note_links._append_safe(renderer) or not isinstance(css, str) or not css):
        raise ValueError("code-highlight-invalid-renderer")
    rendered = renderer.replace("__ANKI_SYNTAX_ASSET__", _script_json(asset_filename)).replace(
        "__ANKI_SYNTAX_CSS__", _script_json(css))
    normalized, field_names, templates = note_links._validated_model(model)
    if normalized["name"] != MODEL_NAME or normalized["type"] != 0 or "질문" not in field_names:
        raise ValueError("code-highlight-unsupported-model")
    if not isinstance(targets, list) or not targets:
        raise ValueError("code-highlight-missing-targets")
    installed = "".join(t[side] for t in normalized["tmpls"] for side in ("qfmt", "afmt"))
    if MARKER in installed or SCOPE_CLASS in installed:
        raise ValueError("code-highlight-partial-install")
    grouped = {}
    seen = set()
    for target in targets:
        if not isinstance(target, dict) or set(target) != {"template_name", "side", "field_name"}:
            raise ValueError("code-highlight-invalid-target")
        name, side, field = target["template_name"], target["side"], target["field_name"]
        if not all(isinstance(value, str) for value in (name, side, field)):
            raise ValueError("code-highlight-invalid-target")
        key = (name, side, field)
        if key in seen:
            raise ValueError("code-highlight-duplicate-target")
        if name not in templates or side not in ("front", "back") or field not in field_names or field not in FIELDS:
            raise ValueError("code-highlight-unsupported-target")
        seen.add(key)
        grouped.setdefault((name, side), []).append(field)
    changes = []
    for template in normalized["tmpls"]:
        if not any((template["name"], side) in grouped for side in ("front", "back")):
            continue
        original = {"model_name": normalized["name"], "template_name": template["name"],
                    "front": template["qfmt"], "back": template["afmt"]}
        change = dict(original)
        for side in ("front", "back"):
            if (template["name"], side) not in grouped:
                continue
            source = _upgrade_note_links(change[side])
            if not note_links._append_safe(source):
                raise ValueError("code-highlight-unfinished-template")
            for field in grouped[(template["name"], side)]:
                token = "{{" + field + "}}"
                if source.count(token) != 1:
                    raise ValueError("code-highlight-ambiguous-field")
                container = note_links._field_container(source, token)
                opening = note_links._add_link_class(container["opening"], container["attrs"], SCOPE_CLASS)
                source = source[:container["start"]] + opening + source[container["end"]:]
            # Static JS/style must not make an otherwise empty question generate
            # a card. The existing field containers and their guards stay intact.
            change[side] = source + "{{#질문}}" + rendered + "{{/질문}}"
        expected = {"expected_model_id": normalized["id"]}
        changes.append({
            "template_index": template["ord"],
            "change": {**change, **expected, "expected_front": original["front"], "expected_back": original["back"]},
            "original": {**original, **expected, "expected_front": change["front"], "expected_back": change["back"]},
        })
    return {"model_id": normalized["id"], "model_name": normalized["name"],
            "targets": [dict(target) for target in targets], "asset_filename": asset_filename, "changes": changes}


class _CodeBlocks(HTMLParser):
    """Locate strict pre > code pairs without serializing surrounding HTML."""

    def __init__(self, source):
        super().__init__(convert_charrefs=False)
        self.source = source
        self.line_starts = [0] + [match.end() for match in re.finditer("\n", source)]
        self.stack = []
        self.pre = None
        self.blocks = []

    def _offset(self):
        line, column = self.getpos()
        return self.line_starts[line - 1] + column

    def _element(self, attrs):
        opening = self.get_starttag_text()
        raw = note_links._raw_attributes(opening)
        if ([name for name, _ in attrs] != [item["name"] for item in raw]
                or len({name for name, _ in attrs}) != len(attrs)):
            raise ValueError("code-highlight-ambiguous-attributes")
        return {"start": self._offset(), "end": self._offset() + len(opening),
                "opening": opening, "attrs": attrs, "raw": raw}

    def handle_starttag(self, tag, attrs):
        if self.pre is not None:
            if tag != "code" or self.stack[-1] != "pre" or self.pre.get("code") is not None:
                raise ValueError("code-highlight-nontext-code-block")
            self.pre["code"] = self._element(attrs)
        elif tag == "pre":
            self.pre = {"pre": self._element(attrs)}
        if tag not in note_links._VOID_TAGS:
            self.stack.append(tag)

    def handle_startendtag(self, tag, attrs):
        if self.pre is not None or tag not in note_links._VOID_TAGS:
            raise ValueError("code-highlight-malformed-code-block")

    def handle_endtag(self, tag):
        if not self.stack or self.stack[-1] != tag:
            raise ValueError("code-highlight-malformed-html")
        if self.pre is not None and tag == "pre":
            if "code" not in self.pre:
                raise ValueError("code-highlight-missing-code-element")
            self.blocks.append(self.pre)
            self.pre = None
        self.stack.pop()

    def handle_data(self, data):
        if self.pre is not None and self.stack[-1] == "pre" and data.strip():
            raise ValueError("code-highlight-nontext-code-block")

    def handle_entityref(self, name):
        if self.pre is not None and self.stack[-1] != "code":
            raise ValueError("code-highlight-nontext-code-block")

    handle_charref = handle_entityref

    def handle_comment(self, data):
        if self.pre is not None:
            raise ValueError("code-highlight-nontext-code-block")

    handle_pi = handle_comment

    def handle_decl(self, decl):
        if self.pre is not None:
            raise ValueError("code-highlight-nontext-code-block")


def _normalize_pre(element):
    opening = element["opening"]
    styles = [attr for attr in element["raw"] if attr["name"] == "style"]
    if not styles:
        return opening
    attr = styles[0]
    if attr["quote"] is None or attr["value_start"] is None:
        raise ValueError("code-highlight-ambiguous-style")
    value = opening[attr["value_start"]:attr["value_end"]]
    # Existing cards have simple declarations. Do not reinterpret CSS strings,
    # functions or entity-encoded values while making a byte-preserving edit.
    if any(char in value for char in "()'\"&{}\\") or "/*" in value:
        raise ValueError("code-highlight-ambiguous-style")
    pieces = re.findall(r"[^;]+;?|;", value)
    retained = []
    for piece in pieces:
        declaration = piece.rstrip(";").strip()
        if not declaration:
            retained.append(piece)
            continue
        match = re.fullmatch(r"([a-zA-Z-]+)\s*:\s*([^:;]+)", declaration)
        if not match:
            raise ValueError("code-highlight-ambiguous-style")
        if match[1].lower() not in ("white-space", "overflow-wrap"):
            retained.append(piece)
    return opening[:attr["value_start"]] + "".join(retained) + opening[attr["value_end"]:]


def migrate_code_blocks(source, languages):
    """Add only explicit language classes and remove two wrapping properties.

    Every real pre block must have one direct code child containing text only;
    the explicit language list binds the caller's inventory count and order.
    Malformed/ambiguous HTML fails instead of silently skipping a partial set.
    """
    if not isinstance(source, str) or not isinstance(languages, list) or not languages:
        raise ValueError("code-highlight-invalid-field-plan")
    if any(not isinstance(lang, str) or lang not in LANGUAGES for lang in languages):
        raise ValueError("code-highlight-unsupported-language")
    parser = _CodeBlocks(source)
    parser.feed(source)
    parser.close()
    if parser.rawdata or parser.stack or parser.pre is not None:
        raise ValueError("code-highlight-malformed-html")
    if len(parser.blocks) != len(languages):
        raise ValueError("code-highlight-block-count-mismatch")
    replacements = []
    for block, language in zip(parser.blocks, languages):
        code = block["code"]
        for name, value in code["attrs"]:
            if name in ("lang", "data-language", "data-lang") or (
                name == "class" and any(item.startswith(("language-", "lang-")) for item in (value or "").split())):
                raise ValueError("code-highlight-language-already-declared")
        opening = note_links._add_link_class(code["opening"], code["attrs"], "language-" + language)
        replacements.append((code["start"], code["end"], opening))
        pre = block["pre"]
        replacements.append((pre["start"], pre["end"], _normalize_pre(pre)))
    changed = source
    for start, end, replacement in sorted(replacements, reverse=True):
        changed = changed[:start] + replacement + changed[end:]
    return changed, len(parser.blocks)


def build_field_patch(note_id, fields, languages_by_field):
    """Return field operation inputs with symmetric exact-value CAS rollback."""
    if (type(note_id) is not int or note_id <= 0 or not isinstance(fields, dict)
            or not isinstance(languages_by_field, dict) or not languages_by_field):
        raise ValueError("code-highlight-invalid-note-plan")
    before, after, count = {}, {}, 0
    for name, languages in languages_by_field.items():
        if name not in FIELDS or name not in fields or not isinstance(fields[name], str):
            raise ValueError("code-highlight-unsupported-field")
        before[name] = fields[name]
        after[name], blocks = migrate_code_blocks(fields[name], languages)
        count += blocks
    return {
        "change": {"note_id": note_id, "fields": after, "expected_fields": before},
        "original": {"note_id": note_id, "fields": before, "expected_fields": after},
        "blocks": count,
    }
