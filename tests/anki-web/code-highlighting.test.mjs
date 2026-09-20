import assert from "node:assert/strict";
import test from "node:test";
import { block, escape, examples, harness, manifest, noteLinkRenderer, scope } from "./harness.mjs";

async function rendered(t, html, options) {
  const page = harness(html, options);
  t.after(page.close);
  page.start();
  await page.flush();
  return page;
}

for (const [language, text] of Object.entries(examples)) {
  test(`actual template and shipped bundle highlight ${language}`, async t => {
    const { document } = await rendered(t, scope(block(text, language)));
    const code = document.querySelector("code");
    assert.equal(code.textContent, text);
    assert.ok(code.classList.contains("hljs"));
    assert.ok(code.querySelector('span[class^="hljs-"]'));
    if (["jsx", "tsx"].includes(language)) assert.ok(code.querySelector(".hljs-tag .hljs-name"));
  });
}

test("all declared aliases work without detecting unspecified languages", async t => {
  const aliases = { js: "javascript", ts: "typescript", xml: "html", sh: "shell", py: "python", yml: "yaml" };
  const page = await rendered(t, scope(Object.entries(aliases).map(([alias, language]) => block(examples[language], alias)).join("")));
  assert.equal(page.document.querySelectorAll("code.hljs").length, Object.keys(aliases).length);
  page.window.hljs = { highlightAuto() { assert.fail("legacy automatic detection was called"); } };
  page.document.body.innerHTML = scope([null, "unknown", "plaintext", "text", "txt", "rust", "constructor", "__proto__"].map(language => block(examples.javascript, language)).join(""));
  await page.api().render();
  for (const code of page.document.querySelectorAll("code")) {
    assert.equal(code.textContent, examples.javascript);
    assert.equal(code.children.length, 0);
    assert.ok(!code.classList.contains("hljs"));
  }
});

test("inline code, unrelated cards, and contradictory language classes stay untouched", async t => {
  const html = `<div>${block("const outside = 1;")}</div>` + scope('<p><code class="language-js">const inline = 2;</code></p><pre><code class="language-js language-python">const ambiguous = 3;</code></pre>');
  const page = await rendered(t, html);
  assert.equal(page.document.body.innerHTML, html);
  assert.equal(page.document.querySelectorAll(".hljs").length, 0);
});

test("tabs, newlines, HTML entities, Korean, and script samples remain inert and exact", async t => {
  const sample = '<script>window.sampleRan = true</script>\n\t<div title="&amp;">한글 & < > \u00a0</div>\n';
  const page = await rendered(t, scope(block(sample, "html")));
  const code = page.document.querySelector("code");
  assert.equal(code.textContent, sample);
  assert.equal(code.querySelector("script"), null);
  assert.equal(page.window.sampleRan, undefined);
});

test("foreign markup including cloze spans and anchors is never flattened", async t => {
  const contents = ['const <span class="cloze">[...]</span> = 3;', '<a href="anki://example">const</a> sample = 3;', 'const <em>sample</em> = 3;', 'const sample = 3;<br>'];
  const page = await rendered(t, scope(contents.map(content => `<pre><code class="language-js">${content}</code></pre>`).join("")));
  assert.deepEqual([...page.document.querySelectorAll("code")].map(code => code.innerHTML), contents);
  assert.equal(page.api().lastMetrics.skipped, contents.length);
});

test("repeated rendering and FrontSide script duplication do not nest token spans or styles", async t => {
  const page = await rendered(t, scope(block(examples.javascript)));
  const code = page.document.querySelector("code");
  const original = code.innerHTML;
  page.start();
  page.start();
  await page.flush();
  await page.api().render();
  assert.equal(code.innerHTML, original);
  assert.equal(page.document.querySelectorAll("#anki-code-style-v1").length, 1);
  assert.equal(page.scripts.length, 0);
});

test("answer blocks, the next card, and direct text edits are highlighted in a reused WebView", async t => {
  const page = await rendered(t, scope(block("const question = 1;")));
  page.document.body.insertAdjacentHTML("beforeend", scope(block("const answer = 2;")));
  page.start();
  await page.flush();
  assert.equal(page.document.querySelectorAll("code.hljs").length, 2);
  page.document.body.innerHTML = scope(block("const next = 3;"));
  page.start();
  await page.flush();
  const code = page.document.querySelector("code");
  assert.ok(code.querySelector(".hljs-keyword"));
  code.textContent = "const edited = 4;";
  await page.api().render();
  assert.equal(code.textContent, "const edited = 4;");
  assert.ok(code.querySelector(".hljs-number"));
});

