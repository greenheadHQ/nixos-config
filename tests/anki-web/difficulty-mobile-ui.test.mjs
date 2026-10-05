import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import test from "node:test";
import { addonPath, harness } from "./harness.mjs";

const fragment = await readFile(resolve(addonPath, "difficulty-badge.html"), "utf8");
const script = fragment.match(/<script>([\s\S]*)<\/script>/)[1];
const markup = fragment.replace(/<script>[\s\S]*<\/script>/, "");
const scheduler = await readFile(resolve(addonPath, "difficulty-scheduler.js"), "utf8");
const names = ["again", "hard", "good", "easy"];
const clone = value => JSON.parse(JSON.stringify(value));
const packed = values => values.reduce((value, grade) => value * 5 + grade, 0);
const empty = (cid = 1001) => [2, cid, 0, -1, 0, 0, 0];
const active = (cid = 1001) => [2, cid, packed([1, 1, 3]), 0, 0, 0, 0];
const encode = state => state.map(value => value === -1 ? "-" : value.toString(36)).join(".");
const decode = value => value.split(".").map(part => part === "-" ? -1 : parseInt(part, 36));
const root = page => page.document.querySelector("[data-anki-difficulty-card]");
const button = page => root(page)?.querySelector("button");
const panel = page => root(page)?.querySelector(".anki-difficulty-badge__evidence");
const card = (id, { answer = false, before = "" } = {}) =>
  `<main id="qa">${before}${markup.replaceAll("{{CardID}}", String(id))}<div class="question">질문</div>` +
  `${answer ? '<hr id="answer"><div class="answer">정답 원문</div>' : ""}</main>`;
const native = kind => kind === "preview" ? { filtered: { preview: { scheduledSecs: 60, finished: false } } }
  : kind === "review" ? { normal: { review: { scheduledDays: 17, elapsedDays: 19, easeFactor: 2.4, lapses: 2 } } }
    : { normal: { [kind]: kind === "relearning" ? { review: { scheduledDays: 17, elapsedDays: 17 },
      learning: { scheduledSecs: 60, remainingSteps: 1 } } : { scheduledSecs: 60, remainingSteps: 1 } } };

function pageFor(t) {
  const page = harness("", { preload: false, mobile: true });
  t.after(page.close);
  page.window.TextEncoder = TextEncoder;
  page.api = () => page.window.AnkiDifficultyBadgeV1;
  page.show = (id = 1001, options) => {
    page.document.body.innerHTML = card(id, options);
    page.window.eval(script);
  };
  page.remount = () => page.window.eval(script);
  page.schedule = (state = active(), { kind = "review", candidateKind = kind === "preview" ? "preview" : "review",
    data = { dce: encode(state) } } = {}) => {
    const current = native(kind);
    page.window.states = { current: { ...current, customData: JSON.stringify(data) },
      ...Object.fromEntries(names.map(name => [name, native(candidateKind)])) };
    page.window.customData = Object.fromEntries(names.map(name => [name, clone(data)]));
    const before = clone(page.window.states);
    page.window.eval(scheduler);
    assert.deepEqual(clone(page.window.states), before, "UI delivery must not write native scheduling states");
    return clone(page.window.AnkiDifficultyEvents);
  };
  page.deliver = snapshot => {
    page.window.AnkiDifficultyEvents = clone(snapshot);
    return page.api()?.receive(page.window.AnkiDifficultyEvents);
  };
  return page;
}

function visible(page, text = /최근 복습 3회: 다시 2회, 어려움 0회/) {
  assert.equal(root(page).hidden, false);
  assert.match(panel(page).textContent, text);
  assert.doesNotMatch(panel(page).textContent, /기록 기간:|기록 기준:|지연 추정|정답 원문/);
  assert.match(panel(page).textContent, /이 카드에 저장된 복습 회차 기준/);
}

function hidden(page) {
  assert.equal(root(page).hidden, true);
  assert.equal(root(page).children.length, 0);
}

