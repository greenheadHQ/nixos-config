import assert from "node:assert/strict";
import test from "node:test";
import { block, escape, harness } from "./harness.mjs";

const pendingStyle = '<style>.anki-fence-scope[data-anki-fence-pending] { opacity: 0; pointer-events: none; }</style>';
const field = (content, name = "question") =>
  `<section class="anki-code-scope anki-fence-scope" data-anki-fence-field="${name}" data-anki-fence-pending>${content}</section>`;
const fenced = (text, language = "javascript") => `\`\`\`${language}<br>${escape(text).replaceAll("\n", "<br>")}<br>\`\`\``;
const card = (content, id = "one", answer = false) =>
  `${pendingStyle}<main id="qa"><div data-anki-cid="${id}"></div>${answer ? '<hr id="answer">' : ""}${content}</main>`;
const scopes = page => [...page.document.querySelectorAll(".anki-fence-scope")];
const codes = page => [...page.document.querySelectorAll("code[data-anki-fenced]")];
const copies = page => [...page.document.querySelectorAll(".anki-code-copy button")];
const visible = (page, scope) => !scope.hasAttribute("data-anki-fence-pending") &&
  page.window.getComputedStyle(scope).opacity !== "0";

function fixture(t, content, options = {}) {
  const page = harness(card(content), options);
  t.after(page.close);
  return page;
}

function timers(page) {
  let next = 1;
  const active = new Map();
  page.window.setTimeout = (callback, delay) => {
    const id = next++;
    active.set(id, { callback, delay });
    return id;
  };
  page.window.clearTimeout = id => active.delete(id);
  return {
    fire(delay) {
      const found = [...active].find(([, timer]) => timer.delay === delay);
      assert.ok(found, `a ${delay} ms timer must be pending`);
      active.delete(found[0]);
      found[1].callback();
    },
  };
}

function firstReveals(page) {
  const snapshots = [];
  const observer = new page.window.MutationObserver(records => {
    for (const { target } of records) {
      if (target.hasAttribute("data-anki-fence-pending")) continue;
      snapshots.push({
        field: target.dataset.ankiFenceField,
        text: target.querySelector("code[data-anki-fenced]")?.textContent,
        highlighted: !!target.querySelector("code[data-anki-fenced].hljs"),
        copies: target.querySelectorAll(".anki-code-copy button").length,
      });
    }
  });
  observer.observe(page.document.body, {
    subtree: true, attributes: true, attributeFilter: ["data-anki-fence-pending"],
  });
  return snapshots;
}

async function start(page) {
  page.start();
  await page.flush();
}

async function loadEngine(page) {
  const script = page.scripts.find(script => typeof script.onload === "function");
  assert.ok(script, "the shared syntax asset must be loading");
  page.installBundle();
  script.onload();
  await page.flush();
}

for (const mobile of [false, true]) {
  test(`a ready engine reveals fenced code with colors and working copy together (${mobile ? "iPhone" : "Desktop"})`, async t => {
    const text = "const answer = '한글';\n\tconsole.log(answer);";
    const page = fixture(t, field(fenced(text)), { mobile });
    const first = firstReveals(page);
    assert.equal(visible(page, scopes(page)[0]), false, "the stored fence must not be visible before initialization");
    let copied;
    page.document.execCommand = () => { copied = page.document.activeElement.value; return true; };
    await start(page);
    assert.equal(visible(page, scopes(page)[0]), true);
    assert.deepEqual(first, [{ field: "question", text, highlighted: true, copies: 1 }]);
    assert.equal(codes(page)[0].textContent, text);
    assert.ok(codes(page)[0].querySelector(".hljs-keyword"));
    copies(page)[0].click();
    assert.equal(copied, text, "copy must exclude fences, token markup and UI labels");
  });
}

test("a field without a complete fence is released immediately without loading a code engine", async t => {
  const original = "ordinary question<br>```javascript<br>const incomplete = 1;";
  const page = fixture(t, field(original), { preload: false });
  page.start();
  assert.equal(visible(page, scopes(page)[0]), true);
  assert.equal(scopes(page)[0].innerHTML, original);
  assert.equal(page.scripts.length, 0);
  assert.equal(codes(page).length, 0);
  assert.equal(copies(page).length, 0);
});

