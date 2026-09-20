import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { JSDOM } from "jsdom";

const manifest = JSON.parse(await readFile(new URL("./dist/manifest.json", import.meta.url), "utf8"));
const source = await readFile(new URL(`./dist/${manifest.asset.filename}`, import.meta.url), "utf8");

function createLibrary() {
  const dom = new JSDOM("<!doctype html><body></body>", { runScripts: "outside-only" });
  dom.window.eval(source);
  return { dom, library: dom.window.AnkiSyntaxHighlightLibraryV1 };
}

const examples = {
  javascript: "const answer = Buffer.from('ABC', 'utf8');\nconsole.log(answer);",
  typescript: "interface Result { value: number }\nconst result: Result = { value: 3 };",
  jsx: "const greeting = <div className=\"hello\">Hello</div>;",
  tsx: "const greeting: JSX.Element = <div className=\"hello\">Hello</div>;",
  html: "<div class=\"hello\"><strong>Hello</strong></div>",
  css: ".hello { color: red; padding: 2px; }",
  json: '{"name": "hello", "count": 3, "enabled": true}',
  bash: "#!/bin/bash\necho \"${HOME}\"",
  shell: "#!/bin/sh\nprintf '%s\\n' \"$HOME\"",
  sql: "SELECT id FROM notes WHERE title = 'hello';",
  c: "int main(void) { return 42; }",
  python: "def hello(name):\n    return f'Hello {name}'",
  java: "public class Hello { public static void main(String[] args) {} }",
  yaml: "name: hello\nitems:\n  - enabled: true",
  http: "GET / HTTP/1.1\nHost: example.com\n\n",
};

for (const [language, code] of Object.entries(examples)) {
  test(`shipped bundle highlights ${language} and preserves its text`, () => {
    const { dom, library } = createLibrary();
    try {
      assert.ok(library.getLanguage(language), `${language} is registered`);
      const result = library.highlight(code, { language, ignoreIllegals: true });
      assert.match(result.value, /class="hljs-/, `${language} produces tokens`);
      const element = dom.window.document.createElement("code");
      element.innerHTML = result.value;
      assert.equal(element.textContent, code);
      if (language === "jsx" || language === "tsx") {
        assert.ok(element.querySelector(".hljs-tag .hljs-name"), "embedded JSX markup is colored");
      }
    } finally {
      dom.window.close();
    }
  });
}

test("isolated API coexists with legacy global hljs and repeated script evaluation", () => {
  const { dom, library } = createLibrary();
  try {
    const legacy = { versionString: "legacy", highlightAuto: () => { throw new Error("legacy touched"); } };
    dom.window.hljs = legacy;
    dom.window.eval(source);
    assert.equal(dom.window.hljs, legacy);
    assert.equal(library.version, manifest.library.version);
    assert.deepEqual(Object.keys(library).sort(), ["getLanguage", "highlight", "version"]);
    assert.ok(Object.isFrozen(library));
    assert.equal(library.getLanguage("rust"), undefined, "unselected grammars are excluded");
    assert.equal(library.getLanguage("plaintext"), undefined, "plaintext is handled by the renderer");
    for (const [alias, language] of Object.entries({
      js: "javascript", ts: "typescript", jsx: "javascript", tsx: "typescript",
      html: "xml", sh: "bash", shell: "bash", yml: "yaml", py: "python",
    })) assert.equal(library.getLanguage(alias), library.getLanguage(language));
  } finally {
    dom.window.close();
  }
});

test("HTTP body stays plain instead of internally auto-detecting JSON", () => {
  const { dom, library } = createLibrary();
  try {
    const header = "HTTP/1.1 200 OK\nContent-Type: application/json\n\n";
    const body = '{"name": "hello", "enabled": true}';
    const result = library.highlight(header + body, { language: "http", ignoreIllegals: true });
    assert.match(result.value, /hljs-meta/);
    assert.ok(result.value.endsWith(body.replaceAll('"', "&quot;")));
    assert.doesNotMatch(result.value, /hljs-(attr|literal)"/);
  } finally {
    dom.window.close();
  }
});

test("literal markup and whitespace remain inert and unchanged", () => {
  const { dom, library } = createLibrary();
  try {
    const code = '<script>window.shouldNotRun = true</script>\n\t<div title="&amp;">한글 & < > \u00a0</div>\n';
    const result = library.highlight(code, { language: "html", ignoreIllegals: true });
    const element = dom.window.document.createElement("code");
    element.innerHTML = result.value;
    dom.window.document.body.append(element);
    assert.equal(element.textContent, code);
    assert.equal(element.querySelector("script"), null);
    assert.equal(dom.window.shouldNotRun, undefined);
  } finally {
    dom.window.close();
  }
});