function localPayload(signals = []) {
  const now = Date.UTC(2026, 9, 5, 12);
  return { schema_version: 1, source: "local", card_id: "1001", generated_at: now,
    signals: signals.map(signal => ({ first_review_at: now - 86400000, last_review_at: now,
      late_days_estimate: null, ...signal })) };
}

test("a synchronous scheduler callback before the first template renders current evidence", t => {
  const page = pageFor(t);
  const snapshot = page.schedule();
  assert.equal(snapshot.sequence, 1);
  assert.equal(page.api(), undefined);
  page.show();
  visible(page);
  assert.equal(panel(page).hidden, true);
});

test("a callback after the template binds its waiting root synchronously", t => {
  const page = pageFor(t);
  page.show();
  hidden(page);
  page.schedule();
  visible(page);
});

test("question-to-answer and repeated mounts retain one interactive badge and its expanded state", t => {
  const page = pageFor(t);
  page.schedule();
  page.show();
  button(page).click();
  assert.equal(panel(page).hidden, false);
  const front = root(page).outerHTML;
  page.show(1001, { answer: true, before: front });
  visible(page);
  assert.equal(panel(page).hidden, false);
  for (let index = 0; index < 3; index += 1) page.remount();
  assert.equal(page.document.querySelectorAll("[data-anki-difficulty-card]").length, 1);
  assert.equal(page.document.querySelectorAll(".anki-difficulty-badge__button").length, 1);
  button(page).click();
  assert.equal(panel(page).hidden, true, "reruns must not attach duplicate toggle handlers");
  assert.equal(page.document.querySelector(".answer").textContent, "정답 원문");
});

test("the same mounted question does not adopt a newly calculated hypothetical or foreign snapshot", t => {
  const page = pageFor(t);
  page.schedule();
  page.show();
  const stable = root(page);
  page.schedule(empty());
  page.remount();
  assert.strictEqual(root(page), stable);
  visible(page);
});

test("the next card cannot inherit a previous card's evidence or an expanded panel", t => {
  const page = pageFor(t);
  page.schedule();
  page.show();
  button(page).click();
  page.show(1002);
  hidden(page);
  page.schedule(active(1001));
  hidden(page);
  page.schedule(active(1002));
  visible(page);
  assert.equal(panel(page).hidden, true);
  assert.match(button(page).id, /1002$/);
});

test("a callback for the next card before its template cannot replace the displayed card", t => {
  const page = pageFor(t);
  page.schedule();
  page.show();
  page.schedule([2, 1002, packed([2, 2, 2]), 0, 0, 0, 0]);
  visible(page);
  page.show(1002);
  visible(page, /최근 복습 3회: 다시 0회, 어려움 3회/);
});

test("same-card re-entry waits for a new callback and accepts Undo decreasing the counters", t => {
  const page = pageFor(t);
  page.schedule();
  page.show();
  page.show(1001, { answer: true });
  page.show();
  hidden(page);
  page.schedule([2, 1001, packed([1, 1]), -1, 0, 0, 0]);
  hidden(page);
  page.show();
  hidden(page);
  page.schedule(active());
  visible(page);
});

test("same-card Undo delivered before its replacement question clears the old badge", t => {
  const page = pageFor(t);
  page.schedule();
  page.show();
  page.show(1001, { answer: true });
  page.schedule(empty());
  page.show();
  hidden(page);
  page.schedule(active());
  page.show();
  visible(page);
});

test("Preview, missing seed, and rejected summaries never display previous evidence", t => {
  const page = pageFor(t);
  for (const options of [{ kind: "preview" }, { data: {} }, { data: { dce: "3.1.0.-.0.0.0" } },
    { data: { dce: encode([2, 1001, 0, -1, 1, 1, 1]) } }]) {
    page.schedule();
    page.show();
    visible(page);
    page.show();
    hidden(page);
    const snapshot = page.schedule(active(), options);
    assert.equal(snapshot.valid, false);
    hidden(page);
    page.show(1001, { answer: true });
    hidden(page);
  }
});