test("a pending copy button cannot take keyboard focus or copy invisible text", async t => {
  const text = "echo pending";
  const page = fixture(t, field(fenced(text, "bash")), { preload: false });
  let attempts = 0, copied;
  page.document.execCommand = () => {
    attempts++;
    copied = page.document.activeElement.value;
    return true;
  };
  await start(page);
  const button = copies(page)[0];
  assert.equal(visible(page, scopes(page)[0]), false);
  assert.equal(button.disabled, true);
  button.focus();
  assert.notEqual(page.document.activeElement, button);
  button.click();
  assert.equal(attempts, 0);
  await loadEngine(page);
  assert.equal(visible(page, scopes(page)[0]), true);
  assert.equal(button.disabled, false);
  button.click();
  assert.equal(copied, text);
  assert.equal(attempts, 1);
});

test("a reused WebView replaces a previous HTML-only renderer before revealing a new fence", async t => {
  const text = "const afterTemplateUpdate = 1;";
  const page = fixture(t, field(fenced(text)));
  let oldCalls = 0;
  page.window.AnkiCodeHighlightV1 = {
    render() { oldCalls++; return Promise.resolve({}); },
  };
  const first = firstReveals(page);
  await start(page);
  assert.equal(oldCalls, 0, "the old renderer must not bypass the new first-display readiness contract");
  assert.deepEqual(first, [{ field: "question", text, highlighted: true, copies: 1 }]);
  assert.equal(visible(page, scopes(page)[0]), true);
});

test("an unknown or absent language first reveals a plain complete box with copy", async t => {
  const text = "  keep\tthese spaces & <signs>";
  const page = fixture(t, field(fenced(text, "not-a-language"), "question") + field(fenced(text, ""), "answer"));
  const first = firstReveals(page);
  await start(page);
  assert.equal(first.length, 2);
  for (const snapshot of first) assert.deepEqual(snapshot, {
    field: snapshot.field, text, highlighted: false, copies: 1,
  });
  assert.equal(codes(page).length, 2);
  assert.ok(codes(page).every(code => !code.classList.contains("hljs")));
  assert.ok(scopes(page).every(scope => visible(page, scope)));
});

test("a cold engine keeps the converted field hidden until colors and copy are ready", async t => {
  const text = "const first = 1;";
  const page = fixture(t, field(fenced(text)), { preload: false });
  timers(page);
  const first = firstReveals(page);
  await start(page);
  assert.equal(visible(page, scopes(page)[0]), false);
  assert.equal(codes(page)[0].textContent, text, "the hidden source should already be converted");
  assert.equal(first.length, 0);
  await loadEngine(page);
  assert.equal(visible(page, scopes(page)[0]), true);
  assert.deepEqual(first, [{ field: "question", text, highlighted: true, copies: 1 }]);
});

test("the engine deadline first reveals plain code and later colors the same box without rebuilding its UI", async t => {
  const text = "const delayed = 'value';\n\tconsole.log(delayed);";
  const page = fixture(t, field(fenced(text)), { preload: false });
  const clock = timers(page);
  const first = firstReveals(page);
  await start(page);
  const code = codes(page)[0];
  clock.fire(50);
  await page.flush();
  assert.equal(visible(page, scopes(page)[0]), true);
  assert.deepEqual(first, [{ field: "question", text, highlighted: false, copies: 1 }]);
  assert.equal(code.dataset.ankiFenceHighlight, "waiting");
  const pre = code.parentElement;
  const shell = pre.parentElement;
  const copy = copies(page)[0];
  const controls = page.document.querySelector(".anki-code-controls");
  const geometryProperties = ["fontFamily", "fontSize", "fontWeight", "whiteSpace", "padding", "border"];
  const geometry = geometryProperties.map(property => page.window.getComputedStyle(pre)[property]);
  let copied;
  page.document.execCommand = () => { copied = page.document.activeElement.value; return true; };
  copy.click();
  assert.equal(copied, text);
  await loadEngine(page);
  assert.equal(codes(page)[0], code);
  assert.equal(code.parentElement, pre);
  assert.equal(pre.parentElement, shell);
  assert.equal(copies(page)[0], copy);
  assert.equal(page.document.querySelector(".anki-code-controls"), controls);
  assert.deepEqual(geometryProperties.map(property => page.window.getComputedStyle(pre)[property]), geometry);
  assert.equal(code.textContent, text);
  assert.ok(code.classList.contains("hljs"));
  assert.equal(first.length, 1, "late color must not hide and reveal the field again");
});

