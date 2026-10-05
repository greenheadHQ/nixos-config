// Optional macOS browser check. This compares real editing/undo with a plain
// textarea; native Korean IME and Qt shortcut routing still need Anki testing.
import assert from "node:assert/strict";
import { mkdir, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { resolve } from "node:path";
import { scratchpadFragment, scratchpadScript } from "./harness.mjs";

assert.equal(process.platform, "darwin", "run on macOS for native Command key semantics");
assert.ok(process.env.PLAYWRIGHT_MODULE_PATH, "provide PLAYWRIGHT_MODULE_PATH");
assert.ok(process.env.CHROMIUM_PATH, "provide CHROMIUM_PATH");
const { chromium } = createRequire(import.meta.url)(process.env.PLAYWRIGHT_MODULE_PATH);
const output = resolve(process.argv[2] || "/tmp/anki-scratchpad-editing");
await mkdir(output, { recursive:true });
const browser = await chromium.launch({ executablePath:process.env.CHROMIUM_PATH, headless:true });
const reports = [];
const cases = [
  { name:"line end", value:"alpha beta", start:10 },
  { name:"line middle", value:"alpha beta gamma", start:8 },
  { name:"hard line", value:"first line\nsecond line", start:22 },
  { name:"line start", value:"first line\nsecond line", start:11 },
  { name:"document start", value:"first line", start:0 },
  { name:"empty", value:"", start:0 },
  { name:"soft wrap", value:"alpha beta gamma delta epsilon zeta eta theta iota kappa lambda", start:46 },
  { name:"soft line start", value:"alpha beta gamma delta epsilon zeta eta theta iota kappa lambda", start:36 },
  { name:"selected range", value:"first line\nsecond line", start:3, end:17 },
  { name:"backward range", value:"first line\nsecond line", start:3, end:17, direction:"backward" },
  { name:"emoji", value:"hello 😀 world 🧑‍💻 text", start:18 },
  { name:"RTL wrap", value:"مرحبا بالعالم هذا اختبار طويل للنص العربي", start:26, dir:"rtl" },
  { name:"trailing newline", value:"first line\n", start:11 },
];
try {
  const errors = [];
  const snapshot = (page, selector) => page.locator(selector).evaluate(input => ({
    value:input.value, start:input.selectionStart, end:input.selectionEnd,
    direction:input.selectionDirection,
  }));
  for (const fixture of cases) {
    const results = {};
    for (const selector of ["#reference", ".anki-scratchpad textarea"]) {
      // A fresh page also clears the global controller; setContent alone keeps
      // it but removes its listeners, silently testing only native behavior.
      const page = await browser.newPage({ viewport:{ width:860, height:650 } });
      page.on("pageerror", error => errors.push(String(error)));
      await page.setContent(`<html><body><main id="qa"><article data-anki-scratchpad-card><span data-anki-cid="123456789"></span></article></main><textarea id="reference"></textarea>${scratchpadFragment.match(/<style>[\s\S]*<\/style>/)[0]}</body></html>`);
      await page.evaluate(scratchpadScript);
      await page.evaluate(() => document.addEventListener("keydown", event => {
        if (event.key === "Backspace" && event.metaKey) window.editingDefaultPrevented = event.defaultPrevented;
      }, true));
      await page.locator("textarea").evaluateAll(inputs => {
        for (const input of inputs) input.style.cssText = "font:20px monospace;line-height:24px;box-sizing:border-box;width:240px;height:160px;white-space:pre-wrap;padding:4px;border:1px solid black";
      });
      await page.locator(selector).fill(fixture.value);
      await page.locator(selector).evaluate((input, fixture) => {
        input.dir = fixture.dir || "ltr";
        input.setSelectionRange(fixture.start, fixture.end ?? fixture.start, fixture.direction || "none");
      }, fixture);
      await page.locator(selector).press("Meta+Backspace");
      assert.equal(await page.evaluate(() => window.editingDefaultPrevented), selector !== "#reference", "correction actually ran only in the scratchpad");
      const after = await snapshot(page, selector);
      await page.locator(selector).press("Meta+z");
      const undo = await snapshot(page, selector);
      await page.locator(selector).press("Meta+Shift+z");
      const redo = await snapshot(page, selector);
      results[selector] = { after, undo, redo };
      if (selector !== "#reference") {
        await page.locator('[data-action="collapse"]').click();
        await page.locator(".anki-scratchpad__launch").click();
        assert.equal(await page.locator(selector).inputValue(), redo.value, "edited draft survives reopen");
      }
      await page.close();
    }
    reports.push({ name:fixture.name, ...results });
    assert.deepEqual(results[".anki-scratchpad textarea"], results["#reference"], fixture.name);
  }
  assert.deepEqual(errors, []);
  await writeFile(resolve(output, "editing.json"), JSON.stringify(reports, null, 2) + "\n");
  console.log(`${reports.length} native editing/undo comparisons passed`);
} finally {
  await browser.close();
}
