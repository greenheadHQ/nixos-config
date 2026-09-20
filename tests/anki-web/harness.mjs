import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../../", import.meta.url));
export const packagePath = process.env.ANKI_SYNTAX_PACKAGE || resolve(root, "modules/nixos/programs/anki-host/code-highlighting");
export const addonPath = process.env.ANKI_SYNTAX_ADDON || resolve(root, "modules/nixos/programs/anki-host/sync-addon");
const require = createRequire(resolve(packagePath, "package.json"));
const { JSDOM } = require("jsdom");
export const manifest = JSON.parse(await readFile(resolve(packagePath, "dist/manifest.json"), "utf8"));
export const bundle = await readFile(resolve(packagePath, "dist", manifest.asset.filename), "utf8");
export const css = await readFile(resolve(addonPath, "code-highlight.css"), "utf8");
const inline = source => source.match(/<script>([\s\S]*)<\/script>/)[1];
export const renderer = inline(await readFile(resolve(addonPath, "code-highlight-renderer.html"), "utf8"))
  .replace("__ANKI_SYNTAX_ASSET__", JSON.stringify(manifest.asset.filename))
  .replace("__ANKI_SYNTAX_CSS__", JSON.stringify(css).replaceAll("<", "\\u003c"));
export const noteLinkRenderer = inline(await readFile(resolve(addonPath, "note-link-renderer.html"), "utf8"));
export const escape = value => value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;");
export const block = (text, language = "javascript") => `<pre><code${language === null ? "" : ` class="language-${language}"`}>${escape(text)}</code></pre>`;
export const scope = content => `<section class="anki-code-scope">${content}</section>`;

export function harness(html = "", { preload = true, freezeClock = true, mobile = false } = {}) {
  const dom = new JSDOM(`<!doctype html><html${mobile ? ' class="iphone"' : ""}><head></head><body>${html}</body></html>`, {
    url: "http://127.0.0.1/", runScripts: "outside-only", pretendToBeVisual: true,
  });
  const { window } = dom;
  const { document } = window;
  // Wall-clock cutoffs are tested separately. Grammar compilation costs must not
  // make behavioral assertions depend on the CI worker's current load.
  if (freezeClock) window.performance.now = () => 0;
  const scripts = [];
  const append = document.head.appendChild.bind(document.head);
  document.head.appendChild = element => {
    if (element.dataset.ankiSyntaxAsset) scripts.push(element);
    return append(element);
  };
  const installBundle = () => window.eval(bundle);
  if (preload) installBundle();
  const start = () => window.eval(renderer);
  const flush = async () => {
    // Promise-only loader/render chain, including two template invocations.
    for (let i = 0; i < 8; i++) await Promise.resolve();
  };
  return { dom, window, document, scripts, start, flush, installBundle,
    api: () => window.AnkiCodeHighlightV1,
    close: () => window.close() };
}

export const examples = {
  javascript: "const answer = Buffer.from('ABC', 'utf8');\nconsole.log(answer);",
  typescript: "interface Result { value: number }\nconst result: Result = { value: 3 };",
  jsx: 'const greeting = <div className="hello">Hello</div>;',
  tsx: 'const greeting: JSX.Element = <div className="hello">Hello</div>;',
  html: '<div class="hello"><strong>Hello</strong></div>',
  css: ".hello { color: red; padding: 2px; }",
  json: '{"name": "hello", "count": 3, "enabled": true}',
  bash: '#!/bin/bash\necho "${HOME}"',
  shell: '#!/bin/sh\nprintf \'%s\\n\' "$HOME"',
  sql: "SELECT id FROM notes WHERE title = 'hello';",
  c: "int main(void) { return 42; }",
  python: "def hello(name):\n    return f'Hello {name}'",
  java: "public class Hello { public static void main(String[] args) {} }",
  yaml: "name: hello\nitems:\n  - enabled: true",
  http: "GET / HTTP/1.1\nHost: example.com\n\n",
};
