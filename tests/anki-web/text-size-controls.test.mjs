import assert from "node:assert/strict";
import test from "node:test";
import { block, cardIdScript, harness, scope, textSizeScript } from "./harness.mjs";

const row = id => `<div class="anki-cid-copy" data-anki-cid="${id}"></div>`;
const card = ({ id = "1001", answer = false, before = "", content = "" } = {}) =>
  `<main id="qa"><div class="question">질문</div>${before}${row(id)}` +
  `${answer ? '<hr id="answer"><div class="answer">답</div>' : ""}${content}</main>`;
const controls = page => [...page.document.querySelectorAll(".anki-text-controls")];
const button = (page, action) => page.document.querySelector(`.anki-text-controls [data-action="${action}"]`);
const scale = page => page.document.querySelector(".anki-text-controls output")?.textContent;
const variable = page => page.document.documentElement.style.getPropertyValue("--anki-text-scale");

// Template order: the card ID fragment renders its row, then this fragment joins it.
function rendered(t, html = card()) {
  const page = harness(html);
  t.after(page.close);
  page.render = () => {
    page.window.eval(cardIdScript);
    page.window.eval(textSizeScript);
  };
  page.replace = next => {
    page.document.body.innerHTML = next;
    page.render();
  };
  page.render();
  return page;
}

test("one control joins the card ID row before the copy button and scales body text from the root", t => {
  const page = rendered(t);
  const [bar] = controls(page);
  assert.equal(controls(page).length, 1);
  assert.ok(bar.parentElement.matches(".anki-cid-copy"));
  assert.ok(bar.nextElementSibling.matches(".anki-cid-copy__button"));
  assert.equal(bar.getAttribute("aria-label"), "이 카드의 본문 글자 크기");
  assert.equal(scale(page), "100%");
  assert.equal(variable(page), "");
  assert.ok(button(page, "reset").disabled);
  button(page, "smaller").click();
  assert.equal(scale(page), "90%");
  assert.equal(variable(page), "0.9");
  assert.ok(!button(page, "reset").disabled);
  button(page, "reset").click();
  assert.equal(scale(page), "100%");
  assert.equal(variable(page), "");
});

test("adjustment stops at 80 and 140 percent", t => {
  const page = rendered(t);
  for (let i = 0; i < 12; i++) button(page, "smaller").click();
  assert.equal(scale(page), "80%");
  assert.equal(variable(page), "0.8");
  assert.ok(button(page, "smaller").disabled);
  assert.ok(!button(page, "larger").disabled);
  for (let i = 0; i < 12; i++) button(page, "larger").click();
  assert.equal(scale(page), "140%");
  assert.equal(variable(page), "1.4");
  assert.ok(button(page, "larger").disabled);
});

test("the answer keeps the question's scale; another card or returning to the question resets it", t => {
  const page = rendered(t);
  button(page, "smaller").click();
  page.replace(card({ answer: true }));
  assert.equal(scale(page), "90%");
  assert.equal(variable(page), "0.9");
  page.replace(card());
  assert.equal(scale(page), "100%");
  assert.equal(variable(page), "");
  button(page, "larger").click();
  page.replace(card({ id: "1002" }));
  assert.equal(scale(page), "100%");
  assert.equal(variable(page), "");
});

test("a rewritten card ID row gets the control back with the same scale", t => {
  const page = rendered(t);
  button(page, "larger").click();
  page.window.eval(cardIdScript);
  assert.equal(controls(page).length, 0);
  page.window.eval(textSizeScript);
  assert.equal(controls(page).length, 1);
  assert.equal(scale(page), "110%");
  page.render();
  assert.equal(controls(page).length, 1);
  assert.equal(scale(page), "110%");
  // The copy button still works from its own listeners after the control joins.
  assert.equal(page.document.querySelector(".anki-cid-copy").dataset.state, "ready");
});

test("stale FrontSide markup and duplicate rows leave one live control", t => {
  const stale = '<div class="anki-text-controls"><output>130%</output></div>';
  const page = rendered(t, card({ answer: true, before: `${stale}${row("1001")}` }));
  assert.equal(page.document.querySelectorAll(".anki-cid-copy").length, 1);
  assert.equal(controls(page).length, 1);
  assert.equal(scale(page), "100%");
  assert.ok(controls(page)[0].parentElement.matches(".anki-cid-copy"));
});

test("a preview without CardID keeps the scale only while its row survives", t => {
  const page = rendered(t, card({ id: "" }));
  assert.ok(page.document.querySelector(".anki-cid-copy__button").disabled);
  button(page, "smaller").click();
  page.window.eval(textSizeScript);
  assert.equal(scale(page), "90%");
  page.replace(card({ id: "" }));
  assert.equal(scale(page), "100%");
  button(page, "smaller").click();
  page.replace(card());
  assert.equal(scale(page), "100%");
});

test("control input does not reach reviewer gesture handlers", t => {
  const page = rendered(t);
  const { document, window } = page;
  const seen = [];
  const names = ["pointerdown", "pointerup", "mousedown", "mouseup", "touchstart", "touchend",
    "keydown", "keypress", "keyup", "click"];
  for (const name of names) document.addEventListener(name, () => seen.push(name));
  for (const name of names) {
    button(page, "larger").dispatchEvent(new window.Event(name, { bubbles: true, cancelable: true }));
  }
  assert.deepEqual(seen, []);
  assert.equal(scale(page), "110%");
});

test("body and code scales stay independent", async t => {
  const page = rendered(t, card({ answer: true, content: scope(block("const answer = 1;")) }));
  page.start();
  await page.flush();
  const qa = page.document.querySelector("#qa");
  const code = action => page.document.querySelector(`.anki-code-controls [data-action="${action}"]`);
  button(page, "smaller").click();
  assert.equal(variable(page), "0.9");
  assert.equal(qa.style.getPropertyValue("--anki-code-scale"), "1");
  code("larger").click();
  assert.equal(qa.style.getPropertyValue("--anki-code-scale"), "1.1");
  assert.equal(variable(page), "0.9");
  assert.equal(scale(page), "90%");
  assert.equal(page.document.querySelector(".anki-code-controls output").textContent, "110%");
});

test("without a card ID row there is no control and no residual scale", t => {
  const page = rendered(t);
  button(page, "smaller").click();
  page.replace('<main id="qa"><div class="question">질문</div></main>');
  assert.equal(controls(page).length, 0);
  assert.equal(variable(page), "");
});
