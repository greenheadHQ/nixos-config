import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import test from "node:test";
import { addonPath, harness, scratchpadScript } from "./harness.mjs";

const fragment = await readFile(resolve(addonPath, "difficulty-badge.html"), "utf8");
const script = fragment.match(/<script>([\s\S]*)<\/script>/)[1];
const markup = fragment.replace(/<script>[\s\S]*<\/script>/, "");
const now = Date.UTC(2026, 9, 4, 12);
const day = 86400000;
const signal = (overrides = {}) => ({ kind: "review", samples: 5, again: 2, hard: 1,
  first_review_at: now - 200 * day, last_review_at: now - day, late_days_estimate: null, ...overrides });
const payload = (overrides = {}) => ({ schema_version: 1, card_id: "1001", generated_at: now,
  source: "local", signals: [signal()], ...overrides });
const card = (id = "1001", { answer = false, before = "" } = {}) =>
  `<main id="qa">${before}${markup.replaceAll("{{CardID}}", id)}<div class="question">질문</div>` +
  `${answer ? '<hr id="answer"><div class="answer">정답 원문</div>' : ""}</main>`;
const root = page => page.document.querySelector("[data-anki-difficulty-card]");
const button = page => root(page)?.querySelector("button");
const panel = page => root(page)?.querySelector(".anki-difficulty-badge__evidence");

function rendered(t, { html = card(), data = payload(), mobile = false } = {}) {
  const page = harness(html, { preload: false, mobile });
  t.after(page.close);
  page.api = () => page.window.AnkiDifficultyBadgeV1;
  page.render = value => {
    page.window.AnkiDifficultyCurrent = value;
    page.window.eval(script);
  };
  page.replace = (html, value) => {
    page.document.body.innerHTML = html;
    page.render(value);
  };
  page.render(data);
  return page;
}

test("a small badge appears before the question; only its evidence expands", t => {
  const page = rendered(t);
  assert.equal(root(page).hidden, false);
  assert.equal(root(page).nextElementSibling.textContent, "질문");
  assert.equal(button(page).textContent, "점검 후보▾");
  assert.equal(button(page).getAttribute("aria-expanded"), "false");
  assert.equal(button(page).getAttribute("aria-controls"), panel(page).id);
  assert.equal(panel(page).hidden, true);
  button(page).click();
  assert.equal(panel(page).hidden, false);
  assert.match(panel(page).textContent, /최근 정규 복습 5회 중 다시 2회 · 어려움 1회/);
  assert.match(panel(page).textContent, /기록 기간:/);
  assert.doesNotMatch(panel(page).textContent, /기록 기준:|기록된 평가를 바탕/);
  assert.equal(page.document.querySelector("#answer"), null);
  assert.doesNotMatch(panel(page).textContent, /정답 원문/);
  assert.equal(button(page).getAttribute("aria-expanded"), "true");
  button(page).click();
  assert.equal(panel(page).hidden, true);
});

test("learning evidence counts evaluations and interval delay is explicitly an estimate", t => {
  const page = rendered(t, { data: payload({ signals: [signal({ late_days_estimate: 8 }),
    signal({ kind: "learning", samples: 9, again: 3, hard: 4, first_review_at: now - day })] }) });
  button(page).click();
  assert.equal(panel(page).querySelectorAll("li").length, 2);
  assert.match(panel(page).textContent, /이번 학습·재학습 과정에서 누적 9회 중 다시 3회 · 어려움 4회/);
  assert.match(panel(page).textContent, /기록된 간격 기준 지연 추정: 8일/);
  assert.doesNotMatch(panel(page).textContent, /예정일|원인|의욕|기억력/);
});

test("FrontSide duplicates and reruns leave one live badge on both sides", t => {
  const page = rendered(t);
  button(page).click();
  const stale = root(page).outerHTML;
  page.replace(card("1001", { answer: true, before: stale }), payload());
  assert.equal(page.document.querySelectorAll("[data-anki-difficulty-card]").length, 1);
  assert.equal(page.document.querySelectorAll(".anki-difficulty-badge__button").length, 1);
  assert.equal(panel(page).hidden, false);
  assert.equal(page.document.querySelector(".answer").textContent, "정답 원문");
  assert.doesNotMatch(panel(page).textContent, /정답 원문/);
  page.window.eval(script);
  button(page).click();
  assert.equal(panel(page).hidden, true);
  // Returning to the question starts closed, even if the prior answer was open.
  button(page).click();
  page.replace(card(), payload());
  assert.equal(panel(page).hidden, true);
});

