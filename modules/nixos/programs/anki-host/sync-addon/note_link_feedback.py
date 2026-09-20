"""Read-only stored Note Linker candidate checks around one local mutation.

This is not a card renderer: model templates, client add-ons and conditional
visibility are not evaluated. Only pointers and occurrence counts reach the
journal; field content and display titles stay in memory.
"""

from collections import Counter
from html.parser import HTMLParser
import re


ACTIONS = frozenset({'add_notes', 'update_fields', 'update_fields_bulk', 'delete_notes', 'delete_decks'})
SCOPE = 'stored-note-link-candidates'
MAX_REFERENCES = 50
# Same neutral Note Linker syntax, after decoding HTML and joining inline text.
# A separator prevents matching across blocks, excluded elements or comments.
_PATTERN = re.compile(r'\[((?:[^\[\x00]|\\\[)*?)\|nid(\d{13})\]')
_EXCLUDED = {'a', 'pre', 'code', 'script', 'style', 'textarea', 'math', 'mjx-container',
             'title', 'xmp', 'plaintext', 'iframe', 'noembed', 'noframes', 'noscript', 'svg'}
_BLOCKS = {'address', 'article', 'aside', 'blockquote', 'div', 'dl', 'dt', 'dd', 'fieldset',
           'figure', 'figcaption', 'footer', 'form', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
           'header', 'hr', 'li', 'main', 'nav', 'ol', 'p', 'section', 'table', 'td', 'th',
           'tr', 'ul'}
_VOID = {'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta',
         'param', 'source', 'track', 'wbr'}
_MATH_CLASS = {'katex', 'katex-display', 'MathJax', 'MathJax_Display', 'mathjax'}
# These are common authoring examples, not clickable references. Preserve line
# breaks while masking them so fenced blocks and surrounding text stay separate.
_CODE_OR_MATH = re.compile(r'(`+)([\s\S]*?)\1|\\\([\s\S]*?\\\)|\\\[[\s\S]*?\\\]|\$\$[\s\S]*?\$\$|(?<!\$)\$[^$\n]+\$(?!\$)')
_FENCE = re.compile(r'^\s{0,3}(`{3,}|~{3,})')


class _Text(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.stack = []

    def boundary(self):
        self.parts.append('\x00\n')

    def handle_starttag(self, tag, attrs):
        if self.stack:
            if tag not in _VOID:
                self.stack.append(tag)
            return
        classes = dict(attrs).get('class') or ''
        if tag in _EXCLUDED or _MATH_CLASS.intersection(classes.split()):
            self.boundary()
            if tag not in _VOID:
                self.stack.append(tag)
        elif tag == 'br':
            self.boundary()
        elif tag in _BLOCKS or tag in _VOID:
            self.boundary()

    def handle_endtag(self, tag):
        if self.stack:
            if tag in self.stack and self.stack[0] != 'plaintext':
                index = len(self.stack) - 1 - self.stack[::-1].index(tag)
                del self.stack[index:]
            return
        if tag in _BLOCKS or tag in _EXCLUDED:
            self.boundary()

    def handle_startendtag(self, tag, attrs):
        # HTML treats non-void <script/> as an opening tag; conservative for all
        # excluded content, so malformed examples do not produce link warnings.
        self.handle_starttag(tag, attrs)

    def handle_data(self, data):
        if not self.stack:
            self.parts.append(data)

    def handle_comment(self, data):
        self.boundary()


def candidates(source):
    parser = _Text()
    parser.feed(source)
    parser.close()
    text = ''.join(parser.parts)
    lines = []
    fence = None
    for line in text.splitlines(keepends=True):
        logical = line.lstrip('\x00')
        marker = _FENCE.match(logical)
        if fence:
            if (marker and marker[1][0] == fence[0] and len(marker[1]) >= len(fence)
                    and not logical[marker.end():].replace('\x00', '').strip()):
                fence = None
            lines.append('\x00\n')
        elif marker and not (marker[1][0] == '`' and '`' in logical[marker.end():]):
            fence = marker[1]
            lines.append('\x00\n')
        else:
            lines.append(line)
    text = _CODE_OR_MATH.sub('\x00', ''.join(lines))
    found = Counter()
    for match in _PATTERN.finditer(text):
        start = match.start()
        index = start
        while index > 0 and text[index - 1] == '\\':
            index -= 1
        if (start - index) % 2 == 0:
            found[int(match[2])] += 1
    return found


def snapshot(rows, model_fields):
    """Scan complete (note id, model id, stored flds) rows, never mutate them."""
    existing = {row[0] for row in rows}
    missing = Counter()
    for nid, mid, fields in rows:
        names = model_fields[mid]
        values = fields.split('\x1f')
        if len(names) != len(values):
            raise ValueError('note-link-field-count-mismatch')
        for name, value in zip(names, values):
            for target, count in candidates(value).items():
                if target not in existing:
                    missing[(nid, name, target)] += count
    return {'notes': len(existing), 'missing': missing}


def compare(before, after):
    """Count newly missing occurrences, ignoring existing dangling references."""
    new = after['missing'] - before['missing']
    references = [{'source_note_id': nid, 'field_name': name, 'target_note_id': target,
                   'new_occurrences': new[(nid, name, target)]}
                  for nid, name, target in sorted(new)[:MAX_REFERENCES]]
    return {'state': 'checked', 'scope': SCOPE,
            'before_notes': before['notes'], 'after_notes': after['notes'],
            'new_missing_occurrences': sum(new.values()), 'new_missing_references': len(new),
            'references': references, 'truncated': len(new) > len(references)}


def unavailable(stage, error):
    # Exception messages can include field content or private paths.
    return {'state': 'unavailable', 'scope': SCOPE, 'stage': stage,
            'error': type(error).__name__}
