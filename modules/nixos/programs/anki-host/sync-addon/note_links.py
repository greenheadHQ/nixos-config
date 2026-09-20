"""Plan reversible, explicitly targeted note-link template changes.

This module is pure: it neither imports Anki nor reads a collection. Desktop
Anki Note Linker and the mobile card-template adapter share the neutral
``[title|nid1234567890123]`` storage format. Callers must read the latest native
model (or the public ``anki_model_info`` projection), name every template side
and field to change, then apply the returned
original/change pair through the existing authorized model_template_update
operation.

The planner deliberately does not discover fields or repair HTML. A field token
must occur exactly once in ordinary HTML text. Stale, ambiguous and partially
installed templates fail before an update can be prepared.
"""

from html import escape, unescape
from html.parser import HTMLParser
from pathlib import Path
import re


MARKER = "anki-note-link-mobile-renderer"
LINK_CLASS = "linkRender"
_RAW_TAGS = {
    "script", "style", "textarea", "title", "xmp", "plaintext",
    "iframe", "noembed", "noframes", "noscript",
}
_BLOCK_CONTAINERS = {"article", "aside", "dd", "div", "li", "section", "td"}
_VOID_TAGS = {
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link",
    "meta", "param", "source", "track", "wbr",
}
_NOTE_ID = re.compile(r"\d{13}\Z")
_AMBIGUOUS_TITLE = re.compile(r"\|nid\d{13}\]", re.IGNORECASE)
_LEGACY_MOBILE_OPENING = re.compile(
    r"<a\s+href=(?P<quote>['\"])"
    r"anki://x-callback-url/search\?query=nid%3[aA](?P<nid>\d{13})"
    r"(?P=quote)>",
    re.IGNORECASE,
)
_LEGACY_MOBILE_CLOSING = re.compile(r"</a\s*>", re.IGNORECASE)


class _Boundary(HTMLParser):
    """Track unfinished/raw HTML and a synthetic field placeholder."""

    def __init__(self):
        super().__init__(convert_charrefs=False)
        self.raw_tags = []

    def handle_starttag(self, tag, attrs):
        if tag in _RAW_TAGS:
            self.raw_tags.append(tag)

    def handle_endtag(self, tag):
        if self.raw_tags and tag == self.raw_tags[-1] and tag != "plaintext":
            self.raw_tags.pop()

    def handle_startendtag(self, tag, attrs):
        # HTML treats raw-text <script/> like an opening tag.
        if tag in _RAW_TAGS:
            self.handle_starttag(tag, attrs)


def _append_safe(source):
    parser = _Boundary()
    parser.feed(source)
    return not parser.rawdata and not parser.raw_tags


class _ContainerLocator(HTMLParser):
    """Locate a block element whose complete template content is one token."""

    def __init__(self, source, token):
        super().__init__(convert_charrefs=False)
        self.source = source
        self.token = token
        self.stack = []
        self.raw_tags = []
        self.matches = []
        self.invalid = False
        self.line_starts = [0]
        for match in re.finditer("\n", source):
            self.line_starts.append(match.end())

    def _offset(self):
        line, column = self.getpos()
        return self.line_starts[line - 1] + column

    def _nontext(self):
        if self.stack:
            self.stack[-1]["nontext"] = True

    def handle_starttag(self, tag, attrs):
        if self.raw_tags:
            return
        self._nontext()
        if tag in _RAW_TAGS:
            self.raw_tags.append(tag)
            return
        if tag in _VOID_TAGS:
            return
        start = self._offset()
        opening = self.get_starttag_text()
        self.stack.append({
            "tag": tag,
            "start": start,
            "end": start + len(opening),
            "opening": opening,
            "attrs": attrs,
            "text": [],
            "nontext": False,
        })

    def handle_startendtag(self, tag, attrs):
        if self.raw_tags:
            return
        self._nontext()
        if tag in _RAW_TAGS:
            self.raw_tags.append(tag)

    def handle_endtag(self, tag):
        if self.raw_tags:
            if tag == self.raw_tags[-1] and tag != "plaintext":
                self.raw_tags.pop()
            return
        if not self.stack or self.stack[-1]["tag"] != tag:
            self.invalid = True
            return
        frame = self.stack.pop()
        if (tag in _BLOCK_CONTAINERS and not frame["nontext"]
                and "".join(frame["text"]).strip() == self.token):
            self.matches.append(frame)

    def handle_data(self, data):
        if self.stack and not self.raw_tags:
            self.stack[-1]["text"].append(data)

    def handle_entityref(self, name):
        self._nontext()

    def handle_charref(self, name):
        self._nontext()

    def handle_comment(self, data):
        self._nontext()

    def handle_decl(self, decl):
        self._nontext()