test("a different card never inherits a stale payload or expanded panel", t => {
  const page = rendered(t);
  button(page).click();
  page.replace(card("1002"), payload());
  assert.equal(root(page).hidden, true);
  assert.equal(button(page), null);
  assert.equal(page.window.AnkiDifficultyCurrent, null);
  page.replace(card("1002"), payload({ card_id: "1002", generated_at: now + 1000 }));
  assert.equal(root(page).hidden, false);
  assert.equal(panel(page).hidden, true);
  // An asynchronous update from the previous card cannot clear this card.
  assert.equal(page.api().render(payload()), false);
  assert.equal(root(page).hidden, false);
  assert.equal(page.window.AnkiDifficultyCurrent.card_id, "1002");
});

test("older same-card data cannot overwrite a newer result, including a cleared signal", t => {
  const page = rendered(t);
  assert.equal(page.api().render(payload({ generated_at: now + 1000, signals: [] })), false);
  assert.equal(root(page).hidden, true);
  assert.equal(page.api().render(payload()), false);
  assert.equal(root(page).hidden, true);
  assert.equal(page.window.AnkiDifficultyCurrent.generated_at, now + 1000);
  assert.equal(page.api().render(payload({ generated_at: now + 2000 })), true);
  assert.equal(root(page).hidden, false);
});

test("missing, mismatched, unsupported, and malformed payloads hide all evidence", t => {
  const invalid = [undefined, null, {}, payload({ card_id: "1002" }), payload({ card_id: 1001 }),
    payload({ schema_version: 2 }), payload({ source: "snapshot" }), payload({ generated_at: "today" }),
    payload({ signals: null }), payload({ signals: [signal(), signal()] }),
    payload({ signals: [signal({ kind: "other" })] }), payload({ signals: [signal({ samples: 0 })] }),
    payload({ signals: [signal({ samples: 6 })] }), payload({ signals: [signal({ again: -1 })] }),
    payload({ signals: [signal({ hard: 0.5 })] }), payload({ signals: [signal({ again: 5, hard: 1 })] }),
    payload({ signals: [signal({ first_review_at: now, last_review_at: now - day })] }),
    payload({ signals: [signal({ last_review_at: now + day })] }),
    payload({ signals: [signal({ late_days_estimate: -1 })] }),
    payload({ signals: [signal({ late_days_estimate: "<img src=x onerror=alert(1)>" })] })];
  const page = rendered(t);
  for (const value of invalid) {
    page.render(value);
    assert.equal(root(page).hidden, true, JSON.stringify(value));
    assert.equal(root(page).children.length, 0);
  }
  assert.equal(page.document.querySelector("img"), null);
  page.replace(card(""), payload());
  assert.equal(root(page).hidden, true);
  page.replace(card("{{CardID}}"), payload());
  assert.equal(root(page).hidden, true);
});

test("absence of a fragment removes an old live view; mounting an explicit scope is supported", t => {
  const page = rendered(t);
  const oldButton = button(page);
  page.replace('<main id="qa"><div class="question">다른 화면</div></main>', payload());
  assert.equal(page.document.querySelector(".anki-difficulty-badge__button"), null);
  oldButton.click();
  page.document.querySelector("#qa").innerHTML = markup.replaceAll("{{CardID}}", "1001");
  assert.equal(page.api().mount(root(page), payload()), true);
  assert.equal(root(page).hidden, false);
});

test("badge and evidence interactions cannot bubble into reviewer flip handlers", t => {
  const page = rendered(t, { mobile: true });
  const seen = [];
  const events = ["pointerdown", "pointerup", "mousedown", "mouseup", "touchstart", "touchend", "touchmove",
    "keydown", "keypress", "keyup", "click", "dblclick"];
  for (const name of events) page.document.addEventListener(name, () => seen.push(name));
  for (const name of events) button(page).dispatchEvent(new page.window.Event(name, { bubbles: true, cancelable: true }));
  for (const name of events) panel(page).dispatchEvent(new page.window.Event(name, { bubbles: true, cancelable: true }));
  assert.deepEqual(seen, []);
  assert.equal(panel(page).hidden, false);
  assert.equal(page.document.querySelector("#answer"), null);
});

