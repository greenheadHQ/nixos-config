import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { harness, noteLinkRenderer } from "./harness.mjs";

const id = "1111111111111";
const otherId = "2222222222222";
const marker = (title = "title", nid = id) => `[${title}|nid${nid}]`;
const fixturePath = process.env.ANKI_NOTE_LINK_FIXTURES
  || fileURLToPath(new URL("../fixtures/anki-note-link/", import.meta.url));
const v2 = (await readFile(`${fixturePath}/renderer-v2.html`, "utf8")).match(/<script>([\s\S]*)<\/script>/)[1];

async function rendered(t, html, { ready = "complete", ...options } = {}) {
  const page = harness(html, { preload: false, mobile: true, ...options });
  t.after(page.close);
  Object.defineProperty(page.document, "readyState", { value: ready, configurable: true });
  page.render = () => page.window.eval(noteLinkRenderer);
  page.render();
  await page.flush();
  return page;
}

for (const title of [
  "plain &amp; &lt;literal&gt; &#x1F517;",
  "term<sup>alias</sup>",
  "term<sup>alias</sup> suffix",
  "<b>first</b> middle <b>last</b>",
  "term <b>bold <sup>small</sup></b> <u>underlined</u>",
  "<span class=\"label\" style=\"color: red\"><em>nested</em></span>",
  "<strong>strong</strong> <i>italic</i> <s>deleted</s> <sub>index</sub>",
  "term<sup style=\"\">alias</sup>",
  "escaped \\[array] <b>title</b>",
  "",
]) {
  test(`preserves the desktop title DOM: ${title}`, async t => {
    const { document } = await rendered(t, `<div class="linkRender">before ${marker(title)} after</div>`);
    const link = document.querySelector("a.noteLink");
    assert.ok(link);
    const expected = document.createElement("div");
    expected.innerHTML = title.replaceAll("\\[", "[");
    assert.equal(link.innerHTML, expected.innerHTML);
    assert.equal(link.textContent, expected.textContent);
    assert.equal(link.getAttribute("href"), `anki://x-callback-url/search?query=nid%3A${id}`);
    assert.equal(link.parentNode.textContent, `before ${expected.textContent} after`);
  });
}

test("preserves original inline elements and their listeners", async t => {
  const page = harness(`<div class="linkRender">${marker("first <b id=kept>second</b>")}</div>`, { preload: false, mobile: true });
  t.after(page.close);
  const original = page.document.querySelector("b");
  let called = false;
  original.addEventListener("custom", () => { called = true; });
  Object.defineProperty(page.document, "readyState", { value: "complete" });
  page.window.eval(noteLinkRenderer);
  assert.equal(page.document.querySelector("a b"), original);
  original.dispatchEvent(new page.window.Event("custom"));
  assert.equal(called, true);
  assert.equal(page.document.querySelectorAll("#kept").length, 1);
});

test("multiple adjacent markers and nested rendering scopes are idempotent", async t => {
  const { document, render } = await rendered(t,
    `<div class="linkRender">${marker("<b>first</b>")} ${marker("second", otherId)}`
    + `<span class="linkRender">${marker("third <sup>x</sup>")}</span></div>`);
  assert.equal(document.querySelectorAll("a.noteLink").length, 3);
  assert.deepEqual(Array.from(document.querySelectorAll("a.noteLink"), link => [
    link.textContent, link.getAttribute("href"), link.innerHTML,
  ]), [
    ["first", `anki://x-callback-url/search?query=nid%3A${id}`, "<b>first</b>"],
    ["second", `anki://x-callback-url/search?query=nid%3A${otherId}`, "second"],
    ["third x", `anki://x-callback-url/search?query=nid%3A${id}`, "third <sup>x</sup>"],
  ]);
  const before = document.body.innerHTML;
  for (let i = 0; i < 5; i++) render();
  assert.equal(document.body.innerHTML, before);
  assert.equal(document.querySelectorAll("a a").length, 0);
});

test("literal, interactive, math, and unselected regions retain their DOM", async t => {
  const protectedHTML = [
    `<a href="https://example.invalid/">${marker("<b>linked</b>")}</a>`,
    `<style>.literal { --example: "${marker()}"; }</style>`,
    ...["pre", "code", "textarea", "script", "math", "mjx-container", "button", "select", "svg"].map(
      tag => `<${tag}>${marker("literal")}</${tag}>`),
    ...["MathJax", "MathJax_Preview", "katex"].map(cls => `<span class="${cls}">${marker()}</span>`),
    `<span contenteditable="true">${marker()}</span>`,
    `<pre><span class="linkRender">${marker()}</span></pre>`,
  ].join("");
  const { document, render } = await rendered(t,
    `<div class="linkRender"><section id="protected">${protectedHTML}</section>${marker("outside")}</div>`
    + `<div id="unselected">${marker("<b>unselected</b>")}</div>`);
  const expected = document.createElement("div");
  expected.innerHTML = protectedHTML;
  assert.equal(document.querySelector("#protected").innerHTML, expected.innerHTML);
  assert.equal(document.querySelector("#unselected").textContent, marker("unselected"));
  assert.equal(document.querySelectorAll("a.noteLink").length, 1);
  render();
  assert.equal(document.querySelector("#protected").innerHTML, expected.innerHTML);
});