test("learning evidence is independent of the Review signal and disappears on native Review", t => {
  const page = pageFor(t);
  const state = [2, 1001, packed([1, 1, 3]), 0, 7, 3, 4];
  page.schedule(state, { kind: "relearning" });
  page.show();
  visible(page);
  assert.match(panel(page).textContent, /학습·재학습 7회: 다시 3회, 어려움 4회/);
  assert.equal(panel(page).querySelectorAll("li").length, 2);
  page.schedule(state, { kind: "review" });
  page.show();
  visible(page);
  assert.equal(panel(page).querySelectorAll("li").length, 1);
  assert.doesNotMatch(panel(page).textContent, /학습·재학습/);
});

test("actual selected candidates trigger and recover only on the card's following presentation", t => {
  const page = pageFor(t);
  let state = empty();
  for (const grade of [1, 1, 3]) {
    page.schedule(state);
    page.show();
    hidden(page);
    page.show(1001, { answer: true });
    hidden(page);
    state = decode(page.window.customData[names[grade - 1]].dce);
  }
  assert.equal(state[3], 0);
  for (const grade of [3, 2, 3]) {
    page.schedule(state);
    page.show();
    assert.equal(root(page).hidden, false);
    page.show(1001, { answer: true });
    assert.equal(root(page).hidden, false, "candidate recovery must not erase current evidence before grading");
    state = decode(page.window.customData[names[grade - 1]].dce);
  }
  assert.deepEqual(state, empty());
  page.schedule(state);
  page.show();
  hidden(page);
});

test("the selected learning answer reaches the threshold and actual graduation clears it", t => {
  const page = pageFor(t);
  const before = [2, 1001, 0, -1, 2, 2, 0];
  page.schedule(before, { kind: "learning", candidateKind: "learning" });
  page.show();
  hidden(page);
  const triggered = decode(page.window.customData.again.dce);
  assert.deepEqual(triggered.slice(4), [3, 3, 0]);
  page.schedule(triggered, { kind: "learning", candidateKind: "review" });
  page.show();
  visible(page, /학습·재학습 3회: 다시 3회, 어려움 0회/);
  const graduated = decode(page.window.customData.good.dce);
  page.schedule(graduated);
  page.show();
  hidden(page);
});

test("mobile event evidence is independent of wall-clock reads and backwards clock changes", t => {
  const page = pageFor(t);
  const RealDate = page.window.Date;
  const blocked = () => { throw Error("event UI must not read calendar time"); };
  page.window.Date = new Proxy(RealDate, { construct: blocked, apply: blocked,
    get(target, key) { return key === "now" ? blocked : Reflect.get(target, key); } });
  page.schedule();
  page.show();
  visible(page);
  page.show();
  page.schedule(empty());
  hidden(page);
  page.window.Date = RealDate;
  page.window.Date.now = () => -1000;
  page.schedule();
  page.show();
  visible(page);
});

test("a desktop local payload takes priority over mobile evidence, including an empty local result", t => {
  const page = pageFor(t);
  page.window.AnkiDifficultyCurrent = localPayload();
  page.schedule();
  page.show();
  hidden(page);
  page.schedule();
  hidden(page);
  page.window.AnkiDifficultyCurrent = localPayload([{ kind: "review", samples: 5, again: 0, hard: 4 }]);
  page.remount();
  assert.equal(root(page).hidden, false);
  assert.match(panel(page).textContent, /최근 복습 5회: 다시 0회, 어려움 4회/);
  assert.match(panel(page).textContent, /기록 기준:/);
  page.schedule();
  assert.match(panel(page).textContent, /최근 복습 5회: 다시 0회, 어려움 4회/);
});

test("a local payload arriving while the mobile root waits retains priority over a later callback", t => {
  const page = pageFor(t);
  page.show();
  hidden(page);
  page.window.AnkiDifficultyCurrent = localPayload();
  page.remount();
  page.schedule();
  hidden(page);
});

test("a foreign callback cannot clear the current card's already-bound evidence when flipping", t => {
  const page = pageFor(t);
  page.schedule(active(1002));
  page.show(1002);
  visible(page);
  page.schedule(active(1001));
  visible(page);
  page.show(1002, { answer: true });
  visible(page);
});