def _field_container(source, token):
    parser = _ContainerLocator(source, token)
    parser.feed(source)
    if parser.rawdata or parser.stack or parser.raw_tags or parser.invalid:
        raise ValueError("note-link-unfinished-template")
    if len(parser.matches) != 1:
        raise ValueError("note-link-field-unsupported-container")
    return parser.matches[0]


def _raw_attributes(opening):
    """Return raw attribute value spans without matching text inside quotes."""
    match = re.match(r"<\s*[^\s/>]+", opening)
    if not match:
        raise ValueError("note-link-unsupported-class-attribute")
    attrs = []
    index = match.end()
    while index < len(opening):
        while index < len(opening) and opening[index].isspace():
            index += 1
        if index >= len(opening) or opening[index] == ">" or opening.startswith("/>", index):
            break
        name_start = index
        while index < len(opening) and not opening[index].isspace() and opening[index] not in "=/>":
            index += 1
        if index == name_start:
            raise ValueError("note-link-unsupported-class-attribute")
        name = opening[name_start:index].lower()
        while index < len(opening) and opening[index].isspace():
            index += 1
        quote = None
        value_start = value_end = None
        if index < len(opening) and opening[index] == "=":
            index += 1
            while index < len(opening) and opening[index].isspace():
                index += 1
            if (index >= len(opening) or opening[index] == ">"
                    or opening.startswith("/>", index)):
                raise ValueError("note-link-unsupported-class-attribute")
            if opening[index] in "'\"":
                quote = opening[index]
                index += 1
                value_start = index
                while index < len(opening) and opening[index] != quote:
                    index += 1
                if index >= len(opening):
                    raise ValueError("note-link-unsupported-class-attribute")
                value_end = index
                index += 1
            else:
                value_start = index
                while index < len(opening) and not opening[index].isspace() and opening[index] not in "/>":
                    index += 1
                value_end = index
        attrs.append({"name": name, "quote": quote, "value_start": value_start, "value_end": value_end})
    return attrs


def _add_link_class(opening, parsed_attrs, class_name=LINK_CLASS):
    attrs = _raw_attributes(opening)
    # HTMLParser is the independent structural parser. Disagreement indicates
    # malformed or surprising markup, which a byte-preserving edit must reject.
    if [name.lower() for name, _ in parsed_attrs] != [attr["name"] for attr in attrs]:
        raise ValueError("note-link-unsupported-class-attribute")
    classes = [attr for attr in attrs if attr["name"] == "class"]
    if len(classes) > 1:
        raise ValueError("note-link-unsupported-class-attribute")
    if not classes:
        insert = len(opening) - 2 if opening.endswith("/>") else len(opening) - 1
        return opening[:insert] + f' class="{class_name}"' + opening[insert:]
    attr = classes[0]
    if attr["quote"] is None or attr["value_start"] is None:
        raise ValueError("note-link-unsupported-class-attribute")
    value = opening[attr["value_start"]:attr["value_end"]]
    if any(char in value for char in "{}&"):
        raise ValueError("note-link-unsupported-class-attribute")
    names = value.split()
    if class_name in names:
        raise ValueError("note-link-partial-install")
    value = (value + " " if value and not value[-1].isspace() else value) + class_name
    return opening[:attr["value_start"]] + value + opening[attr["value_end"]:]


