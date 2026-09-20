"""Keep literal note-link examples intact during desktop card rendering.

The upstream renderer substitutes across the complete HTML, including code and
scripts. Record source ranges instead of serializing an HTML tree: even entity
spellings, tag case, attribute quotes and whitespace must remain unchanged.
This is a rendering boundary only; the add-on's graph/index parser is unchanged.
"""

from bisect import bisect_right
from html.parser import HTMLParser
import re
from typing import Callable, Match, Pattern


class _LiteralRanges(HTMLParser):
    literal_tags = frozenset({"pre", "code", "script", "style", "textarea"})

    def __init__(self, source: str):
        super().__init__(convert_charrefs=False)
        self.source = source
        self.line_starts = [0] + [match.end() for match in re.finditer("\n", source)]
        self.stack = []
        self.start = None
        self.ranges = []

    def source_offset(self):
        line, column = self.getpos()
        return self.line_starts[line - 1] + column

    def handle_starttag(self, tag, attrs):
        if tag in self.literal_tags:
            if not self.stack:
                self.start = self.source_offset()
            self.stack.append(tag)

    def handle_startendtag(self, tag, attrs):
        # HTML ignores the self-closing slash on these non-void elements.
        self.handle_starttag(tag, attrs)

    def handle_endtag(self, tag):
        if tag not in self.stack:
            return
        # A malformed nested element must not expose the literal outer block.
        index = len(self.stack) - 1 - self.stack[::-1].index(tag)
        del self.stack[index:]
        if not self.stack:
            end = self.source.find(">", self.source_offset()) + 1
            self.ranges.append((self.start, end))
            self.start = None

    def finish(self):
        self.feed(self.source)
        self.close()
        if self.stack:
            # An unclosed literal element protects the rest of the fragment.
            self.ranges.append((self.start, len(self.source)))
        return self.ranges


def replace_links_outside_literals(
    text: str, pattern: Pattern[str], replacement: Callable[[Match[str]], str]
) -> str:
    """Apply the upstream replacement except where a match touches literal HTML."""
    try:
        ranges = _LiteralRanges(text).finish()
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
