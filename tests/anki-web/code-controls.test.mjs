import assert from "node:assert/strict";
import test from "node:test";
import { block, css, harness, renderer, scope } from "./harness.mjs";

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
  document.querySelector(".anki-code-scope > .anki-code-block > pre").remove();
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


const copyButtons = page => [...page.document.querySelectorAll(".anki-code-copy button")];
const copyState = page => page.document.querySelector(".anki-code-copy")?.dataset.state;
function clipboard(page, writeText) {
  Object.defineProperty(page.window, "isSecureContext", { configurable: true, value: true });
  Object.defineProperty(page.window.navigator, "clipboard", { configurable: true, value: { writeText } });
}
function copyTimers(page) {
  const pending = new Map();
  const set = page.window.setTimeout.bind(page.window);
  const clear = page.window.clearTimeout.bind(page.window);
  let serial = 10000;
  page.window.setTimeout = (callback, delay) => {
    if (delay !== 1800) return set(callback, delay);
    pending.set(++serial, callback);
    return serial;
  };
  page.window.clearTimeout = id => {
    if (!pending.delete(id)) clear(id);
  };
  return () => {
    const callbacks = [...pending.values()];
    pending.clear();
    for (const callback of callbacks) callback();
  };
}

test("each block gets its own copy control, including plain, large, hidden and folded code", async t => {
  const page = await rendered(t, `${block("const highlighted = 1;")}<details><summary>참고</summary>${block("plain", "plaintext")}</details><div hidden>${block("hidden")}</div>${block("x".repeat(5000))}<p><code>inline</code></p>`);
  assert.equal(copyButtons(page).length, 4);
  assert.equal(page.document.querySelectorAll(".anki-code-block").length, 4);
  for (const code of page.document.querySelectorAll("pre > code")) {
    const shell = code.parentElement.parentElement;
    assert.ok(shell.matches(".anki-code-block"));
    assert.equal(shell.querySelectorAll(".anki-code-copy").length, 1);
    assert.equal(code.querySelector("button"), null);
  }
  assert.equal(page.document.querySelector("p code").textContent, "inline");
  page.document.querySelector("details").open = true;
  page.document.querySelector("details").dispatchEvent(new page.window.Event("toggle"));
  assert.equal(copyButtons(page).length, 4);
});

test("synchronous copy preserves code whitespace and never includes controls", async t => {
  const text = "\tconst value = '< & >';\n\n  // 한글\n";
  const page = await rendered(t, block(text));
  const expire = copyTimers(page);
  let received;
  page.document.execCommand = name => {
    assert.equal(name, "copy");
    received = page.document.activeElement.value;
    return true;
  };
  copyButtons(page)[0].click();
  assert.equal(received, text);
  assert.equal(copyState(page), "success");
  assert.equal(page.document.querySelector("pre code").textContent, text);
  assert.equal(copyButtons(page)[0].getAttribute("aria-label"), "코드 복사됨");
  expire();
  assert.equal(copyState(page), "ready");
});

test("copy follows visible BR, block and cloze text without exposing hidden answers", async t => {
  const markup = '<pre><code>  first<br><span class="cloze" data-answer="secret attribute">[...]</span><span hidden>secret hidden</span><span style="display:none">secret display</span><span style="visibility:hidden">secret visibility</span><span style="opacity:0">secret opacity</span><span style="content-visibility:hidden">secret content</span><br><span>  last\n</span></code></pre>';
  const page = await rendered(t, markup + '<pre><code><div>one</div><div>two</div></code></pre>');
  const copied = [];
  page.document.execCommand = () => { copied.push(page.document.activeElement.value); return true; };
  copyButtons(page)[0].click();
  copyButtons(page)[1].click();
  assert.deepEqual(copied, ["  first\n[...]\n  last\n", "one\ntwo"]);
  assert.ok(!copied.join("").includes("secret"));
  assert.ok(page.document.querySelector(".cloze").hasAttribute("data-answer"), "source markup remains intact");
});

