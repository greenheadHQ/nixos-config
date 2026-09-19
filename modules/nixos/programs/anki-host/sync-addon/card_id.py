"""Plan a reversible card-ID control without changing note or card data.

This module is pure: it neither imports Anki nor reads a collection. Callers
must obtain a current native Anki model and apply each returned change through
the existing authorized model_template_update operation. Unsupported template
boundaries are rejected instead of repairing the user's original HTML.

Decision record (2026-09-19, issue 1328):
The user needs an identifier to copy into an LLM conversation, including when
asking to edit the parent note. Memorizing or permanently displaying it adds
no value. We use the renderer's current {{CardID}} and copy "cid:<ID>";
anki_find_cards already returns noteId, so callers can resolve the parent note.

We rejected storing a note ID in an extra field: newly created notes would
need that field populated, and imports can reassign IDs while retaining old
field values. Host-side repair would introduce a sync round trip before the
button could reliably identify newly created or imported notes. Direct CardID
rendering avoids that dependency and does not create a second source of truth.

The same card must copy the same ID on both sides; sibling cards must copy
their own IDs. Preserve card-generation conditions and existing note/card IDs,
fields, content, styling, schedules, and review history. Copying needs no host
connection; looking up a newly created card on the host still requires sync.
These reasons live with the implementation so the decision remains readable
without the issue tracker or another documentation platform.
"""

from html.parser import HTMLParser
from pathlib import Path
import re


MARKER = "anki-cid-copy"
_TOKEN = re.compile(r"\{\{([^{}]+)\}\}")
_RAW_TAGS = {"script", "style", "textarea", "title", "xmp", "plaintext"}


class _Boundary(HTMLParser):
    """Detect an unfinished tag/comment or an HTML raw-text context."""

    def __init__(self):
        super().__init__(convert_charrefs=False)
        self.raw_tags = []
        self.front_sides = 0

    def handle_starttag(self, tag, attrs):
        if tag in _RAW_TAGS:
            self.raw_tags.append(tag)
        if tag == "anki-front-side-placeholder" and not self.raw_tags:
            self.front_sides += 1

    def handle_endtag(self, tag):
        if self.raw_tags and tag == self.raw_tags[-1] and tag != "plaintext":
            self.raw_tags.pop()

    def handle_startendtag(self, tag, attrs):
        # HTML ignores the self-closing slash on raw-text elements. Treating
        # <script/> as closed would allow the appended widget to be swallowed.
        if tag in _RAW_TAGS:
            self.handle_starttag(tag, attrs)


def _append_safe(source):
    parser = _Boundary()
    parser.feed(source)
    # Do not close(): HTMLParser.close() converts unfinished input to ordinary
    # text, concealing the exact browser boundary we need to reject here.
    return not parser.rawdata and not parser.raw_tags


def _inherits_front(back):
    """Only accept one unconditional, unfiltered FrontSide in HTML content."""
    sections = []
    occurrences = 0
    for match in _TOKEN.finditer(back):
        token = match.group(1).strip()
        if token.startswith(("#", "^")):
            sections.append(token[1:].strip())
        elif token.startswith("/"):
            if not sections or sections.pop() != token[1:].strip():
                raise ValueError("card-id-unbalanced-back-conditions")
        elif token == "FrontSide":
            if sections or match.group(0) != "{{FrontSide}}":
                raise ValueError("card-id-conditional-or-nonliteral-frontside")
            occurrences += 1
        elif token.split(":")[-1] == "FrontSide":
            raise ValueError("card-id-filtered-frontside")
    if sections:
        raise ValueError("card-id-unbalanced-back-conditions")
    if occurrences > 1:
        raise ValueError("card-id-duplicate-frontside")
    if not occurrences:
        return False
    parser = _Boundary()
    parser.feed(back.replace("{{FrontSide}}", "<anki-front-side-placeholder></anki-front-side-placeholder>"))
    if parser.front_sides != 1:
        raise ValueError("card-id-frontside-outside-html-content")
    return True


def _guard(widget, mode, names):
    if mode == "all":
        return ("".join("{{#" + name + "}}" for name in names) + widget
                + "".join("{{/" + name + "}}" for name in reversed(names)))
    # The first populated field wins. Independent positive sections would
    # preserve card generation but render several controls when fields overlap.
    pieces = []
    for index, name in enumerate(names):
        earlier = names[:index]
        pieces.append("".join("{{^" + item + "}}" for item in earlier)
                      + "{{#" + name + "}}" + widget + "{{/" + name + "}}"
                      + "".join("{{/" + item + "}}" for item in reversed(earlier)))
    return "".join(pieces)


