import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { createContext, Script } from "node:vm";

const root = fileURLToPath(new URL("../../", import.meta.url));
const addonPath = process.env.ANKI_SYNTAX_ADDON || resolve(root, "modules/nixos/programs/anki-host/sync-addon");
const filename = resolve(addonPath, "difficulty-scheduler.js");
const program = new Script(await readFile(filename, "utf8"), { filename });
const names = ["again", "hard", "good", "easy"];
const cid = 1790000000123;
const clone = value => JSON.parse(JSON.stringify(value));
const empty = () => [2, cid, 0, -1, 0, 0, 0];
const encode = state => state.map(value => value === -1 ? "-" : value.toString(36)).join(".");
const decode = value => value.split(".").map(part => part === "-" ? -1 : parseInt(part, 36));
const packed = values => values.reduce((value, grade) => value * 5 + grade, 0);
const summary = (run, name) => decode(run.customData[name].dce);
const byteLength = value => new TextEncoder().encode(JSON.stringify(value)).length;

function native(kind) {
  const review = { scheduledDays: 17, elapsedDays: 19, easeFactor: 2.4, lapses: 2,
    leeched: false, memoryState: { difficulty: 6.2, stability: 15.4 } };
  const learning = { remainingSteps: 1, scheduledSecs: 86400, elapsedSecs: 120,
    memoryState: { difficulty: 5.3, stability: 0.8 } };
  if (kind === "review") return { normal: { review } };
  if (kind === "learning") return { normal: { learning } };
  if (kind === "relearning") return { normal: { relearning: { review, learning } } };
  if (kind === "new") return { normal: { new: { position: 73 } } };
  if (kind === "preview") return { filtered: { preview: { scheduledSecs: 60, finished: false } } };
  throw Error(`unknown fixture kind: ${kind}`);
}

const filtered = state => ({ filtered: { rescheduling: { originalState: clone(state.normal) } } });

function fixture({ state = empty(), current = native("review"), candidates,
  data = { dce: encode(state) }, rawCurrent, candidateData } = {}) {
  const states = {
    current: { ...clone(current), customData: rawCurrent ?? JSON.stringify(data) },
    ...Object.fromEntries(names.map(name => [name, clone(candidates?.[name] || native("review"))])),
  };
  const customData = Object.fromEntries(names.map(name => [name, clone(candidateData?.[name] || data)]));
  const statesBefore = clone(states);
  const originalObjects = { ...customData };
  const originalsBefore = clone(customData);
  const deliveries = [];
  const unavailable = name => () => { throw Error(`scheduler must not call ${name}`); };
  const window = {
    AnkiDifficultyBadgeV1: {
      receive(snapshot) {
        deliveries.push({ snapshot: clone(snapshot), candidates: clone(customData) });
      },
    },
  };
  const context = createContext({ states, customData, window, TextEncoder,
    setTimeout: unavailable("setTimeout"), setInterval: unavailable("setInterval"),
    queueMicrotask: unavailable("queueMicrotask"), fetch: unavailable("fetch"),
    anki: { getSchedulingStatesWithContext: unavailable("getSchedulingStatesWithContext"),
      setSchedulingStates: unavailable("setSchedulingStates") },
  });
  return {
    states, statesBefore, customData, originalObjects, originalsBefore, window, deliveries,
    run() { program.runInContext(context); return this; },
    resetCandidates() {
      for (const name of names) customData[name] = clone(originalsBefore[name]);
    },
  };
}

function unchanged(run) {
  assert.deepEqual(run.states, run.statesBefore, "native scheduling and current customData must stay intact");
  for (const name of names) {
    assert.deepEqual(run.originalObjects[name], run.originalsBefore[name], `${name} source object must stay intact`);
  }
}

function rejected(run) {
  assert.doesNotThrow(() => run.run());
  assert.equal(run.window.AnkiDifficultyEvents.valid, false);
  assert.equal(run.deliveries.length, 1, "an unavailable delivery must clear any previous UI evidence");
  for (const name of names) assert.strictEqual(run.customData[name], run.originalObjects[name]);
  assert.deepEqual(run.customData, run.originalsBefore);
  unchanged(run);
}