test("copy omits unpainted text while preserving shadows, strokes and descendant overrides", async t => {
  const cases = [
    ["transparent", "color:transparent", "secret", ""],
    ["rgba zero", "color:rgba(20,30,40,0)", "secret", ""],
    ["Color 4 zero", "color:color(display-p3 1 0 0 / 0)", "secret", ""],
    ["lab zero", "color:lab(50% 20 30 / 0%)", "secret", ""],
    ["zero size", "font-size:0", "secret", ""],
    ["restored color", "color:transparent", 'secret<span style="color:black">visible</span>', "visible"],
    ["restored size", "font-size:0", 'secret<span style="font-size:16px">visible</span>', "visible"],
    ["text shadow", "color:transparent;text-shadow:0 0 1px black", "visible", "visible"],
    ["text stroke", "color:transparent;-webkit-text-stroke-width:1px;-webkit-text-stroke-color:black", "visible", "visible"],
    ["transparent fill", "-webkit-text-fill-color:transparent", "secret", ""],
    ["opaque fill", "color:transparent;-webkit-text-fill-color:black", "visible", "visible"],
    ["clipped background", "color:transparent;background-clip:text;background-image:linear-gradient(red,blue)", "visible", "visible"],
    ["ancestor clipped background", "color:transparent;background-clip:text;background-image:linear-gradient(red,blue)", "<span>visible</span>", "visible"],
    ["partial alpha", "color:rgba(0,0,0,0.1)", "visible", "visible"],
    ["opaque zero channels", "color:rgb(0,0,0)", "visible", "visible"],
  ];
  const page = await rendered(t, cases.map(([, style, content]) =>
    `<pre><code>before [<span style="${style}">${content}</span>] after\n</code></pre>`).join(""));
  // JSDOM resolves even text-shadow:none to a bare current color. Use these
  // fixtures' declared shadows; actual paint is also checked in Chromium.
  const getStyle = page.window.getComputedStyle.bind(page.window);
  page.window.getComputedStyle = node => {
    const style = getStyle(node);
    let source = node;
    while (source && !source.style.textShadow) source = source.parentElement;
    Object.defineProperty(style, "textShadow", { value: source?.style.textShadow || "none" });
    return style;
  };
  const original = [...page.document.querySelectorAll("pre > code")].map(code => code.innerHTML);
  let copied;
  page.document.execCommand = () => { copied = page.document.activeElement.value; return true; };
  for (const [index, [name, , , expected]] of cases.entries()) {
    copyButtons(page)[index].click();
    const style = page.window.getComputedStyle(page.document.querySelectorAll("pre > code > span")[index]);
    const paint = ["color", "font-size", "-webkit-text-fill-color", "text-shadow", "-webkit-text-stroke-width", "-webkit-text-stroke-color", "background-clip", "-webkit-background-clip"].map(property => [property, style.getPropertyValue(property)]);
    assert.equal(copied, `before [${expected}] after\n`, `${name}: ${JSON.stringify(paint)}`);
  }
  assert.deepEqual([...page.document.querySelectorAll("pre > code")].map(code => code.innerHTML), original);
});

test("a hidden block or collapsed details cannot reveal its text through a programmatic copy", async t => {
  const page = await rendered(t, `<details><summary>참고</summary>${block("hidden answer")}</details>${block("visible")}`);
  let copied;
  page.document.execCommand = () => { copied = page.document.activeElement.value; return true; };
  copyButtons(page)[0].click();
  assert.equal(copied, "");
  const details = page.document.querySelector("details");
  details.open = true;
  copyButtons(page)[0].click();
  assert.equal(copied, "hidden answer");
});

test("legacy failure falls through to writeText in the same click and waits for success", async t => {
  const page = await rendered(t, block("line one\nline two\n"));
  const order = [];
  let finish;
  page.document.execCommand = () => { order.push("legacy"); return false; };
  clipboard(page, text => {
    order.push(text);
    return new Promise(resolve => { finish = resolve; });
  });
  copyButtons(page)[0].click();
  copyButtons(page)[0].click();
  assert.deepEqual(order, ["legacy", "line one\nline two\n"]);
  assert.equal(copyState(page), "copying");
  finish();
  await page.flush();
  assert.equal(copyState(page), "success");
});

test("CRLF text nodes bypass a normalizing textarea and reach writeText unchanged", async t => {
  const page = await rendered(t, block("initial", "plaintext"));
  const text = "first\r\n  second\r\n";
  page.document.querySelector("code").textContent = text;
  let copied;
  page.document.execCommand = () => { assert.fail("textarea would change CRLF"); };
  clipboard(page, value => { copied = value; return Promise.resolve(); });
  copyButtons(page)[0].click();
  await page.flush();
  assert.equal(copied, text);
  assert.equal(copyState(page), "success");
});