test("edited foreign markup is preserved, and changing to plaintext removes old tokens", async t => {
  const page = await rendered(t, scope(block("const value = 1;")));
  const code = page.document.querySelector("code");
  code.className = "language-plaintext hljs";
  await page.api().render();
  assert.equal(code.innerHTML, "const value = 1;");
  assert.equal(code.className, "language-plaintext");
  code.className = "language-javascript";
  await page.api().render();
  code.insertAdjacentHTML("beforeend", '<em class="user-edit">note</em>');
  const modified = code.innerHTML;
  await page.api().render();
  assert.equal(code.innerHTML, modified);
});

test("one pending asset load serves both template scripts and discards the old card", async t => {
  const page = harness(scope(block("const oldCard = 1;")), { preload: false });
  t.after(page.close);
  page.start();
  const old = page.document.querySelector("code");
  page.document.body.innerHTML = scope(block("const currentCard = 2;"));
  page.start();
  assert.equal(page.scripts.length, 1);
  assert.ok(page.scripts[0].src.endsWith(manifest.asset.filename));
  assert.equal(page.document.querySelector("code").textContent, "const currentCard = 2;");
  page.installBundle();
  page.scripts[0].onload();
  await page.flush();
  assert.equal(old.children.length, 0);
  assert.ok(page.document.querySelector("code .hljs-keyword"));
  assert.equal(page.document.querySelectorAll("script[data-anki-syntax-asset]").length, 0);
  page.start();
  await page.flush();
  assert.equal(page.scripts.length, 1);
});

test("failed or empty asset loads leave readable text and retry on a later card", async t => {
  const page = harness(scope(block("const visible = 1;")), { preload: false });
  t.after(page.close);
  page.start();
  page.scripts[0].onerror();
  await page.flush();
  assert.equal(page.document.querySelector("code").innerHTML, "const visible = 1;");
  page.start();
  page.scripts[1].onload(); // A corrupt/old asset that registers no supported API.
  await page.flush();
  assert.equal(page.document.querySelector("code").children.length, 0);
  page.start();
  page.installBundle();
  page.scripts[2].onload();
  await page.flush();
  assert.ok(page.document.querySelector("code .hljs-keyword"));
  assert.equal(page.scripts.length, 3);
});

test("load timeout removes the pending script and permits a fresh attempt", async t => {
  const page = harness(scope(block("const visible = 1;")), { preload: false });
  t.after(page.close);
  let timeout;
  page.window.setTimeout = (callback, delay) => { assert.equal(delay, 3000); timeout = callback; return 123; };
  page.window.clearTimeout = token => assert.equal(token, 123);
  page.start();
  timeout();
  await page.flush();
  assert.equal(page.document.querySelector("code").innerHTML, "const visible = 1;");
  assert.equal(page.document.querySelectorAll("script[data-anki-syntax-asset]").length, 0);
  page.start();
  assert.equal(page.scripts.length, 2);
  page.scripts[1].onerror();
  await page.flush();
});

test("a grammar error preserves plaintext and does not hide later blocks", async t => {
  const page = harness(scope(block("const error = 1;") + block("const ok = 2;")));
  t.after(page.close);
  const actual = page.window.AnkiSyntaxHighlightLibraryV1;
  let calls = 0;
  page.window.AnkiSyntaxHighlightLibraryV1 = { version: actual.version, highlight(...args) {
    if (++calls === 1) throw new Error("simulated grammar failure");
    return actual.highlight(...args);
  } };
  page.start();
  await page.flush();
  const [first, second] = page.document.querySelectorAll("code");
  assert.equal(first.innerHTML, "const error = 1;");
  assert.ok(second.querySelector(".hljs-keyword"));
});

test("4096-character per-block bound is inclusive and keeps oversized code intact", async t => {
  const atLimit = "const value = 1;".padEnd(4096, " ");
  const beyond = atLimit + " ";
  const page = await rendered(t, scope(block(atLimit) + block(beyond)));
  const [first, second] = page.document.querySelectorAll("code");
  assert.ok(first.classList.contains("hljs"));
  assert.equal(first.textContent, atLimit);
  assert.equal(second.children.length, 0);
  assert.equal(second.textContent, beyond);
});

