import ast
import importlib.util
import os
from pathlib import Path
import re
import sys
from types import SimpleNamespace
import unittest


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "modules/shared/programs/anki-addons/note-linker-html.py"
PATTERN = re.compile(r"\[((?:[^\[]|\\\[)*?)\|nid(\d{13})\]")
MARKER = "[예제 &amp; 제목|nid1787809736976]"


def load_module(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


helper = load_module(HELPER, "note_linker_html")


def render(source, *, protect_fences=False):
    return helper.replace_links_outside_literals(
        source, PATTERN, lambda match: f"<LINK>{match.group(1)}</LINK>",
        protect_fences=protect_fences,
    )


class NoteLinkerLiteralTest(unittest.TestCase):
    def test_links_outside_literals_keep_existing_markup_and_escaping(self):
        source = '<div class="x">[<b>강조</b> \\[배열]|nid1787809736976]</div>'
        self.assertEqual(
            render(source),
            '<div class="x"><LINK><b>강조</b> \\[배열]</LINK></div>',
        )

    def test_each_literal_element_is_preserved_between_normal_links(self):
        for tag in ("pre", "code", "script", "style", "textarea"):
            with self.subTest(tag=tag):
                literal = f"<{tag}>{MARKER}</{tag}>"
                self.assertEqual(
                    render(MARKER + literal + MARKER),
                    "<LINK>예제 &amp; 제목</LINK>" + literal
                    + "<LINK>예제 &amp; 제목</LINK>",
                )

    def test_nested_highlight_spans_and_raw_bytes_are_unchanged(self):
        source = (
            "\r\n앞\n<PRE data-title='a > b'  class=example>\r\n"
            "<CODE>\t<span class='hljs-string'>[예제 &amp; 제목|nid1787809736976]</span>"
            " &lt; &nbsp; &#32; &#x20;\r\n</CODE> </PRE>\n뒤"
        )
        self.assertEqual(render(source), source)

    def test_nested_literals_close_only_at_outer_boundary(self):
        literal = f"<pre><code>{MARKER}</code>{MARKER}</pre>"
        self.assertEqual(render(literal + MARKER), literal + "<LINK>예제 &amp; 제목</LINK>")

    def test_malformed_nested_element_does_not_escape_outer_literal(self):
        literal = f"<pre><code>{MARKER}</pre>"
        self.assertEqual(render(literal + MARKER), literal + "<LINK>예제 &amp; 제목</LINK>")

    def test_unclosed_literals_fail_closed(self):
        for tag in ("pre", "code", "script", "style", "textarea"):
            with self.subTest(tag=tag):
                source = f"<{tag}>{MARKER}\n<div>{MARKER}</div>"
                self.assertEqual(render(source), source)

    def test_self_closing_nonvoid_element_still_protects_following_content(self):
        for tag in ("pre", "code", "script", "style", "textarea"):
            with self.subTest(tag=tag):
                literal = f"<{tag} />{MARKER}</{tag}>"
                self.assertEqual(
                    render(literal + MARKER), literal + "<LINK>예제 &amp; 제목</LINK>"
                )

    def test_raw_script_content_does_not_fake_code_boundaries(self):
        literal = f'<script>const value = "<code>{MARKER}</pre>";</script>'
        self.assertEqual(render(literal + MARKER), literal + "<LINK>예제 &amp; 제목</LINK>")

    def test_marker_straddling_literal_boundary_is_not_partially_rewritten(self):
        for source in (
            "[before <code>inside</code> after|nid1787809736976]",
            "<code>[before</code> after|nid1787809736976]",
            "[before<pre> after|nid1787809736976]</pre>",
        ):
            with self.subTest(source=source):
                self.assertEqual(render(source), source)

    def test_attribute_marker_on_literal_element_is_preserved(self):
        source = f'<code title="{MARKER}">{MARKER}</code>'
        self.assertEqual(render(source), source)

    def test_unknown_malformed_declaration_does_not_break_card(self):
        literal = f"<pre><code>{MARKER}</code></pre>"
        prefix = "<![unsupported]>" + literal
        source = prefix + MARKER
        # Python versions either reject this declaration (plaintext fallback)
        # or accept it as a bogus comment (normal outside-link rendering).
        # In both cases the card stays readable and code remains byte-identical.
        self.assertIn(render(source), (source, prefix + "<LINK>예제 &amp; 제목</LINK>"))

    def test_comments_do_not_open_literal_contexts(self):
        source = f"<!-- <pre> -->{MARKER}<!-- </pre> -->"
        self.assertEqual(
            render(source), "<!-- <pre> --><LINK>예제 &amp; 제목</LINK><!-- </pre> -->"
        )

    def test_plaintext_and_unrelated_html_are_identical(self):
        for source in ("", "\t한글\r\n", "<p x='>'>&amp; &#123; <br /></p>"):
            with self.subTest(source=source):
                self.assertEqual(render(source), source)


class NoteLinkerFenceTest(unittest.TestCase):
    def scope(self, content, field="질문", extra=""):
        return f'<div class="anki-code-scope" data-anki-fence-field="{field}"{extra}>{content}</div>'

    def assert_fence_preserved(self, content):
        literal = self.scope(content)
        source = MARKER + literal + MARKER
        expected = render(MARKER) + literal + render(MARKER)
        self.assertEqual(render(source, protect_fences=True), expected)

    def test_newlines_and_editor_break_elements_preserve_exact_source(self):
        for content in (
            f"```bash\n{MARKER}\n```",
            f"```bash\r\n{MARKER}\r\n```",
            f"```bash<br>{MARKER}<BR />```",
            f"<div>```bash</div><div>{MARKER}</div><div>```</div>",
            f"<p>```bash</p><p>{MARKER}</p><p>```</p>",
            f"<div>```bash<br>{MARKER}</div><p>```</p>",
            f"<div>```bash</div><div></div><div><br></div><div>{MARKER}</div><div>```</div>",
        ):
            with self.subTest(content=content):
                self.assert_fence_preserved(content)

    def test_inline_split_fences_entities_and_formatting_remain_byte_identical(self):
        self.assert_fence_preserved(
            '<span>``</span><b>`</b><i>bash</i><br>'
            + f'\tconst link = "[<b>예제</b> &amp; 제목|nid1787809736976]";'
            + '&nbsp;&lt;script&gt;\n'
            + '<span>&#96;&#x60;&grave;</span>'
        )
        self.assert_fence_preserved(
            '&#32;&#x20; &#96;&#96;&#96;bash&#10;'
            + MARKER + '&#13;&#10;   &#x60;&#x60;&#x60;\t'
        )

    def test_long_opening_keeps_shorter_backticks_inside_code(self):
        self.assert_fence_preserved(f"````bash\n{MARKER}\n```\n{MARKER}\n`````\t")

    def test_three_leading_ascii_spaces_are_inclusive(self):
        for count in range(4):
            with self.subTest(count=count):
                self.assert_fence_preserved(f"{' ' * count}```bash\n{MARKER}\n{' ' * count}```")

    def test_four_spaces_tabs_and_nbsp_are_not_boundary_indentation(self):
        for indent in ("    ", "\t", "\u00a0", "&nbsp;"):
            literal = self.scope(f"{indent}```bash<br>{MARKER}<br>{indent}```")
            with self.subTest(indent=indent):
                self.assertEqual(render(literal, protect_fences=True), literal.replace(MARKER, render(MARKER)))

    def test_unclosed_escaped_inline_and_tilde_examples_keep_normal_links(self):
        for content in (
            f"```bash<br>{MARKER}",
            f"````bash<br>{MARKER}<br>```",
            f"\\```bash<br>{MARKER}<br>```",
            f"```bash {MARKER} ```",
            f"~~~bash<br>{MARKER}<br>~~~",
            f"```ba`sh<br>{MARKER}<br>```",
            f"```bash<br>{MARKER}<br>```&nbsp;",
            f"```bash<br>{MARKER}<br>``` trailing",
        ):
            literal = self.scope(content)
            with self.subTest(content=content):
                self.assertEqual(render(literal, protect_fences=True), literal.replace(MARKER, render(MARKER)))

    def test_multiple_blocks_preserve_inside_links_and_render_between_them(self):
        first = f"```bash<br>{MARKER}<br>```"
        second = f"````<br>{MARKER}<br>````"
        literal = self.scope(first + "<br>" + MARKER + "<br>" + second)
        expected = self.scope(first + "<br>" + render(MARKER) + "<br>" + second)
        self.assertEqual(render(literal, protect_fences=True), expected)

    def test_opt_in_and_each_selected_field_are_required(self):
        content = f"```bash\n{MARKER}\n```"
        for field in ("질문", "답", "설명", "출처"):
            literal = self.scope(content, field)
            with self.subTest(field=field):
                self.assertEqual(render(literal, protect_fences=True), literal)
                self.assertEqual(render(literal), literal.replace(MARKER, render(MARKER)))
        for literal in (
            self.scope(content, "맥락"), self.scope(content, "검토 메모"),
            f'<div class="anki-code-scope">{content}</div>', content,
        ):
            with self.subTest(literal=literal):
                self.assertEqual(render(literal, protect_fences=True), literal.replace(MARKER, render(MARKER)))

    def test_boundaries_never_join_separate_fields(self):
        source = self.scope(f"```bash<br>{MARKER}") + self.scope(f"{MARKER}<br>```", "답")
        self.assertEqual(render(source, protect_fences=True), source.replace(MARKER, render(MARKER)))

    def test_hidden_existing_code_and_raw_script_regions_do_not_supply_fence_lines(self):
        for excluded in (
            f'<div hidden>```bash<br>{MARKER}</div>',
            f'<textarea>```bash\n{MARKER}</textarea>',
            f'<script>const example = "```bash\\n{MARKER}"</script>',
            f'<pre><code>```bash\n{MARKER}</code></pre>',
        ):
            source = self.scope(excluded + "<br>" + MARKER + "<br>```")
            with self.subTest(excluded=excluded):
                # Fence opt-in cannot change legacy behavior in hidden/foreign DOM.
                self.assertEqual(render(source, protect_fences=True), render(source))

    def test_closed_source_fence_preserves_literal_links_across_foreign_content(self):
        for barrier in ('<pre><code>existing</code></pre>', '<img src="fixture.png">', '<div hidden>hidden</div>'):
            source = self.scope(f"```bash<br>{MARKER}{barrier}{MARKER}<br>```")
            with self.subTest(barrier=barrier):
                self.assertEqual(render(source, protect_fences=True), source)

    def test_marker_overlapping_a_complete_fence_is_not_partly_rewritten(self):
        source = self.scope('[before<br>```bash<br>body<br>```<br>after|nid1787809736976]')
        self.assertEqual(render(source, protect_fences=True), source)

    def test_missing_outer_field_end_does_not_expose_a_complete_fence(self):
        source = '<div data-anki-fence-field="질문">```bash<br>' + MARKER + '<br>```'
        self.assertEqual(render(source, protect_fences=True), source)

    def test_nonfenced_markup_and_outside_attributes_keep_legacy_behavior(self):
        source = self.scope(f'<p title="{MARKER}">plain {MARKER}</p><b>한글 &nbsp; &#96;</b>')
        self.assertEqual(render(source, protect_fences=True), render(source))

    def test_inline_existing_literals_and_opaque_elements_cannot_invent_an_opener(self):
        for prefix in ('<code>prefix</code>', '<textarea>prefix</textarea>', '<img src="fixture.png">'):
            source = self.scope(prefix + f'```bash<br>{MARKER}<br>```')
            with self.subTest(prefix=prefix):
                self.assertEqual(render(source, protect_fences=True), render(source))
        self.assert_fence_preserved(f'<pre><code>prefix</code></pre>```bash<br>{MARKER}<br>```')

    def test_unsafe_complete_regions_protect_source_even_if_later_dom_conversion_fails(self):
        first = f'```bash<br>{MARKER}<br>```<br>'
        for unsafe in ('<img src="fixture.png">', '<span aria-hidden="true">hidden</span>',
                       '<span style="display:none">hidden</span>', '<span contenteditable>editable</span>',
                       '<span style="visibility:collapse">hidden</span>', '<span style="opacity:0">hidden</span>',
                       '<span class="mjx-container">math</span>', '<span class="katex-display">math</span>'):
            source = self.scope(first + f'```bash<br>{MARKER}{unsafe}<br>```')
            with self.subTest(unsafe=unsafe):
                self.assertEqual(render(source, protect_fences=True), source)
        # An unsafe, unfinished example has no basis for protecting its marker.
        source = self.scope(first + f'```bash<br>{MARKER}<img src="fixture.png">')
        expected = self.scope(first + f'```bash<br>{render(MARKER)}<img src="fixture.png">')
        self.assertEqual(render(source, protect_fences=True), expected)

    def test_unsupported_ancestors_and_comments_preserve_closed_source_fences(self):
        source = self.scope(f'<blockquote><p>```bash</p><p>{MARKER}</p><p>```</p></blockquote>')
        self.assertEqual(render(source, protect_fences=True), source)
        self.assert_fence_preserved(f'``<!-- invisible -->`bash<br>{MARKER}<br>```')
        self.assert_fence_preserved(f'<p>```bash<p>{MARKER}<p>```')


@unittest.skipUnless(os.environ.get("ANKI_NOTE_LINKER_SOURCE"), "requires built Note Linker package")
class PackagedNoteLinkerTest(unittest.TestCase):
    """Run the distribution's patched renderer without importing Qt or Anki."""

    @classmethod
    def setUpClass(cls):
        source = Path(os.environ["ANKI_NOTE_LINKER_SOURCE"]) / "anki_note_linker"
        packaged_helper = load_module(source / "core/html_links.py", "packaged_html_links")
        links = load_module(source / "core/links.py", "packaged_note_links")
        tree = ast.parse((source / "runtime/editor_actions.py").read_text())
        mixin = next(node for node in tree.body if isinstance(node, ast.ClassDef)
                     and node.name == "EditorActionsMixin")
        method = next(node for node in mixin.body if isinstance(node, ast.FunctionDef)
                      and node.name == "convertLink")
        namespace = {"Card": object, "NOTE_LINK_PATTERN": links.NOTE_LINK_PATTERN,
                     "replace_links_outside_literals": packaged_helper.replace_links_outside_literals}
        exec(compile(ast.Module(body=[method], type_ignores=[]), "convertLink", "exec"), namespace)
        cls.convert = staticmethod(lambda text, model="학습 Basic": namespace["convertLink"](
            None, text, SimpleNamespace(note_type=lambda: {"name": model}), "reviewQuestion"))
        cls.tree = tree
        cls.source = source
        cls.pattern = links.NOTE_LINK_PATTERN

    def test_package_wires_exact_helper_and_upstream_pattern(self):
        self.assertEqual((self.source / "core/html_links.py").read_bytes(), HELPER.read_bytes())
        self.assertEqual(self.pattern.pattern, PATTERN.pattern)
        self.assertTrue(any(isinstance(node, ast.ImportFrom)
                            and node.module == "core.html_links" and node.level == 2
                            and any(alias.name == "replace_links_outside_literals" for alias in node.names)
                            for node in self.tree.body))

    def test_actual_renderer_preserves_code_but_opens_normal_link(self):
        literal = f"<pre><code>{MARKER}</code></pre>"
        rendered = self.convert(literal + MARKER)
        self.assertTrue(rendered.startswith("<script>window.AnkiNoteLinkerIsActive = true</script>"))
        self.assertIn(literal, rendered)
        self.assertEqual(rendered.count('class="noteLink"'), 1)
        self.assertIn('AnkiNoteLinker-openNoteInPreviewer`+`1787809736976', rendered)
        self.assertIn('AnkiNoteLinker-openNoteInNewEditor`+`1787809736976', rendered)
        self.assertTrue(rendered.endswith(">예제 &amp; 제목</a>"))

    def test_actual_renderer_protects_selected_basic_fences_only(self):
        literal = '<div data-anki-fence-field="질문">```bash<br>' + MARKER + '<br>```</div>'
        rendered = self.convert(literal + MARKER)
        self.assertIn(literal, rendered)
        self.assertEqual(rendered.count('class="noteLink"'), 1)
        other = self.convert(literal + MARKER, "KaTeX and Markdown Cloze")
        self.assertEqual(other.count('class="noteLink"'), 2)


if __name__ == "__main__":
    unittest.main()