test("an engine load error releases a complete plain box and does not retry coloring that field", async t => {
  const text = "const readable = 1;";
  const page = fixture(t, field(fenced(text)), { preload: false });
  timers(page);
  await start(page);
  page.scripts[0].onerror();
  await page.flush();
  assert.equal(visible(page, scopes(page)[0]), true);
  const code = codes(page)[0];
  assert.equal(code.textContent, text);
  assert.equal(code.dataset.ankiFenceHighlight, "plain");
  assert.equal(copies(page).length, 1);
  page.installBundle();
  page.start();
  await page.flush();
  await page.api().render();
  assert.equal(codes(page)[0], code);
  assert.equal(code.textContent, text);
  assert.equal(code.classList.contains("hljs"), false);
});

test("a late engine result cannot color a detached card or reveal the replacement before its own readiness", async t => {
  const page = fixture(t, field(fenced("const oldCard = 1;")), { preload: false });
  timers(page);
  await start(page);
  const oldScope = scopes(page)[0];
  const oldCode = codes(page)[0];
  page.document.body.innerHTML = card(field(fenced("const nextCard = 2;")), "two");
  await start(page);
  assert.equal(visible(page, scopes(page)[0]), false);
  assert.equal(page.scripts.length, 1, "both cards should share the pending engine request");
  await loadEngine(page);
  assert.equal(oldScope.isConnected, false);
  assert.equal(oldCode.classList.contains("hljs"), false);
  assert.equal(oldScope.hasAttribute("data-anki-fence-pending"), true);
  assert.equal(visible(page, scopes(page)[0]), true);
  assert.equal(codes(page)[0].textContent, "const nextCard = 2;");
  assert.ok(codes(page)[0].classList.contains("hljs"));
  assert.equal(copies(page).length, 1);
});

test("a deadline callback for a dropped card does not reveal or rebuild detached content", async t => {
  const page = fixture(t, field(fenced("const dropped = 1;")), { preload: false });
  const clock = timers(page);
  await start(page);
  const oldScope = scopes(page)[0];
  page.document.body.innerHTML = card(field("a replacement without code"), "two");
  await start(page);
  clock.fire(50);
  await page.flush();
  assert.equal(oldScope.hasAttribute("data-anki-fence-pending"), true);
  assert.equal(visible(page, scopes(page)[0]), true);
  assert.equal(scopes(page)[0].textContent, "a replacement without code");
  assert.equal(copies(page).length, 0);
});

test("a timed-out card's permitted late color cannot spill into a later card without code", async t => {
  const page = fixture(t, field(fenced("const timeoutCard = 1;")), { preload: false });
  const clock = timers(page);
  await start(page);
  clock.fire(50);
  await page.flush();
  const oldCode = codes(page)[0];
  assert.equal(visible(page, scopes(page)[0]), true);
  assert.equal(oldCode.classList.contains("hljs"), false);
  page.document.body.innerHTML = card(field("the next ordinary question"), "two");
  await start(page);
  const current = scopes(page)[0];
  const original = current.innerHTML;
  await loadEngine(page);
  assert.equal(oldCode.isConnected, false);
  assert.equal(oldCode.classList.contains("hljs"), false);
  assert.equal(current.innerHTML, original);
  assert.equal(visible(page, current), true);
  assert.equal(copies(page).length, 0);
});