test("aggregate character and block limits bound dense cards without removing content", async t => {
  const text = "const value = 1;".padEnd(4096, " ");
  const page = await rendered(t, scope(Array.from({ length: 5 }, () => block(text)).join("")));
  assert.equal(page.document.querySelectorAll("code.hljs").length, 4);
  assert.equal([...page.document.querySelectorAll("code")].every(code => code.textContent === text), true);
  page.document.body.innerHTML = scope(Array.from({ length: 33 }, () => block("const value = 1;")).join(""));
  await page.api().render();
  assert.equal(page.document.querySelectorAll("code.hljs").length, 32);
  assert.equal(page.document.querySelectorAll("code").length, 33);
});

test("elapsed-time bound stops starting further grammar work", async t => {
  const page = harness(scope(block("const first = 1;") + block("const second = 2;")));
  t.after(page.close);
  const actual = page.window.AnkiSyntaxHighlightLibraryV1;
  let clock = 0;
  page.window.performance.now = () => clock;
  page.window.AnkiSyntaxHighlightLibraryV1 = { version: actual.version, highlight(...args) {
    const result = actual.highlight(...args);
    clock += 17;
    return result;
  } };
  page.start();
  await page.flush();
  assert.equal(page.document.querySelectorAll("code.hljs").length, 1);
  assert.equal(page.document.querySelectorAll("code")[1].innerHTML, "const second = 2;");
});

test("cards without code avoid loading any asset", async t => {
  const page = await rendered(t, '<section class="anki-code-scope"><p>일반 카드</p></section>', { preload: false });
  assert.equal(page.scripts.length, 0);
  assert.equal(page.document.body.textContent, "일반 카드");
});

test("scoped stylesheet keeps line breaks and horizontal scrolling while following app night mode", async t => {
  const page = await rendered(t, scope(block("const value = 1;")) + '<pre id="unrelated"><code>outside</code></pre>');
  const pre = page.document.querySelector(".anki-code-scope pre");
  const style = page.window.getComputedStyle(pre);
  assert.equal(style.whiteSpace, "pre");
  assert.equal(style.overflowX, "auto");
  assert.equal(style.overflowWrap, "normal");
  assert.equal(style.maxWidth, "100%");
  assert.equal(style.fontWeight, "400");
  assert.notEqual(page.window.getComputedStyle(page.document.querySelector("#unrelated")).overflowX, "auto");
  const token = pre.querySelector(".hljs-keyword");
  const lightColor = page.window.getComputedStyle(token).color;
  const lightBackground = style.backgroundColor;
  for (const night of ["nightMode", "night_mode"]) {
    page.document.body.className = night;
    assert.notEqual(page.window.getComputedStyle(pre).backgroundColor, lightBackground);
    assert.notEqual(page.window.getComputedStyle(token).color, lightColor);
  }
});

for (const order of ["links-first", "highlight-first"]) {
  test(`mobile note-link rendering leaves code literal intact (${order})`, async t => {
    const literal = '[프로그램 카운터|nid1787809736976]';
    const code = `const sample = "${literal}";`;
    const html = `<div class="linkRender anki-code-scope"><p>${escape(literal)}</p>${block(code)}<p><code>${escape(literal)}</code></p></div>`;
    const page = harness(html, { mobile: true });
    t.after(page.close);
    const renderLinks = () => {
      page.window.eval(noteLinkRenderer);
      page.document.dispatchEvent(new page.window.Event("DOMContentLoaded"));
      page.window.AnkiNoteLinkerRenderMobile();
    };
    if (order === "links-first") renderLinks();
    page.start();
    await page.flush();
    if (order === "highlight-first") renderLinks();
    const blockCode = page.document.querySelector("pre code");
    assert.equal(blockCode.textContent, code);
    assert.equal(blockCode.querySelector("a"), null);
    assert.equal(page.document.querySelector("p code").innerHTML, escape(literal));
    assert.equal(page.document.querySelectorAll("a.noteLink").length, 1);
    assert.equal(page.document.querySelector("a.noteLink").href, "anki://x-callback-url/search?query=nid%3A1787809736976");
    assert.ok(blockCode.querySelector(".hljs-string"));
  });
}
