import assert from "node:assert/strict";
import test from "node:test";
import { block, css, harness, scope } from "./harness.mjs";

const card = (content, { id = "1001", answer = false } = {}) =>
  `<main id="qa"><div class="anki-cid-copy" data-anki-cid="${id}"></div>${answer ? '<hr id="answer">' : ""}${scope(content)}</main>`;
const button = (page, action) => page.document.querySelector(`[data-action="${action}"]`);
const scale = page => page.document.querySelector("output")?.textContent;
const replace = async (page, content, options) => {
  page.document.body.innerHTML = card(content, options);
  page.start();
  await page.flush();
};
async function rendered(t, content = block("const first = 1;"), options = {}) {
  const page = harness(card(content, options));
  t.after(page.close);
  page.start();
  await page.flush();
  return page;
}

test("one toolbar precedes the first block and scales all code without changing source or inline code", async t => {
  const text = "\tconst first = '< & >';\n\n  // 한글\n";
  const page = await rendered(t, `<p><code>inline</code></p>${block(text)}<details><summary>참고</summary>${block("aligned  →  text", "plaintext")}</details>`);
  const { document } = page;
  const blocks = [...document.querySelectorAll("pre code")];
  const original = blocks.map(code => code.innerHTML);
  const bar = document.querySelector(".anki-code-controls");
  assert.equal(bar.nextElementSibling, blocks[0].parentElement);
  assert.equal(document.querySelectorAll(".anki-code-controls").length, 1);
  assert.equal(scale(page), "100%");
  assert.ok(button(page, "reset").disabled);
  button(page, "smaller").click();
  assert.equal(scale(page), "90%");
  assert.equal(document.querySelector("#qa").style.getPropertyValue("--anki-code-scale"), "0.9");
  assert.equal(blocks[0].textContent, text);
  assert.deepEqual(blocks.map(code => code.innerHTML), original);
  assert.equal(document.querySelector("p code").outerHTML, "<code>inline</code>");
  button(page, "reset").click();
  assert.equal(scale(page), "100%");
  assert.equal(document.querySelector("#qa").style.getPropertyValue("--anki-code-scale"), "1");
});

test("adjustment stops at 80 and 140 percent and reset restores the responsive baseline", async t => {
  const page = await rendered(t);
  for (let i = 0; i < 12; i++) button(page, "smaller").click();
  assert.equal(scale(page), "80%");
  assert.ok(button(page, "smaller").disabled);
  assert.ok(!button(page, "larger").disabled);
  for (let i = 0; i < 12; i++) button(page, "larger").click();
  assert.equal(scale(page), "140%");
  assert.ok(button(page, "larger").disabled);
  button(page, "reset").click();
  assert.equal(scale(page), "100%");
});

test("controls follow the first expanded block and preserve scale when all code is folded", async t => {
  const page = await rendered(t, `<details><summary>참고</summary>${block("optional")}</details><div hidden>${block("hidden")}</div>${block("required")}`);
  const { document, window } = page;
  const details = document.querySelector("details");
  const anchor = () => document.querySelector(".anki-code-controls")?.nextElementSibling.textContent;
  const toggle = open => {
    details.open = open;
    details.dispatchEvent(new window.Event("toggle"));
  };
  assert.equal(anchor(), "required");
  button(page, "smaller").click();
  toggle(true);
  assert.equal(anchor(), "optional");
  assert.equal(scale(page), "90%");
  toggle(false);
  assert.equal(anchor(), "required");
  document.querySelector(".anki-code-scope > pre").remove();
  page.start();
  await page.flush();
  assert.equal(document.querySelector(".anki-code-controls"), null);
  assert.equal(document.querySelector("#qa").style.getPropertyValue("--anki-code-scale"), "0.9");
  toggle(true);
  assert.equal(anchor(), "optional");
  assert.equal(scale(page), "90%");
  assert.equal(document.querySelectorAll(".anki-code-controls").length, 1);
});