test("malformed direct snapshots cannot turn valid-looking learning counts into evidence", t => {
  const page = pageFor(t);
  const invalid = [
    { valid: false, state: [2, 1001, 0, -1, 3, 3, 0] },
    { valid: true, state: [3, 1001, 0, -1, 3, 3, 0] },
    { valid: true, state: [2, 1002, 0, -1, 3, 3, 0] },
    { valid: true, state: [2, 1001, 0, -1, 1, 1, 1] },
    { valid: true, state: [2, 1001, 5, -1, 3, 3, 0] },
    { valid: true, state: [2, 1001, 0, 5, 3, 3, 0] },
  ];
  for (const [index, snapshot] of invalid.entries()) {
    page.show();
    page.deliver({ sequence: index + 1, card_id: "1001", ...snapshot });
    assert.equal(root(page).hidden, true, JSON.stringify(snapshot));
    assert.equal(root(page).children.length, 0, JSON.stringify(snapshot));
  }
});

test("repeated same-card callbacks retain the question's evidence when flipping to the answer", t => {
  const page = pageFor(t);
  page.schedule();
  page.show();
  button(page).click();
  page.schedule();
  page.show(1001, { answer: true });
  visible(page);
  assert.equal(panel(page).hidden, false);
});

test("an earlier unidentified callback cannot consume the next question's matching callback", t => {
  const page = pageFor(t);
  const unknown = page.schedule(active(), { data: {} });
  assert.equal(unknown.card_id, null);
  assert.equal(unknown.valid, false);
  page.show();
  hidden(page);
  page.schedule(active(1002));
  hidden(page);
  page.schedule();
  visible(page);
  assert.equal(panel(page).hidden, true);
});

test("a legacy badge API is replaced in the same WebView before mobile evidence mounts", t => {
  const page = pageFor(t);
  page.schedule();
  const cleaned = [];
  const legacy = {
    mount: () => assert.fail("the legacy mount must not receive the new template"),
    render: payload => { cleaned.push(payload); },
  };
  page.window.AnkiDifficultyBadgeV1 = legacy;
  page.show();
  assert.notStrictEqual(page.api(), legacy);
  assert.equal(page.api().version, 2);
  assert.equal(typeof page.api().receive, "function");
  assert.deepEqual(cleaned, [null]);
  visible(page);
  button(page).click();
  assert.equal(panel(page).hidden, false);
});

test("repeated version-two template runs reuse one API and one interactive badge", t => {
  const page = pageFor(t);
  page.schedule();
  page.show();
  const api = page.api();
  assert.equal(api.version, 2);
  for (let index = 0; index < 3; index += 1) {
    page.remount();
    assert.strictEqual(page.api(), api);
  }
  assert.equal(page.document.querySelectorAll(".anki-difficulty-badge__button").length, 1);
  button(page).click();
  assert.equal(panel(page).hidden, false);
  button(page).click();
  assert.equal(panel(page).hidden, true);
});

test("upgrading the legacy API preserves local evidence even when legacy cleanup clears it", t => {
  const page = pageFor(t);
  page.schedule();
  const local = localPayload([{ kind: "review", samples: 5, again: 0, hard: 4 }]);
  page.window.AnkiDifficultyCurrent = local;
  let cleaned = 0;
  page.window.AnkiDifficultyBadgeV1 = {
    mount: () => assert.fail("the legacy mount must not receive the new template"),
    render: payload => {
      assert.equal(payload, null);
      cleaned += 1;
      page.window.AnkiDifficultyCurrent = payload;
    },
  };
  page.show();
  assert.equal(cleaned, 1);
  assert.equal(page.api().version, 2);
  assert.strictEqual(page.window.AnkiDifficultyCurrent, local);
  assert.equal(root(page).hidden, false);
  assert.match(panel(page).textContent, /최근 복습 5회: 다시 0회, 어려움 4회/);
  assert.match(panel(page).textContent, /기록 기준:/);
  page.remount();
  assert.equal(cleaned, 1);
  assert.strictEqual(page.window.AnkiDifficultyCurrent, local);
});