function answer(state, grade, options = {}) {
  const run = fixture({ state, ...options }).run();
  assert.equal(run.window.AnkiDifficultyEvents.valid, true);
  unchanged(run);
  return summary(run, names[grade - 1]);
}

const reviewSequence = (values, state = empty()) => values.reduce((value, grade) => answer(value, grade), state);

test("all four candidates are independent and only customData is changed", () => {
  const data = { dce: encode(empty()), dcb: [1, 1790000000000, "abcdef012345"], other: { x: 7 } };
  const run = fixture({ data, candidates: { again: native("relearning") } }).run();
  assert.equal(run.window.AnkiDifficultyEvents.valid, true);
  names.forEach((name, index) => {
    assert.deepEqual(summary(run, name), [2, cid, index + 1, -1, 0, 0, 0]);
    assert.deepEqual(run.customData[name].dcb, data.dcb);
    assert.deepEqual(run.customData[name].other, data.other);
    assert.notStrictEqual(run.customData[name], run.originalObjects[name]);
  });
  unchanged(run);
  const saved = clone(run.customData);
  run.customData.again.dce = "changed selected fixture";
  for (const name of names.slice(1)) assert.deepEqual(clone(run.customData[name]), saved[name]);
});

test("review trigger uses at least three answers and the last five Review answers", () => {
  for (const [values, active] of [
    [[1, 1], false], [[1, 1, 3], true], [[2, 2, 2], true],
    [[1, 2, 3], false], [[1, 2, 2], true], [[1, 3, 3, 3, 1], true],
    [[1, 3, 3, 3, 3, 1], false], [[3, 4, 3, 4, 3, 4], false],
  ]) {
    const result = reviewSequence(values);
    assert.equal(result[3] >= 0, active, JSON.stringify(values));
    assert.equal(result[2], packed(values.slice(-5)), JSON.stringify(values));
  }
});

test("recovery starts after the triggering answer and clears to a fresh Review window", () => {
  const active = reviewSequence([1, 1, 3]);
  assert.equal(active[3], 0);
  const two = reviewSequence([3, 4], active);
  assert.equal(two[3], packed([3, 4]), "the triggering Good must not be a recovery answer");
  const cleared = answer(two, 2);
  assert.deepEqual(cleared, empty());
  assert.equal(answer(cleared, 1)[3], -1, "old Again answers must not retrigger the reset window");
});

test("recovery is a rolling three-answer window, including Again and Hard setbacks", () => {
  const active = reviewSequence([2, 2, 2]);
  let result = reviewSequence([3, 2, 2, 3], active);
  assert.equal(result[3], packed([2, 2, 3]));
  result = answer(result, 4);
  assert.deepEqual(result, empty());
  result = reviewSequence([3, 1, 3, 3], active);
  assert.equal(result[3], packed([1, 3, 3]));
  assert.deepEqual(answer(result, 2), empty());
});

test("Review Again counts once as Review and Relearning answers cannot recover it", () => {
  const active = reviewSequence([1, 2, 2]);
  const afterAgain = answer(active, 1, { candidates: { again: native("relearning") } });
  assert.equal(afterAgain[2], packed([1, 2, 2, 1]));
  assert.equal(afterAgain[3], 1);
  assert.deepEqual(afterAgain.slice(4), [0, 0, 0]);
  const candidates = Object.fromEntries(names.map(name => [name, native("relearning")]));
  let result = afterAgain;
  for (const grade of [1, 2, 3, 3]) result = answer(result, grade, { current: native("relearning"), candidates });
  assert.equal(result[2], afterAgain[2]);
  assert.equal(result[3], afterAgain[3]);
  assert.deepEqual(result.slice(4), [4, 1, 1]);
  const graduated = answer(result, 3, { current: native("relearning"), candidates: { good: native("review") } });
  assert.equal(graduated[3], afterAgain[3], "graduation clears only the learning signal");
  assert.deepEqual(graduated.slice(4), [0, 0, 0]);
});