test("details events on a replaced card cannot reset or remount the current controls", async t => {
  const page = await rendered(t, `<details open><summary>참고</summary>${block("old")}</details>`);
  const oldDetails = page.document.querySelector("details");
  const oldRoot = page.document.querySelector("#qa");
  const remove = oldRoot.removeEventListener.bind(oldRoot);
  let removed = 0;
  oldRoot.removeEventListener = (name, listener, capture) => {
    if (name === "toggle" && capture === true) removed++;
    remove(name, listener, capture);
  };
  await replace(page, block("new"), { id: "1002" });
  button(page, "larger").click();
  const toolbar = page.document.querySelector(".anki-code-controls");
  oldDetails.dispatchEvent(new page.window.Event("toggle"));
  assert.equal(removed, 1);
  assert.equal(scale(page), "110%");
  assert.equal(page.document.querySelector(".anki-code-controls"), toolbar);
  assert.equal(oldRoot.style.getPropertyValue("--anki-code-scale"), "");
});

test("a replacement answer DOM keeps the current scale, including duplicate FrontSide scripts", async t => {
  const page = await rendered(t);
  button(page, "larger").click();
  button(page, "larger").click();
  const stale = button(page, "smaller");
  // Include a DOM copy to exercise clients that retain already-rendered markup.
  const front = page.document.querySelector(".anki-code-scope").innerHTML;
  await replace(page, front + block("const answer = 2;"), { answer: true });
  page.start();
  page.start();
  await page.flush();
  assert.equal(scale(page), "120%");
  assert.equal(page.document.querySelectorAll(".anki-code-controls").length, 1);
  stale.click();
  assert.equal(scale(page), "120%");
  button(page, "smaller").click();
  assert.equal(scale(page), "110%", "one click changes only one step");
  assert.equal(page.document.querySelectorAll("pre code").length, 2);
});

test("next cards, including identical text and a repeated card after its answer, start at 100 percent", async t => {
  const page = await rendered(t);
  button(page, "smaller").click();
  await replace(page, block("const first = 1;"), { id: "1002" });
  assert.equal(scale(page), "100%");
  button(page, "larger").click();
  await replace(page, block("const first = 1;"), { id: "1002", answer: true });
  assert.equal(scale(page), "110%");
  await replace(page, block("const first = 1;"), { id: "1002" });
  assert.equal(scale(page), "100%");
});

test("previews without a valid CardID never leak scale into replaced card content", async t => {
  const page = await rendered(t, block("const preview = 1;"), { id: "{{CardID}}" });
  button(page, "smaller").click();
  page.start();
  await page.flush();
  assert.equal(scale(page), "90%");
  await replace(page, block("const preview = 1;"), { id: "{{CardID}}" });
  assert.equal(scale(page), "100%");
});

test("cards without block code show no toolbar or stale scale, and a later answer can add controls", async t => {
  const page = await rendered(t);
  button(page, "smaller").click();
  await replace(page, "<p><code>inline only</code></p>", { id: "1002" });
  assert.equal(page.document.querySelector(".anki-code-controls"), null);
  assert.equal(page.document.querySelector("#qa").style.getPropertyValue("--anki-code-scale"), "");
  await replace(page, block("answer"), { id: "1002", answer: true });
  assert.equal(scale(page), "100%");
});

test("controls stop reviewer events without cancelling native activation or code scrolling", async t => {
  const page = await rendered(t);
  for (const name of ["pointerdown", "pointerup", "mousedown", "mouseup", "touchstart", "touchend", "keydown", "keypress", "keyup", "click"]) {
    let received = 0;
    const listener = () => received++;
    page.document.addEventListener(name, listener);
    const event = new page.window.Event(name, { bubbles: true, cancelable: true });
    button(page, "larger").dispatchEvent(event);
    assert.equal(received, 0, name);
    assert.equal(event.defaultPrevented, false, name);
    page.document.querySelector("pre").dispatchEvent(new page.window.Event(name, { bubbles: true }));
    assert.equal(received, 1, `code retains native ${name}`);
    page.document.removeEventListener(name, listener);
  }
});

test("CSS refreshes in a reused reviewer and controls work even while highlighting fails", async t => {
  const page = harness(card(block("const readable = 1;")), { preload: false });
  t.after(page.close);
  const style = page.document.createElement("style");
  style.id = "anki-code-style-v1";
  style.textContent = ".anki-code-scope pre { font-size: 40px; }";
  page.document.head.append(style);
  page.start();
  assert.equal(style.textContent, css);
  button(page, "smaller").click();
  assert.equal(scale(page), "90%");
  page.scripts[0].onerror();
  await page.flush();
  assert.equal(page.document.querySelector("pre code").textContent, "const readable = 1;");
  assert.equal(page.document.querySelectorAll("#anki-code-style-v1").length, 1);
});