test("FrontSide clones and repeated renderer scripts retain one copy control per code block", async t => {
  const page = fixture(t, field(fenced("const front = 1;")));
  await start(page);
  const staleButton = copies(page)[0];
  const clonedFront = scopes(page)[0].outerHTML;
  page.document.body.innerHTML = card(clonedFront + field(fenced("const back = 2;"), "answer"), "one", true);
  await start(page);
  await start(page);
  assert.equal(codes(page).length, 2);
  assert.equal(copies(page).length, 2);
  assert.equal(page.document.querySelectorAll(".anki-code-block").length, 2);
  assert.equal(page.document.querySelectorAll(".anki-code-controls").length, 1);
  assert.equal(page.document.querySelectorAll("#anki-code-style-v1").length, 1);
  assert.ok(scopes(page).every(scope => visible(page, scope)));
  let calls = 0;
  page.document.execCommand = () => { calls++; return true; };
  staleButton.click();
  assert.equal(calls, 0, "a detached FrontSide control must be inert");
  for (const copy of copies(page)) copy.click();
  assert.equal(calls, 2);
});

test("a late clipboard success from the front cannot mark the answer's controls as copied", async t => {
  const page = fixture(t, field(fenced("const front = 1;")));
  await start(page);
  let finish;
  page.document.execCommand = () => false;
  Object.defineProperty(page.window, "isSecureContext", { configurable: true, value: true });
  Object.defineProperty(page.window.navigator, "clipboard", { configurable: true, value: {
    writeText: () => new Promise(resolve => { finish = resolve; }),
  } });
  copies(page)[0].click();
  const oldControl = page.document.querySelector(".anki-code-copy");
  assert.equal(oldControl.dataset.state, "copying");
  page.document.body.innerHTML = card(field(fenced("const answer = 2;"), "answer"), "one", true);
  await start(page);
  finish();
  await page.flush();
  assert.equal(oldControl.dataset.state, "copying");
  assert.equal(page.document.querySelector(".anki-code-copy").dataset.state, "ready");
  assert.equal(copies(page)[0].getAttribute("aria-label"), "코드 복사");
  assert.equal(page.document.querySelector('[role="status"]').textContent, "");
});

test("large new fences preserve and copy all text without later coloring while ordinary HTML code still highlights", async t => {
  const text = `const large = '${"한".repeat(5000)}';\n  finalLine();`;
  const existing = "const existing = 3;";
  const page = fixture(t, field(fenced(text) + block(existing)), { preload: false });
  const clock = timers(page);
  await start(page);
  if (!visible(page, scopes(page)[0])) clock.fire(50);
  await page.flush();
  const code = codes(page)[0];
  assert.equal(visible(page, scopes(page)[0]), true);
  assert.equal(code.textContent, text);
  assert.equal(code.dataset.ankiFenceHighlight, "skipped");
  const copy = code.closest(".anki-code-block").querySelector(".anki-code-copy button");
  let copied;
  page.document.execCommand = () => { copied = page.document.activeElement.value; return true; };
  copy.click();
  assert.equal(copied, text);
  await loadEngine(page);
  await page.api().render();
  assert.equal(code.textContent, text);
  assert.equal(code.classList.contains("hljs"), false);
  assert.ok(page.document.querySelector("code:not([data-anki-fenced])").classList.contains("hljs"));
  assert.equal(copies(page).length, 2);
});

test("a later card's heavy fence is immediately readable even while its existing HTML code loads a cold engine", async t => {
  const page = fixture(t, field("initial question without code"), { preload: false });
  timers(page);
  await start(page);
  const text = `const laterHeavy = '${"x".repeat(5000)}';`;
  page.document.body.innerHTML = card(field(fenced(text) + block("const existingLater = 4;")), "two");
  await start(page);
  assert.equal(page.scripts.length, 1, "the old HTML code should still load its normal engine");
  assert.equal(visible(page, scopes(page)[0]), true,
    "the current heavy field must not be gated by an unrelated old HTML engine request");
  const code = codes(page)[0];
  assert.equal(code.textContent, text);
  assert.equal(code.dataset.ankiFenceHighlight, "skipped");
  assert.equal(copies(page).length, 2);
  await loadEngine(page);
  assert.equal(code.classList.contains("hljs"), false);
  assert.ok(page.document.querySelector("code:not([data-anki-fenced])").classList.contains("hljs"));
});

