"""Keep literal note-link examples intact during desktop card rendering.

The upstream renderer substitutes across the complete HTML, including code and
scripts. Record source ranges instead of serializing an HTML tree: even entity
spellings, tag case, attribute quotes and whitespace must remain unchanged.
This is a rendering boundary only; the add-on's graph/index parser is unchanged.
"""

from bisect import bisect_right
from html import unescape
from html.parser import HTMLParser
import re
from typing import Callable, Match, Pattern


class _FenceScope:
    """Read logical editor lines while retaining original HTML source offsets."""

    opening = re.compile(r"^ {0,3}(`{3,})([^`]*)$")
    closing = re.compile(r"^ {0,3}(`{3,})[ \t]*$")

    def __init__(self):
        self.parts = []
        self.start = None
        self.end = None
        self.pending = None
        self.ranges = []
        self.serial = 0
        self.has_tick = False

    def text(self, text, start, end):
        if not text:
            return
        if self.start is None:
            self.start = start
        self.end = end
        self.parts.append(text)
        self.has_tick = self.has_tick or "`" in text
        self.serial += 1

    def newline(self):
        if self.has_tick:
            line = "".join(self.parts)
            if self.pending:
                closing = self.closing.fullmatch(line)
                if closing and len(closing[1]) >= self.pending[0]:
                    self.ranges.append((self.pending[1], self.end))
                    self.pending = None
            else:
                opening = self.opening.fullmatch(line)
                if opening:
                    self.pending = (len(opening[1]), self.start)
        self.parts = []
        self.start = self.end = None
        self.has_tick = False
        self.serial += 1

    def boundary(self):
        # Adjacent DIV/P ends and starts describe one logical line boundary.
        if self.parts:
            self.newline()

    def barrier(self):
        # Existing code, hidden or non-text regions cannot supply fence lines.
        self.parts = []
        self.start = self.end = self.pending = None
        self.has_tick = False
        self.serial += 1

    def finish(self):
        self.boundary()
        # This is source protection, not DOM conversion validation. Even when
        # the later converter rejects unsafe content, its fence literals must
        # retain the title/nid spelling entered by the user.
        return self.ranges


class _Fences:
    """Opt-in fence protection inside the four managed display field markers."""

    fields = frozenset({"질문", "답", "설명", "출처"})
    void = frozenset({"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"})
    skipped = frozenset({"pre", "code", "script", "style", "textarea"})
    inline = frozenset({"span", "b", "i", "strong", "em", "a", "u", "s", "strike", "sub", "sup", "mark", "small", "font", "abbr", "kbd", "samp", "var", "wbr"})

    def __init__(self, parser):
        self.parser = parser
        self.frames = []
        self.scope = None
        self.blocked = 0
        self.ranges = []

    @staticmethod
    def hidden(attributes):
        # Use the last simple inline declaration, as the browser's CSSStyleDeclaration
        # does. The fence renderer also rejects hidden and aria-hidden elements.
        styles = {}
        for declaration in (attributes.get("style") or "").split(";"):
            key, separator, value = declaration.partition(":")
            if separator:
                styles[key.strip().lower()] = value.strip().lower().removesuffix("!important").strip()
        return ("hidden" in attributes or attributes.get("aria-hidden") == "true"
                or styles.get("display") == "none"
                or styles.get("visibility") in {"hidden", "collapse"}
                or styles.get("opacity") in {"0", "0.0", ".0"})

    def child(self):
        if self.frames:
            self.frames[-1]["children"] = True

    def offset(self):
        return self.parser.source_offset()

    def tag_end(self, start):
        # HTMLParser already found the exact start tag, including quoted '>'.
        return start + len(self.parser.get_starttag_text())

    def start(self, tag, attrs):
        start = self.offset()
        # Browsers close an editor P when another P/DIV starts, even if its
        # optional closing tag was omitted in the stored field HTML.
        if tag in {"div", "p"} and self.frames and self.frames[-1]["tag"] == "p":
            self.end("p", source_end=start)
        self.child()
        end = self.tag_end(start)
        attributes = dict(attrs)
        hidden = self.hidden(attributes)
        excluded = tag in self.skipped or hidden
        block = tag in {"div", "p"}
        opaque = not block and tag not in self.inline and tag != "br"
        previous = self.scope
        created = not self.blocked and attributes.get("data-anki-fence-field") in self.fields
        if created:
            if previous:
                previous.barrier()
            self.scope = _FenceScope()
        active = self.scope and not self.blocked
        if active and excluded and not hidden and tag in {"pre", "code", "textarea"}:
            if tag == "pre":
                self.scope.boundary()
            # Visible existing literals occupy their line; ignoring them would
            # invent a fence opener immediately after inline CODE/TEXTAREA.
            self.scope.text("\ufffc", start, end)
            if tag == "pre":
                self.scope.boundary()
        elif active and block and not created and not excluded:
            self.scope.boundary()
        if tag in self.void:
            if tag == "br" and active and not excluded:
                self.scope.newline()
            elif active and opaque and not excluded:
                self.scope.text("\ufffc", start, end)
            return
        if excluded:
            self.blocked += 1
        self.frames.append({"tag": tag, "excluded": excluded, "created": created,
                            "previous": previous, "scope": self.scope,
                            "block": block and not created, "opaque": opaque,
                            "start": start, "children": False,
                            "serial": self.scope.serial if self.scope else 0})

    def end(self, tag, source_end=None):
        if tag == "div" and self.frames and self.frames[-1]["tag"] == "p":
            self.end("p", source_end=self.offset())
        index = next((index for index in range(len(self.frames) - 1, -1, -1)
                      if self.frames[index]["tag"] == tag), None)
        if index is None:
            return
        # Closing malformed nested markup must not join previously split lines.
        if index != len(self.frames) - 1 and self.scope:
            self.scope.barrier()
        start = self.offset()
        end = source_end if source_end is not None else self.parser.source.find(">", start) + 1
        if end == 0:
            end = len(self.parser.source)
        while len(self.frames) > index:
            frame = self.frames.pop()
            scope = frame["scope"]
            if frame["excluded"]:
                self.blocked -= 1
            elif scope is not None and scope is self.scope and not self.blocked:
                if frame["block"]:
                    if scope.serial == frame["serial"]:
                        scope.newline()  # An empty DIV/P is a real empty editor line.
                    else:
                        scope.boundary()
                elif frame["opaque"] and not frame["children"]:
                    scope.text("\ufffc", frame["start"], end)
            if frame["created"]:
                self.ranges.extend(scope.finish())
                self.scope = frame["previous"]
                if self.scope:
                    self.scope.barrier()

    def data(self, data, start, end, encoded=False):
        self.child()
        if not self.scope or self.blocked:
            return
        cursor = 0
        for match in re.finditer(r"\r\n|\r|\n", data):
            self.scope.text(data[cursor:match.start()], start if encoded else start + cursor,
                            end if encoded else start + match.start())
            self.scope.newline()
            cursor = match.end()
        self.scope.text(data[cursor:], start if encoded else start + cursor, end)

    def finish(self):
        # HTMLParser does not synthesize end tags for an unclosed field container.
        while self.frames:
            self.end(self.frames[-1]["tag"])
        return self.ranges


