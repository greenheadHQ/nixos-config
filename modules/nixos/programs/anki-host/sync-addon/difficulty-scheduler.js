// anki-difficulty-events-v2 — owned Custom Scheduling program.
// Synchronous candidate calculation only. Anki saves the selected candidate
// with the answer and restores it with native Undo. Never change scheduling.
(() => {
  const key = "dce", names = ["again", "hard", "good", "easy"];
  const maxCount = 0xffffffff;
  const safeNumbers = value => typeof value === "number" ?
    Number.isFinite(value) && (!Number.isInteger(value) || Number.isSafeInteger(value)) :
    value && typeof value === "object" ? Object.values(value).every(safeNumbers) : true;
  const deliver = snapshot => {
    // Template upgrades or DOM errors must never prevent native grading.
    try { window.AnkiDifficultyBadgeV1?.receive?.(snapshot); } catch (_) {}
  };
  const abort = message => {
    window.AnkiDifficultyEvents = {
      sequence: (window.AnkiDifficultyEvents?.sequence || 0) + 1, card_id: null, valid: false
    };
    deliver(window.AnkiDifficultyEvents);
    throw Error(message);
  };
  // The wrapper falls back to {} on malformed JSON. Throw before its pack
  // step rather than replacing an imported card's damaged foreign metadata.
  let originalData;
  try { originalData = JSON.parse(states.current.customData || "{}"); }
  catch (_) { abort("invalid-custom-data"); }
  if (!originalData || typeof originalData !== "object" || Array.isArray(originalData)) {
    abort("invalid-custom-data");
  }
  // The native wrapper serializes all four objects even after a no-op. Abort
  // its transform before packing if an imported card contains a large integer
  // that JavaScript cannot preserve, including cards outside our managed type.
  if (!names.every(name => safeNumbers(customData[name]))) {
    abort("custom-data-integer-not-javascript-safe");
  }
  const encode = s => s.map(n => n === -1 ? "-" : n.toString(36)).join(".");
  const grades = q => {
    const result = [];
    while (q) {
      const grade = q % 5;
      if (!grade) throw Error("invalid-mobile-summary");
      result.unshift(grade);
      q = Math.floor(q / 5);
    }
    return result;
  };
  const decode = text => {
    if (typeof text !== "string" || !/^2\.[0-9a-z]+\.[0-9a-z]+\.(?:-|[0-9a-z]+)\.[0-9a-z]+\.[0-9a-z]+\.[0-9a-z]+$/.test(text)) {
      throw Error("invalid-mobile-summary");
    }
    const s = text.split(".").map(n => n === "-" ? -1 : parseInt(n, 36));
    if (s.some(n => !Number.isSafeInteger(n)) || encode(s) !== text ||
        s[1] <= 0 || s[2] < 0 || s[2] >= 3125 || s[3] < -1 || s[3] >= 125 ||
        s[4] > maxCount || s.slice(4).some(n => n < 0) || s[5] + s[6] > s[4]) {
      throw Error("invalid-mobile-summary");
    }
    grades(s[2]);
    if (s[3] >= 0) grades(s[3]);
    return s;
  };
  const normal = state => state?.normal || state?.filtered?.rescheduling?.originalState || null;
  const kind = state => state?.review ?
    (state.review.elapsedDays < state.review.scheduledDays ? 3 : 1) :
    state?.new ? 0 : state?.learning ? 0 : state?.relearning ? 2 : -1;
  const trigger = values => {
    const again = values.filter(g => g === 1).length, hard = values.filter(g => g === 2).length;
    return again >= 2 || hard >= 3 || (again > 0 && hard > 0 && again + hard >= 3);
  };
  const advance = (original, current, next, grade) => {
    const s = original.slice(), phase = kind(current);
    // New is an actual new episode, including a manual Forget operation.
    if (current.review || current.new) s.splice(4, 3, 0, 0, 0);
    if (phase === 1) {
      s[2] = (s[2] * 5 + grade) % 3125;
      const recent = grades(s[2]);
      if (s[3] >= 0) {
        s[3] = (s[3] * 5 + grade) % 125;
        const recovery = grades(s[3]);
        if (recovery.length === 3 && !recovery.includes(1) && recovery.filter(g => g >= 3).length >= 2) {
          s[2] = 0; s[3] = -1;
        }
      } else if (recent.length >= 3 && trigger(recent)) s[3] = 0;
    } else if (phase === 0 || phase === 2) {
      s[4] += 1;
      s[5] += Number(grade === 1);
      s[6] += Number(grade === 2);
    }
    if (next.review) s.splice(4, 3, 0, 0, 0);
    if (s[4] > maxCount) throw Error("mobile-summary-capacity-exceeded");
    return s;
  };
  let snapshot = null;
  try {
    const original = decode(originalData[key]);
    const current = normal(states.current);
    const sequence = (window.AnkiDifficultyEvents?.sequence || 0) + 1;
    snapshot = { sequence, card_id: String(original[1]), state: original.slice(), valid: false };
    // Preview carries customData too; it must not accumulate real answers.
    if (kind(current) >= 0) {
      const pending = names.map((name, index) => {
        const next = normal(states[name]);
        if (kind(next) < 0 || customData[name]?.[key] !== originalData[key]) throw Error("unsupported-candidate");
        const value = advance(original, current, next, index + 1);
        const data = { ...customData[name], [key]: encode(value) };
        if (!safeNumbers(data) || new TextEncoder().encode(JSON.stringify(data)).length > 100 ||
            Object.keys(data).some(k => new TextEncoder().encode(k).length > 8)) throw Error("custom-data-capacity-exceeded");
        return data;
      });
      // Publish none of the mutations until all four candidates pass.
      names.forEach((name, index) => { customData[name] = pending[index]; });
      snapshot.valid = true;
      if (current.review || current.new) snapshot.state.splice(4, 3, 0, 0, 0);
    }
  } catch (_) {
    // Unknown/unsupported data stays untouched. It is not evidence of recovery.
  }
  window.AnkiDifficultyEvents = snapshot || {
    sequence: (window.AnkiDifficultyEvents?.sequence || 0) + 1, card_id: null, valid: false
  };
  // Only a currently waiting template can consume an after-render delivery.
  // The receiver never updates native scheduling states or writes card data.
  deliver(window.AnkiDifficultyEvents);
})();