test("a fenced block still offers all its text for manual copy when the mobile clipboard is unavailable", async t => {
  const text = "  first\n\tsecond & <literal>\n";
  const page = fixture(t, field(fenced(text, "plaintext")), { mobile: true });
  await start(page);
  page.document.execCommand = () => false;
  copies(page)[0].click();
  await page.flush();
  const control = page.document.querySelector(".anki-code-copy");
  const input = page.document.querySelector(".anki-code-copy-manual textarea");
  assert.equal(control.dataset.state, "manual");
  assert.equal(input.closest(".anki-code-copy-manual").hidden, false);
  assert.equal(input.value, text);
  assert.equal(input.selectionStart, 0);
  assert.equal(input.selectionEnd, text.length);
  assert.equal(copies(page)[0].getAttribute("aria-label"), "코드 복사");
  assert.ok(!input.value.includes("```"));
});

test("unsupported content preserves the whole failed field plus one notice and never transforms it later", async t => {
  const original = fenced("const validEarlier = 1;") +
    '<br>```javascript<br>const keep = 2;<img src="fixture.png" alt="original image"><br>```<br>ordinary tail';
  const page = fixture(t, field(original) + field(fenced("const independent = 3;"), "answer"));
  await start(page);
  const failed = scopes(page)[0];
  assert.equal(visible(page, failed), true);
  assert.equal(failed.dataset.ankiFenceState, "failed");
  assert.equal(failed.querySelectorAll("code[data-anki-fenced]").length, 0,
    "conversion must roll back the entire field, including an earlier valid block");
  const notice = failed.querySelector(".anki-fence-error");
  assert.ok(notice?.textContent.trim());
  const clone = failed.cloneNode(true);
  clone.querySelector(".anki-fence-error").remove();
  assert.equal(clone.innerHTML, original);
  assert.ok(scopes(page)[1].querySelector("code.hljs"), "an independent field should still render normally");
  const unchanged = failed.innerHTML;
  await start(page);
  await page.api().render();
  assert.equal(failed.innerHTML, unchanged);
  assert.equal(failed.querySelectorAll(".anki-fence-error").length, 1);
  assert.equal(copies(page).length, 1);
});

test("an unexpected converter exception reveals the failed field once without hiding an independent answer", async t => {
  const page = fixture(t, field("initial ordinary question"));
  await start(page);
  const convert = page.window.AnkiFencedCodeV1.convert;
  page.window.AnkiFencedCodeV1.convert = scope => {
    if (scope.dataset.ankiFenceField === "question") throw new Error("simulated converter exception");
    return convert(scope);
  };
  const original = fenced("const preserved = 1;") + "<br>ordinary tail";
  page.document.body.innerHTML = card(field(original) + field(fenced("const independent = 2;"), "answer"), "two");
  await start(page);
  const failed = scopes(page)[0];
  assert.equal(visible(page, failed), true);
  assert.equal(failed.dataset.ankiFenceState, "failed");
  assert.ok(failed.querySelector(".anki-fence-error")?.textContent.trim());
  const clone = failed.cloneNode(true);
  clone.querySelector(".anki-fence-error").remove();
  assert.equal(clone.innerHTML, original);
  assert.ok(scopes(page)[1].querySelector("code.hljs"));
  const unchanged = failed.innerHTML;
  page.window.AnkiFencedCodeV1.convert = convert;
  await start(page);
  assert.equal(failed.innerHTML, unchanged);
  assert.equal(failed.querySelectorAll("code[data-anki-fenced]").length, 0);
  assert.equal(failed.querySelectorAll(".anki-fence-error").length, 1);
  assert.equal(copies(page).length, 1);
});