test("all learning grades accumulate within one episode, and New starts a fresh episode", () => {
  const state = [2, cid, packed([1, 1, 3]), 0, 8, 3, 4];
  const candidates = Object.fromEntries(names.map(name => [name, native("learning")]));
  const learning = fixture({ state, current: native("learning"), candidates }).run();
  names.forEach((name, index) => {
    assert.deepEqual(summary(learning, name).slice(4), [9, 3 + Number(index === 0), 4 + Number(index === 1)]);
    assert.deepEqual(summary(learning, name).slice(0, 4), state.slice(0, 4));
  });
  const fresh = fixture({ state, current: native("new"), candidates }).run();
  names.forEach((name, index) => assert.deepEqual(summary(fresh, name).slice(4),
    [1, Number(index === 0), Number(index === 1)]));
  assert.deepEqual(clone(fresh.window.AnkiDifficultyEvents.state).slice(4), [0, 0, 0]);
  unchanged(learning);
  unchanged(fresh);
});

test("graduation follows each native candidate type, including Again and Hard", () => {
  const state = [2, cid, 0, -1, 4, 3, 1];
  for (const phase of ["new", "learning", "relearning"]) {
    const run = fixture({ state, current: native(phase), candidates: {
      again: native("review"), hard: native("review"), good: native("learning"), easy: native("review"),
    } }).run();
    for (const name of ["again", "hard", "easy"]) assert.deepEqual(summary(run, name).slice(4), [0, 0, 0]);
    assert.deepEqual(summary(run, "good").slice(4), phase === "new" ? [1, 0, 0] : [5, 3, 1]);
    unchanged(run);
  }
});

test("rescheduling filtered decks unwrap current and candidate states independently", () => {
  const state = [2, cid, packed([1, 1]), -1, 0, 0, 0];
  const run = fixture({ state, current: filtered(native("review")), candidates: {
    again: filtered(native("relearning")), hard: native("review"),
    good: native("review"), easy: native("review"),
  } }).run();
  assert.equal(summary(run, "good")[3], 0);
  assert.deepEqual(summary(run, "again").slice(4), [0, 0, 0]);
  const learning = fixture({ state: [2, cid, 0, -1, 3, 3, 0], current: filtered(native("learning")), candidates: {
    again: filtered(native("learning")), hard: filtered(native("learning")),
    good: native("review"), easy: native("review"),
  } }).run();
  assert.deepEqual(summary(learning, "again").slice(4), [4, 4, 0]);
  assert.deepEqual(summary(learning, "good").slice(4), [0, 0, 0]);
  unchanged(run);
  unchanged(learning);
});

test("filtered preview never adds answers or changes any candidate customData", () => {
  const candidates = Object.fromEntries(names.map(name => [name, native("preview")]));
  rejected(fixture({ state: reviewSequence([1, 1, 3]), current: native("preview"), candidates }));
});

test("early Review answers match native filtered revlog and cannot advance or recover Review", () => {
  const state = [2, cid, packed([1, 1, 3, 3, 4]), packed([3, 4]), 0, 0, 0];
  const early = native("review");
  early.normal.review.elapsedDays = 16;
  for (const current of [early, filtered(early)]) {
    const run = fixture({ state, current }).run();
    assert.equal(run.window.AnkiDifficultyEvents.valid, true);
    for (const name of names) assert.deepEqual(summary(run, name), state);
    unchanged(run);
  }
  const due = native("review");
  due.normal.review.elapsedDays = due.normal.review.scheduledDays;
  assert.deepEqual(answer(state, 3, { current: due }), empty());
  assert.deepEqual(answer(state, 3, { current: filtered(due) }), empty());
});