class _LiteralRanges(HTMLParser):
    literal_tags = frozenset({"pre", "code", "script", "style", "textarea"})

    def __init__(self, source: str, protect_fences: bool = False):
        super().__init__(convert_charrefs=False)
        self.source = source
        self.line_starts = [0] + [match.end() for match in re.finditer("\n", source)]
        self.stack = []
        self.start = None
        self.ranges = []
        self.fences = _Fences(self) if protect_fences else None

    def source_offset(self):
        line, column = self.getpos()
        return self.line_starts[line - 1] + column

    def handle_starttag(self, tag, attrs):
        if self.fences:
            self.fences.start(tag, attrs)
        if tag in self.literal_tags:
            if not self.stack:
                self.start = self.source_offset()
            self.stack.append(tag)

    def handle_startendtag(self, tag, attrs):
        # HTML ignores the self-closing slash on these non-void elements.
        self.handle_starttag(tag, attrs)

    def handle_endtag(self, tag):
        if self.fences:
            self.fences.end(tag)
        if tag not in self.stack:
            return
        # A malformed nested element must not expose the literal outer block.
        index = len(self.stack) - 1 - self.stack[::-1].index(tag)
        del self.stack[index:]
        if not self.stack:
            end = self.source.find(">", self.source_offset()) + 1
            self.ranges.append((self.start, end))
            self.start = None

    def handle_data(self, data):
        if self.fences:
            start = self.source_offset()
            self.fences.data(data, start, start + len(data))

    def handle_comment(self, data):
        if self.fences:
            self.fences.child()

    def _entity(self, raw):
        if not self.fences or not self.fences.scope or self.fences.blocked:
            return
        start = self.source_offset()
        end = start + len(raw)
        if self.source[end:end + 1] == ";":
            end += 1
        self.fences.data(unescape(self.source[start:end]), start, end, encoded=True)

    def handle_entityref(self, name):
        self._entity("&" + name)

    def handle_charref(self, name):
        self._entity("&#" + name)

    def finish(self):
        self.feed(self.source)
        self.close()
        if self.stack:
            # An unclosed literal element protects the rest of the fragment.
            self.ranges.append((self.start, len(self.source)))
        if self.fences:
            self.ranges.extend(self.fences.finish())
        # Fence and existing literal spans share one overlap-safe interval index.
        merged = []
        for start, end in sorted(self.ranges):
            if merged and start <= merged[-1][1]:
                merged[-1] = (merged[-1][0], max(end, merged[-1][1]))
            else:
                merged.append((start, end))
        return merged


def replace_links_outside_literals(
    text: str, pattern: Pattern[str], replacement: Callable[[Match[str]], str],
    *, protect_fences: bool = False,
) -> str:
    """Apply the upstream replacement except where a match touches literal HTML."""
    try:
        ranges = _LiteralRanges(text, protect_fences).finish()
    except (AssertionError, NotImplementedError, ValueError):
        # Unsupported malformed declarations must not break card rendering.
        return text
    starts = [start for start, _ in ranges]

    def replace(match):
        index = bisect_right(starts, match.end() - 1) - 1
        if index >= 0 and ranges[index][1] > match.start():
            return match.group(0)
        return replacement(match)

    return pattern.sub(replace, text)