def build_plan(model, widget=None):
    """Return original/change pairs for a native Anki note-type dictionary.

    The front receives a control guarded by its existing ALL/ANY requirements.
    The back inherits an unconditional FrontSide, or receives its own control.
    A known legacy Cloze ``<br\n{{Back Extra}}`` tail requires prefix placement;
    any other unfinished boundary fails closed. Already installed controls and
    unknown/empty requirement modes are deliberately rejected, not reinstalled.
    """
    if widget is None:
        widget = Path(__file__).with_name("card-id-button.html").read_text(encoding="utf-8")
    if not isinstance(widget, str) or MARKER not in widget or 'data-anki-cid="{{CardID}}"' not in widget:
        raise ValueError("card-id-invalid-widget")
    if not _append_safe(widget):
        raise ValueError("card-id-unfinished-widget")
    if not isinstance(model, dict) or not isinstance(model.get("name"), str) or not model["name"]:
        raise ValueError("card-id-invalid-model")
    if (type(model.get("id")) is not int or model["id"] <= 0
            or type(model.get("type")) is not int or model["type"] not in (0, 1)):
        raise ValueError("card-id-invalid-model-identity")
    fields, templates, requirements = (model.get(key) for key in ("flds", "tmpls", "req"))
    if not all(isinstance(value, list) and value for value in (fields, templates, requirements)):
        raise ValueError("card-id-missing-model-metadata")
    names = []
    for index, field in enumerate(fields):
        if not isinstance(field, dict) or type(field.get("ord")) is not int or field["ord"] != index:
            raise ValueError("card-id-invalid-field-order")
        name = field.get("name")
        if (not isinstance(name, str) or not name or name != name.strip()
                or any(char in name for char in "{}") or name[0] in "#^/"):
            raise ValueError("card-id-unsupported-field-name")
        names.append(name)
    if len(set(names)) != len(names):
        raise ValueError("card-id-duplicate-field-name")
    req_by_ord = {}
    for requirement in requirements:
        if not isinstance(requirement, (list, tuple)) or len(requirement) != 3:
            raise ValueError("card-id-invalid-requirement")
        ordinal, mode, indexes = requirement
        if (type(ordinal) is not int or ordinal in req_by_ord or mode not in ("all", "any")
                or not isinstance(indexes, list) or not indexes
                or any(type(index) is not int or not 0 <= index < len(names) for index in indexes)
                or len(set(indexes)) != len(indexes)):
            raise ValueError("card-id-unsupported-requirement")
        req_by_ord[ordinal] = (mode, [names[index] for index in indexes])
    if set(req_by_ord) != set(range(len(templates))):
        raise ValueError("card-id-template-requirement-mismatch")
    changes = []
    template_names = set()
    for index, template in enumerate(templates):
        if (not isinstance(template, dict) or type(template.get("ord")) is not int or template["ord"] != index
                or not isinstance(template.get("name"), str) or not template["name"]
                or template["name"] in template_names
                or any(not isinstance(template.get(key), str) for key in ("qfmt", "afmt"))):
            raise ValueError("card-id-invalid-template")
        template_names.add(template["name"])
        front, back = template["qfmt"], template["afmt"]
        if MARKER in front + back or "anki-card-id" in front + back:
            raise ValueError("card-id-already-installed")
        if not _append_safe(front):
            raise ValueError("card-id-unfinished-front")
        original = {"model_name": model["name"], "template_name": template["name"],
                    "front": front, "back": back}
        change = dict(original)
        mode, required = req_by_ord[index]
        change["front"] += _guard(widget, mode, required)
        if _inherits_front(back):
            placement = "inherited-from-front"
        elif _append_safe(back):
            change["back"] += widget
            placement = "suffix"
        else:
            legacy_tail = "<br\n{{Back Extra}}"
            if model["type"] != 1 or not back.endswith(legacy_tail) or not _append_safe(back[:-len(legacy_tail)]):
                raise ValueError("card-id-unfinished-back")
            change["back"] = widget + back
            placement = "prefix-preserve-malformed-cloze"
        changes.append({"template_index": index, "back_placement": placement,
                        "original": original, "change": change})
    return {"model_id": model["id"], "model_name": model["name"], "changes": changes}