test("an early-looking next Review candidate is still a valid native graduation", () => {
  const next = native("review");
  next.normal.review.elapsedDays = 0;
  const candidates = Object.fromEntries(names.map(name => [name, next]));
  const state = [2, cid, 0, -1, 4, 3, 1];
  const run = fixture({ state, current: native("learning"), candidates }).run();
  assert.equal(run.window.AnkiDifficultyEvents.valid, true);
  for (const name of names) assert.deepEqual(summary(run, name).slice(4), [0, 0, 0]);
  unchanged(run);
});

test("the original snapshot is published synchronously after all candidates are ready", () => {
  const state = [2, cid, packed([1, 1]), -1, 0, 0, 0];
  const run = fixture({ state }).run();
  assert.equal(run.deliveries.length, 1, "delivery must finish before the script returns");
  const delivered = run.deliveries[0];
  assert.deepEqual(delivered.snapshot, { sequence: 1, card_id: String(cid), state, valid: true });
  assert.deepEqual(delivered.candidates, clone(run.customData));
  assert.equal(decode(delivered.candidates.good.dce)[3], 0, "a candidate can trigger without publishing a hypothetical answer");
  assert.equal(delivered.snapshot.state[3], -1);
  run.customData.again.dce = encode(empty());
  assert.deepEqual(clone(run.window.AnkiDifficultyEvents.state), state, "delivery must not alias candidate state");
});

test("repeating the callback from the same native current state never counts twice", () => {
  const run = fixture({ state: [2, cid, packed([1, 2]), -1, 0, 0, 0] }).run();
  const once = clone(run.customData);
  run.resetCandidates();
  run.run();
  assert.deepEqual(clone(run.customData), once);
  assert.equal(run.window.AnkiDifficultyEvents.sequence, 2);
  assert.equal(run.window.AnkiDifficultyEvents.valid, true);
  assert.deepEqual(run.states, run.statesBefore);
  run.run();
  assert.deepEqual(clone(run.customData), once, "even a reused mutated candidate object must not accumulate");
  assert.equal(run.window.AnkiDifficultyEvents.valid, false);
});

test("unseeded, malformed, foreign-version, and invalid-ID summaries fail without mutations", () => {
  const invalid = [
    undefined, null, [], 2, "", "3.1.0.-.0.0.0", "2.0.0.-.0.0.0",
    "2.01.0.-.0.0.0", "2.A.0.-.0.0.0", encode([2, Number.MAX_SAFE_INTEGER + 1, 0, -1, 0, 0, 0]),
    encode([2, cid, 3125, -1, 0, 0, 0]), encode([2, cid, 5, -1, 0, 0, 0]),
    encode([2, cid, 0, 125, 0, 0, 0]), encode([2, cid, 0, 5, 0, 0, 0]),
    encode([2, cid, 0, -2, 0, 0, 0]), encode([2, cid, 0, -1, 1, 1, 1]),
    encode([2, cid, 0, -1, 0x100000000, 0, 0]),
  ];
  for (const dce of invalid) rejected(fixture({ data: dce === undefined ? { other: 1 } : { dce, other: 1 } }));
  const maximum = fixture({ state: [2, Number.MAX_SAFE_INTEGER, 0, -1, 0, 0, 0] }).run();
  assert.equal(maximum.window.AnkiDifficultyEvents.card_id, String(Number.MAX_SAFE_INTEGER));
  assert.equal(maximum.window.AnkiDifficultyEvents.valid, true);
});

test("unsupported final candidates or mismatched markers reject all four candidates atomically", () => {
  rejected(fixture({ candidates: { easy: {} } }));
  rejected(fixture({ current: {} }));
  rejected(fixture({ candidateData: { easy: { dce: encode([2, cid + 1, 0, -1, 0, 0, 0]), other: 1 } } }));
  rejected(fixture({ candidateData: { easy: { other: 1 } } }));
});