class _LegacyAnchorLocator(HTMLParser):
    """Find only real, unnested legacy anchor elements and preserve all bytes."""

    def __init__(self, source):
        super().__init__(convert_charrefs=False)
        self.source = source
        self.line_starts = [0]
        for match in re.finditer("\n", source):
            self.line_starts.append(match.end())
        self.raw_tags = []
        self.anchor = None
        self.matches = []

    def _offset(self):
        line, column = self.getpos()
        return self.line_starts[line - 1] + column

    def handle_starttag(self, tag, attrs):
        if self.raw_tags:
            return
        if tag in _RAW_TAGS:
            self.raw_tags.append(tag)
            return
        if self.anchor is not None:
            self.anchor["invalid"] = True
            return
        if tag != "a":
            return
        opening = self.get_starttag_text()
        match = _LEGACY_MOBILE_OPENING.fullmatch(opening)
        if match:
            start = self._offset()
            self.anchor = {
                "start": start, "content_start": start + len(opening),
                "nid": match.group("nid"), "invalid": False,
            }

    def handle_startendtag(self, tag, attrs):
        if self.anchor is not None:
            self.anchor["invalid"] = True
        if tag in _RAW_TAGS and not self.raw_tags:
            self.raw_tags.append(tag)

    def handle_endtag(self, tag):
        if self.raw_tags:
            if tag == self.raw_tags[-1] and tag != "plaintext":
                self.raw_tags.pop()
            return
        if self.anchor is None:
            return
        if tag != "a":
            self.anchor["invalid"] = True
            return
        close_start = self._offset()
        closing = _LEGACY_MOBILE_CLOSING.match(self.source, close_start)
        anchor = self.anchor
        self.anchor = None
        title = self.source[anchor["content_start"]:close_start]
        if not anchor["invalid"] and closing and "<" not in title and ">" not in title:
            self.matches.append({
                "start": anchor["start"], "end": closing.end(),
                "nid": anchor["nid"], "title": title,
            })

    def handle_comment(self, data):
        if self.anchor is not None:
            self.anchor["invalid"] = True

    def handle_decl(self, decl):
        if self.anchor is not None:
            self.anchor["invalid"] = True


def format_note_link(note_id, title):
    """Return Anki Note Linker's neutral note-link syntax."""
    if (isinstance(note_id, bool)
            or not _NOTE_ID.fullmatch(str(note_id))):
        raise ValueError("note-link-invalid-note-id")
    if not isinstance(title, str):
        raise ValueError("note-link-invalid-title")
    if _AMBIGUOUS_TITLE.search(title):
        raise ValueError("note-link-ambiguous-title")
    escaped_title = title.replace("[", "\\[")
    return f"[{escaped_title}|nid{note_id}]"


def convert_legacy_mobile_links(source):
    """Convert only the old, plain-title AnkiMobile anchor shape.

    Callers must compare the returned count with their read-only inventory and
    reject any remaining legacy URLs before writing. Nested/attributed anchors
    are intentionally left untouched rather than guessed at.
    """
    if not isinstance(source, str):
        raise ValueError("note-link-invalid-source")
    parser = _LegacyAnchorLocator(source)
    parser.feed(source)
    parser.close()
    converted = source
    for match in reversed(parser.matches):
        # Desktop parses the stored HTML source while AnkiMobile parses decoded
        # DOM text. Normalize entities to the same visible title, apply Note
        # Linker escaping, then encode only HTML text metacharacters again.
        replacement = escape(format_note_link(match["nid"], unescape(match["title"])), quote=False)
        converted = converted[:match["start"]] + replacement + converted[match["end"]:]
    return converted, len(parser.matches)


def _validated_model(model):
    if not isinstance(model, dict) or not isinstance(model.get("name"), str) or not model["name"]:
        raise ValueError("note-link-invalid-model")
    if (type(model.get("id")) is not int or model["id"] <= 0
            or type(model.get("type")) is not int or model["type"] not in (0, 1)):
        raise ValueError("note-link-invalid-model-identity")
    native = "flds" in model or "tmpls" in model
    public = "fields" in model or "templates" in model
    if native and public:
        raise ValueError("note-link-mixed-model-metadata")
    if public:
        public_fields, public_templates = model.get("fields"), model.get("templates")
        if (not isinstance(public_fields, list) or not isinstance(public_templates, list)):
            raise ValueError("note-link-missing-model-metadata")
        fields = [{"name": field.get("name"), "ord": field.get("index")}
                  if isinstance(field, dict) else field for field in public_fields]
        templates = [{
            "name": template.get("name"),
            "ord": template.get("index"),
            "qfmt": template.get("front"),
            "afmt": template.get("back"),
        } if isinstance(template, dict) else template for template in public_templates]
        normalized = {**model, "flds": fields, "tmpls": templates}
    else:
        normalized = model
        fields, templates = model.get("flds"), model.get("tmpls")
    if not isinstance(fields, list) or not fields or not isinstance(templates, list) or not templates:
        raise ValueError("note-link-missing-model-metadata")
    field_names = []
    for index, field in enumerate(fields):
        if (not isinstance(field, dict) or type(field.get("ord")) is not int
                or field["ord"] != index or not isinstance(field.get("name"), str)
                or not field["name"] or field["name"] != field["name"].strip()
                or any(char in field["name"] for char in "{}")):
            raise ValueError("note-link-invalid-field")
        field_names.append(field["name"])
    if len(set(field_names)) != len(field_names):
        raise ValueError("note-link-duplicate-field")
    template_by_name = {}
    for index, template in enumerate(templates):
        if (not isinstance(template, dict) or type(template.get("ord")) is not int
                or template["ord"] != index or not isinstance(template.get("name"), str)
                or not template["name"] or template["name"] in template_by_name
                or any(not isinstance(template.get(key), str) for key in ("qfmt", "afmt"))):
            raise ValueError("note-link-invalid-template")
        template_by_name[template["name"]] = template
    return normalized, set(field_names), template_by_name


