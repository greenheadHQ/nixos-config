import ast
import importlib.util
import os
from pathlib import Path
import re
import sys
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


def render(source):
    return helper.replace_links_outside_literals(
        source, PATTERN, lambda match: f"<LINK>{match.group(1)}</LINK>"
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
        source = f"<![unsupported]>{MARKER}"
        self.assertEqual(render(source), source)

    def test_comments_do_not_open_literal_contexts(self):
        source = f"<!-- <pre> -->{MARKER}<!-- </pre> -->"
        self.assertEqual(
            render(source), "<!-- <pre> --><LINK>예제 &amp; 제목</LINK><!-- </pre> -->"
        )

    def test_plaintext_and_unrelated_html_are_identical(self):
        for source in ("", "\t한글\r\n", "<p x='>'>&amp; &#123; <br /></p>"):
            with self.subTest(source=source):
                self.assertEqual(render(source), source)


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
        cls.convert = staticmethod(lambda text: namespace["convertLink"](None, text, None, "reviewQuestion"))
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


if __name__ == "__main__":
    unittest.main()