test("Enter and Space toggle evidence; Escape closes it and restores button focus", t => {
  const page = rendered(t);
  const key = value => button(page).dispatchEvent(new page.window.KeyboardEvent("keydown", {
    key: value, bubbles: true, cancelable: true
  }));
  assert.equal(key("Enter"), false);
  assert.equal(panel(page).hidden, false);
  assert.equal(key(" "), false);
  assert.equal(panel(page).hidden, true);
  key("Enter");
  panel(page).dispatchEvent(new page.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
  assert.equal(panel(page).hidden, true);
  assert.equal(page.document.activeElement, button(page));
});

test("the visible pill has a 44px touch target and follows app night-mode classes", t => {
  const page = rendered(t);
  const style = page.window.getComputedStyle(button(page));
  assert.equal(style.minHeight, "44px");
  assert.equal(style.minWidth, "44px");
  const light = page.window.getComputedStyle(root(page)).getPropertyValue("--difficulty-text").trim();
  for (const name of ["nightMode", "night_mode", "night-mode"]) {
    page.document.body.className = name;
    const dark = page.window.getComputedStyle(root(page)).getPropertyValue("--difficulty-text").trim();
    assert.notEqual(dark, light);
  }
});

test("rendered evidence uses text nodes and does not read question or answer content", t => {
  const page = rendered(t, { html: card("1001", { answer: true }) });
  const question = page.document.querySelector(".question").innerHTML;
  const answer = page.document.querySelector(".answer").innerHTML;
  assert.doesNotMatch(script, /innerHTML|querySelector\(["']\.(?:answer|question)/);
  // A non-contract property must never be used as HTML or as card evidence.
  page.api().render(payload({ explanation: '<img src=x onerror="alert(1)">정답 원문' }));
  button(page).click();
  assert.equal(page.document.querySelector("img"), null);
  assert.doesNotMatch(panel(page).textContent, /정답 원문/);
  assert.equal(page.document.querySelector(".question").innerHTML, question);
  assert.equal(page.document.querySelector(".answer").innerHTML, answer);
});

test("badge evidence and scratchpad coexist across answer and next-card transitions", async t => {
  const content = (id, answer = false) =>
    `${answer ? '<span hidden data-anki-scratchpad-answer></span>' : ""}` +
    `<div class="rehab-card" data-anki-scratchpad-card>${markup.replaceAll("{{CardID}}", id)}` +
    `<div class="question">질문</div></div><span data-anki-cid="${id}"></span>` +
    `${answer ? '<hr id="answer"><div class="answer">정답</div>' : ""}`;
  const page = rendered(t, { html: `<main id="qa">${content("1001")}</main>` });
  page.window.scrollTo = () => {};
  page.window.eval(scratchpadScript);
  const input = () => page.document.querySelector(".anki-scratchpad textarea");
  const draft = "회상한 내용\n두 번째 줄";
  input().value = draft;
  input().dispatchEvent(new page.window.Event("input", { bubbles: true }));
  button(page).click();
  await page.flush();
  assert.equal(panel(page).hidden, false);
  assert.equal(input().value, draft);

  page.document.getElementById("qa").innerHTML = content("1001", true);
  page.render(payload({ generated_at: now + 1 }));
  page.window.eval(scratchpadScript);
  await page.flush();
  assert.equal(page.document.querySelectorAll(".anki-scratchpad").length, 1);
  assert.equal(page.document.querySelectorAll("[data-anki-difficulty-card]").length, 1);
  assert.equal(input().value, draft);
  button(page).click();
  button(page).click();
  await page.flush();
  assert.equal(input().value, draft);

  page.document.getElementById("qa").innerHTML = content("1002");
  page.render(payload({ card_id: "1002", generated_at: now + 2, signals: [] }));
  page.window.eval(scratchpadScript);
  await page.flush();
  assert.equal(root(page).hidden, true);
  assert.equal(input().value, "");
});