def build_plan(model, targets, renderer=None):
    """Return original/change pairs for explicitly named field containers.

    ``model`` may be Anki's native ``flds``/``tmpls`` dictionary or the MCP
    ``fields``/``templates`` projection. ``targets`` is a non-empty list of
    ``template_name``, ``side`` (front/back) and ``field_name`` dictionaries.
    Each literal field token's existing block container receives one class; the
    renderer is appended once to each changed side.
    """
    if renderer is None:
        renderer = Path(__file__).with_name("note-link-renderer.html").read_text(encoding="utf-8")
    if (not isinstance(renderer, str) or MARKER not in renderer
            or "window.AnkiNoteLinkerIsActive" not in renderer
            or f".{LINK_CLASS}" not in renderer or not _append_safe(renderer)):
        raise ValueError("note-link-invalid-renderer")
    normalized, field_names, template_by_name = _validated_model(model)
    if not isinstance(targets, list) or not targets:
        raise ValueError("note-link-missing-targets")

    installed_text = "".join(
        template[side] for template in normalized["tmpls"] for side in ("qfmt", "afmt")
    )
    if (MARKER in installed_text or "window.AnkiNoteLinkerIsActive" in installed_text
            or re.search(r"\blinkRender\b", installed_text)):
        raise ValueError("note-link-partial-install")

    grouped = {}
    normalized_targets = []
    seen = set()
    for target in targets:
        if not isinstance(target, dict) or set(target) != {"template_name", "side", "field_name"}:
            raise ValueError("note-link-invalid-target")
        template_name, side, field_name = (
            target["template_name"], target["side"], target["field_name"]
        )
        if (not all(isinstance(value, str) and value for value in (template_name, side, field_name))
                or side not in ("front", "back")):
            raise ValueError("note-link-invalid-target")
        key = (template_name, side, field_name)
        if key in seen:
            raise ValueError("note-link-duplicate-target")
        seen.add(key)
        if template_name not in template_by_name:
            raise ValueError("note-link-unknown-template")
        if field_name not in field_names:
            raise ValueError("note-link-unknown-field")
        grouped.setdefault((template_name, side), []).append(field_name)
        normalized_targets.append(dict(target))

    changes = []
    for template in normalized["tmpls"]:
        selected = {side: grouped[(template["name"], side)]
                    for side in ("front", "back") if (template["name"], side) in grouped}
        if not selected:
            continue
        original = {
            "model_name": normalized["name"],
            "template_name": template["name"],
            "front": template["qfmt"],
            "back": template["afmt"],
        }
        change = dict(original)
        for side, names in selected.items():
            key = "front" if side == "front" else "back"
            source = change[key]
            if not _append_safe(source):
                raise ValueError("note-link-unfinished-template")
            for name in names:
                token = "{{" + name + "}}"
                if source.count(token) != 1:
                    raise ValueError("note-link-field-occurrence-ambiguous")
                container = _field_container(source, token)
                opening = _add_link_class(container["opening"], container["attrs"])
                source = source[:container["start"]] + opening + source[container["end"]:]
            change[key] = source + renderer
        expected_model_id = normalized["id"]
        forward = {
            **change,
            "expected_model_id": expected_model_id,
            "expected_front": original["front"],
            "expected_back": original["back"],
        }
        rollback = {
            **original,
            "expected_model_id": expected_model_id,
            "expected_front": change["front"],
            "expected_back": change["back"],
        }
        changes.append({"template_index": template["ord"], "original": rollback, "change": forward})
    return {
        "model_id": normalized["id"],
        "model_name": normalized["name"],
        "targets": normalized_targets,
        "changes": changes,
    }