for (const mode of ["absent", "reject", "throw", "invalid"]) {
  test(`failed clipboard (${mode}) shows selectable multiline code without claiming success`, async t => {
    const text = "  first\n\tsecond\n";
    const page = await rendered(t, block(text));
    page.document.execCommand = () => false;
    if (mode !== "absent") clipboard(page, () => {
      if (mode === "throw") throw new Error("denied");
      if (mode === "invalid") return undefined;
      return Promise.reject(new Error("denied"));
    });
    copyButtons(page)[0].click();
    await page.flush();
    const input = page.document.querySelector(".anki-code-copy-manual textarea");
    assert.equal(copyState(page), "manual");
    assert.equal(input.closest(".anki-code-copy-manual").hidden, false);
    assert.equal(input.value, text);
    assert.equal(input.selectionStart, 0);
    assert.equal(input.selectionEnd, text.length);
    assert.equal(input.readOnly, true);
    assert.equal(copyButtons(page)[0].getAttribute("aria-label"), "코드 복사");
  });
}

test("a pending clipboard times out to manual copy and ignores its late success", async t => {
  const page = await rendered(t);
  const expire = copyTimers(page);
  let finish;
  page.document.execCommand = () => false;
  clipboard(page, () => new Promise(resolve => { finish = resolve; }));
  copyButtons(page)[0].click();
  assert.equal(copyState(page), "copying");
  expire();
  assert.equal(copyState(page), "manual");
  finish();
  await page.flush();
  assert.equal(copyState(page), "manual");
});

test("FrontSide clones and repeated scripts leave one live copy control per block", async t => {
  const page = await rendered(t);
  let calls = 0;
  page.document.execCommand = () => { calls++; return true; };
  const stale = copyButtons(page)[0];
  const front = page.document.querySelector(".anki-code-scope").innerHTML;
  await replace(page, front + block("answer"), { answer: true });
  page.start();
  page.start();
  assert.equal(copyButtons(page).length, 2);
  assert.equal(page.document.querySelectorAll(".anki-code-block").length, 2);
  assert.equal(page.document.querySelectorAll(".anki-code-controls").length, 1);
  stale.click();
  assert.equal(calls, 0);
  copyButtons(page)[1].click();
  assert.equal(calls, 1);
});

test("old clipboard completion cannot update a new card or remounted controls", async t => {
  const page = await rendered(t);
  let finish;
  page.document.execCommand = () => false;
  clipboard(page, () => new Promise(resolve => { finish = resolve; }));
  copyButtons(page)[0].click();
  await replace(page, block("new card"), { id: "1002" });
  finish();
  await page.flush();
  assert.equal(copyState(page), "ready");
  assert.equal(page.document.querySelector(".anki-code-copy-manual").hidden, true);
});

test("copy controls stop review gestures while code keeps native scrolling and selection", async t => {
  const page = await rendered(t);
  page.document.execCommand = () => false;
  copyButtons(page)[0].click();
  for (const name of ["pointerdown", "pointerup", "mousedown", "mouseup", "touchstart", "touchend", "keydown", "keypress", "keyup", "click"]) {
    let received = 0;
    const listener = () => received++;
    page.document.addEventListener(name, listener);
    for (const target of [copyButtons(page)[0], page.document.querySelector(".anki-code-copy-manual textarea")]) {
      target.dispatchEvent(new page.window.Event(name, { bubbles: true, cancelable: true }));
      assert.equal(received, 0, name);
    }
    page.document.querySelector("pre").dispatchEvent(new page.window.Event(name, { bubbles: true }));
    assert.equal(received, 1, `pre retains ${name}`);
    page.document.removeEventListener(name, listener);
  }
});

test("copy installs beside already-loaded V1 size controls without replacing their lifecycle", async t => {
  const page = harness(card(block("const value = 1;")));
  t.after(page.close);
  const legacy = renderer.slice(0, renderer.indexOf("  // Copy has its own lifecycle:")) + "  window[CONTROLS].mount();\n})();";
  page.window.eval(legacy);
  const original = page.window.AnkiCodeControlsV1;
  button(page, "larger").click();
  page.start();
  await page.flush();
  assert.equal(page.window.AnkiCodeControlsV1, original);
  assert.equal(scale(page), "110%");
  assert.equal(copyButtons(page).length, 1);
  button(page, "larger").click();
  assert.equal(scale(page), "120%");
});


test("HTML editor blank lines and final BR lines are preserved when copying", async t => {
  const page = await rendered(t, '<pre><code><div>one</div><div><br></div><div>two</div></code></pre><pre><code><div>one</div><div><br></div></code></pre>');
  const copied = [];
  page.document.execCommand = () => { copied.push(page.document.activeElement.value); return true; };
  for (const button of copyButtons(page)) button.click();
  assert.deepEqual(copied, ["one\n\ntwo", "one\n\n"]);
});