test("foreign keys survive and the complete UTF-8 JSON byte budget includes every candidate", () => {
  const data = { dce: encode(empty()), x: "" };
  data.x = "v".repeat(100 - byteLength(data));
  assert.equal(byteLength(data), 100);
  const accepted = fixture({ data }).run();
  assert.equal(accepted.window.AnkiDifficultyEvents.valid, true);
  for (const name of names) {
    assert.equal(byteLength(accepted.customData[name]), 100);
    assert.equal(accepted.customData[name].x, data.x);
  }
  rejected(fixture({ data, candidateData: { easy: { ...data, x: `${data.x}v` } } }));
  const unicode = { dce: encode(empty()), x: "가".repeat(30) };
  assert.ok(JSON.stringify(unicode).length <= 100);
  assert.ok(byteLength(unicode) > 100);
  rejected(fixture({ data: unicode }));
});

test("UTF-8 key limits allow eight bytes and reject oversized keys without loss", () => {
  const allowed = fixture({ data: { dce: encode(empty()), "12345678": 1, "한글": 2 } }).run();
  assert.equal(allowed.window.AnkiDifficultyEvents.valid, true);
  for (const name of names) {
    assert.equal(allowed.customData[name]["12345678"], 1);
    assert.equal(allowed.customData[name]["한글"], 2);
  }
  for (const key of ["123456789", "한글키"]) rejected(fixture({ data: { dce: encode(empty()), [key]: 1 } }));
});

test("learning counter overflow rejects the entire calculation and preserves current evidence", () => {
  const state = [2, cid, packed([1, 1, 3]), 0, 0xffffffff, 3, 4];
  const candidates = Object.fromEntries(names.map(name => [name, native("learning")]));
  const run = fixture({ state, current: native("learning"), candidates });
  rejected(run);
  assert.deepEqual(clone(run.window.AnkiDifficultyEvents.state), state);
});

test("unsafe foreign integer metadata is never rounded and written back", () => {
  for (const value of [Number.MAX_SAFE_INTEGER + 1, -(Number.MAX_SAFE_INTEGER + 1)]) {
    for (const data of [{ dce: encode(empty()), x: [value] }, { x: [value] }]) {
      const run = fixture({ data });
      assert.throws(() => run.run(), /custom-data-integer-not-javascript-safe/);
      assert.deepEqual(clone(run.customData), run.originalsBefore);
      assert.equal(run.window.AnkiDifficultyEvents.valid, false);
    }
  }
});

test("an early Review begins a new learning episode without counting a Review answer", () => {
  const current = native("review");
  current.normal.review.elapsedDays = 0;
  const state = [2, cid, packed([1, 2, 2]), 0, 4, 3, 0];
  const run = fixture({ state, current, candidates: { again: native("relearning") } }).run();
  assert.deepEqual(summary(run, "again"), [2, cid, state[2], 0, 0, 0, 0]);
});


test("invalid raw metadata aborts the native wrapper before it can save its empty fallback", () => {
  for (const rawCurrent of ["{", "null", "[]", '"text"', "3", "false"]) {
    const run = fixture({ rawCurrent, data: {} });
    let packed = false;
    assert.throws(() => {
      run.run();
      packed = true;
      for (const name of names) run.states[name].customData = JSON.stringify(run.customData[name]);
    }, /invalid-custom-data/);
    assert.equal(packed, false);
    assert.equal(run.window.AnkiDifficultyEvents.valid, false);
    assert.equal(run.deliveries.length, 1);
    unchanged(run);
  }
});

test("a missing or broken template receiver cannot block native grading", () => {
  for (const receiver of [{ mount() {} }, { receive() { throw Error("old DOM"); } }]) {
    const run = fixture();
    run.window.AnkiDifficultyBadgeV1 = receiver;
    assert.doesNotThrow(() => run.run());
    assert.equal(run.window.AnkiDifficultyEvents.valid, true);
    names.forEach((name, index) => assert.equal(summary(run, name)[2], index + 1));
    unchanged(run);
    const invalid = fixture({ rawCurrent: "{" });
    invalid.window.AnkiDifficultyBadgeV1 = receiver;
    assert.throws(() => invalid.run(), /invalid-custom-data/);
  }
});