test("native TeX markers remain literal before MathJax runs", async t => {
  const math = `\\(${marker("math")}\\) and \\[${marker("<b>display math</b>")}\\]`;
  const { document } = await rendered(t, `<div class="linkRender">${math} ${marker("normal")}</div>`);
  assert.equal(document.querySelectorAll("a.noteLink").length, 1);
  assert.equal(document.querySelector("a").textContent, "normal");
  assert.ok(document.querySelector(".linkRender").textContent.startsWith(
    `\\(${marker("math")}\\) and \\[${marker("display math")}\\]`));
});

test("block, break, comment, and excluded-element boundaries cannot join a marker", async t => {
  for (const html of [
    `[one<div>two</div>|nid${id}]`,
    `[one<br>two|nid${id}]`,
    `[one<!-- boundary -->two|nid${id}]`,
    `[one<code>two</code>|nid${id}]`,
    `<p>[one</p><p>two|nid${id}]</p>`,
    `[one<img alt="two">|nid${id}]`,
  ]) {
    const { document } = await rendered(t, `<div class="linkRender">${html}</div>`);
    const expected = document.createElement("div");
    expected.innerHTML = html;
    assert.equal(document.querySelector(".linkRender").innerHTML, expected.innerHTML);
    assert.equal(document.querySelectorAll("a.noteLink").length, 0);
  }
});

test("partial tag boundaries, split nid syntax, and escaped markers fail closed", async t => {
  for (const html of [
    `<b>[one</b> two|nid${id}]`,
    `[one <b>two|nid${id}]</b>`,
    `[one|<b>nid${id}</b>]`,
    `[one|nid111111<b>1111111</b>]`,
    `\\${marker("<b>escaped</b>")}`,
    `[missing|nid123]`,
  ]) {
    const { document } = await rendered(t, `<div class="linkRender">${html}</div>`);
    const expected = document.createElement("div");
    expected.innerHTML = html;
    assert.equal(document.querySelector(".linkRender").innerHTML, expected.innerHTML);
    assert.equal(document.querySelectorAll("a.noteLink").length, 0);
  }
});

test("desktop and an active desktop add-on do not run the mobile adapter", async t => {
  const html = `<div class="linkRender">${marker("<b>title</b>")}</div>`;
  const desktop = await rendered(t, html, { mobile: false });
  assert.equal(desktop.document.querySelectorAll("a").length, 0);
  const page = harness(html, { preload: false, mobile: true });
  t.after(page.close);
  page.window.AnkiNoteLinkerIsActive = true;
  page.window.eval(noteLinkRenderer);
  await page.flush();
  assert.equal(page.document.querySelectorAll("a").length, 0);
});

test("version two upgrades a reused WebView and newly swapped front/back content", async t => {
  const page = harness(`<div class="linkRender">${marker("first <b>bold</b>")}</div>`, { preload: false, mobile: true });
  t.after(page.close);
  Object.defineProperty(page.document, "readyState", { value: "complete" });
  page.window.eval(v2);
  assert.equal(page.window.AnkiNoteLinkerMobileVersion, 2);
  assert.equal(page.document.querySelectorAll("a").length, 0);
  page.window.eval(noteLinkRenderer);
  assert.equal(page.window.AnkiNoteLinkerMobileVersion, 3);
  assert.equal(page.document.querySelector("a").textContent, "first bold");
  page.document.body.innerHTML = `<div class="linkRender">${marker("second <sup>x</sup>")}</div>`;
  page.window.eval(noteLinkRenderer);
  assert.equal(page.document.querySelector("a").textContent, "second x");
});

test("a pending version-two DOMContentLoaded callback invokes only the latest renderer", async t => {
  const page = harness(`<div class="linkRender">${marker("<b>title</b>")}</div>`, { preload: false, mobile: true });
  t.after(page.close);
  Object.defineProperty(page.document, "readyState", { value: "loading" });
  page.window.eval(v2);
  page.window.eval(noteLinkRenderer);
  page.window.eval(noteLinkRenderer);
  assert.equal(page.window.AnkiNoteLinkerMobileVersion, 3);
  assert.equal(page.window.AnkiNoteLinkerMobileRenderPending, true);
  let calls = 0;
  const original = page.window.AnkiNoteLinkerRenderMobile;
  page.window.AnkiNoteLinkerRenderMobile = () => { calls++; original(); };
  page.document.dispatchEvent(new page.window.Event("DOMContentLoaded"));
  assert.equal(calls, 1);
  assert.equal(page.window.AnkiNoteLinkerMobileRenderPending, false);
  assert.equal(page.document.querySelectorAll("a.noteLink").length, 1);
});
