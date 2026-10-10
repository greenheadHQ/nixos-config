// Reproducible Node/jsdom benchmark, not an Anki/iPhone performance test.
// DOM construction, WebView layout/paint, native I/O, and media fetches are excluded.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { arch, cpus, platform } from "node:os";
import { resolve } from "node:path";
import { performance } from "node:perf_hooks";
import { addonPath, bundle, css, manifest, packagePath, renderer } from "./harness.mjs";

const require = createRequire(resolve(packagePath, "package.json"));
const { JSDOM } = require("jsdom");
const jsdomVersion = require("jsdom/package.json").version;
const parser = await readFile(resolve(addonPath, "fenced-code.js"), "utf8");
const baselinePath = process.env.ANKI_FENCED_BASELINE_RENDERER;
let baselineRenderer = null;
if (baselinePath) {
  const source = await readFile(baselinePath, "utf8");
  if (source.includes("AnkiFencedCodeV1") || source.includes("__ANKI_FENCED_CODE__")) {
    throw new Error("ANKI_FENCED_BASELINE_RENDERER must contain the pre-fence renderer");
  }
  baselineRenderer = (source.match(/<script>([\s\S]*)<\/script>/)?.[1] ?? source)
    .replace("__ANKI_SYNTAX_ASSET__", JSON.stringify(manifest.asset.filename))
    .replace("__ANKI_SYNTAX_CSS__", JSON.stringify(css).replaceAll("<", "\\u003c"));
}
const iterations = Number(process.env.ANKI_FENCED_BENCH_ITERATIONS || 100);
if (!Number.isSafeInteger(iterations) || iterations < 10 || iterations > 1000) {
  throw new Error("ANKI_FENCED_BENCH_ITERATIONS must be between 10 and 1000");
}
const warmups = 10;
const grammarOnly = process.argv.includes("--grammar-only");
const parserOnly = process.argv.includes("--parser-only");
if (grammarOnly && parserOnly) throw new Error("Choose one of --grammar-only or --parser-only");
const escape = value => value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
const htmlCode = (text, language = "javascript") =>
  `<pre><code${language ? ` class="language-${language}"` : ""}>${escape(text)}</code></pre>`;
const fence = (text, language = "javascript", shape = "br") => {
  const lines = ["```" + (language || ""), ...text.split("\n"), "```"];
  if (shape === "div" || shape === "p") {
    return lines.map(line => `<${shape}>${escape(line) || "<br>"}</${shape}>`).join("");
  }
  if (shape === "inline") return lines.map(line => `<span>${escape(line)}</span>`).join("<br>");
  return lines.map(escape).join(shape === "newline" ? "\n" : "<br>");
};
const shortJS = "const answer = Buffer.from('ABC', 'utf8');\nconsole.log(answer);";
const heavyJS = ("const value = Buffer.from('ABC');\n".repeat(128)).slice(0, 4096);
const adb = "❯ adb pair 198.51.100.123:12345\nEnter pairing code: 000000\n"
  + "error: protocol fault (couldn't read status message): Undefined error: 0";
const question = "문서 예시용 주소와 가짜 페어링 코드로 만든 합성 질문입니다. "
  + "코드 블록과 이 문장이 함께 있는 카드의 표시 비용을 측정합니다.";
const mixedProse = Array.from({ length: 80 }, (_, index) =>
  `<p><b>설명 ${index}</b> <span>일반 문장</span><br><a href="https://example.invalid/">참고</a></p>`).join("");
const codeCase = (name, description, text, language, shape = "br", category = "typical") => ({
  name, description, category, expectedBlocks: 1,
  fenced: fence(text, language, shape), html: htmlCode(text, language), texts: [text],
});

// Fixed input inventory is defined before timing. No actual collection is queried.
// "typical" is a measurement fixture label, not a claim about the user's cards.
const fixtures = [
  { ...codeCase("adbQuestion", "Synthetic ADB example with BR boundaries and documentation-only address", adb, "bash"),
    fenced: fence(adb, "bash") + "<br><br>" + question,
    html: htmlCode(adb, "bash") + "<br><br>" + question },
  { name: "noFenceSmall", description: "Small ordinary note without a fence", category: "typical",
    expectedBlocks: 0, fenced: "<p>일반 질문입니다.</p>", html: "<p>일반 질문입니다.</p>", texts: [] },
  { name: "noFenceRich", description: "80 paragraphs, inline formatting, BRs, and links without fences",
    category: "stress", expectedBlocks: 0, fenced: mixedProse, html: mixedProse, texts: [] },
  codeCase("shortBR", "One short code block separated by BR", shortJS, "javascript"),
  codeCase("shortNewline", "One short code block separated by literal LF", shortJS, "javascript", "newline"),
  codeCase("shortDIV", "One short code block with editor DIV wrappers", shortJS, "javascript", "div"),
  codeCase("shortP", "One short code block with editor P wrappers", shortJS, "javascript", "p"),
  codeCase("shortInline", "Inline spans around BR-separated fence lines", shortJS, "javascript", "inline"),
  { name: "manyInlineAroundCode", description: "80 rich paragraphs before one short code block",
    category: "stress", expectedBlocks: 1, fenced: mixedProse + fence(shortJS),
    html: mixedProse + htmlCode(shortJS), texts: [shortJS] },
  codeCase("unknownLanguage", "Unknown language stays plain", shortJS, "unknown"),
  codeCase("missingLanguage", "Missing language stays plain", shortJS, null),
  codeCase("heavy4096", "4096 UTF-16 code units; dense JS token output", heavyJS, "javascript", "br", "stress"),
  codeCase("oversized4097", "4097 UTF-16 code units; existing HTML highlighter limit", heavyJS + " ", "javascript", "br", "stress"),
  { name: "many33Blocks", description: "33 short explicitly labelled code blocks", category: "stress",
    expectedBlocks: 33, fenced: Array.from({ length: 33 }, () => fence(shortJS)).join("<br>"),
    html: Array.from({ length: 33 }, () => htmlCode(shortJS)).join("<br>"),
    texts: Array.from({ length: 33 }, () => shortJS) },
];
const grammarSeeds = {
  javascript: "const rows = [{ id: 42, name: '한글', active: true }];\n"
    + "function render(row) { return `${row.id}: ${row.name}`; }\nconsole.log(rows.map(render));\n",
  bash: "#!/bin/bash\nfor item in \"${items[@]}\"; do\n  printf '%s\\n' \"$item\" | sed 's/a/b/g'\ndone\n",
  json: '{"rows":[{"id":42,"name":"한글","active":true,"items":[1,2,3]}],"missing":null}\n',
  xml: '<div class="sample"><span data-id="42">한글 &amp; text</span><a href="/sample">link</a></div>\n',
};
const grammarFixtures = Object.entries(grammarSeeds).flatMap(([language, seed]) =>
  [512, 1024, 2048, 4096].map(length => ({ language, length,
    text: seed.repeat(Math.ceil(length / seed.length)).slice(0, length) })));
const envelope = (content, pending = true) => `<div id="qa"><div data-anki-cid="1001"></div>`
  + `<section class="anki-code-scope anki-fence-scope" data-anki-fence-field="질문"${pending ? ' data-anki-fence-pending=""' : ""}>${content}</section></div>`;
const summarize = values => {
  const sorted = [...values].sort((a, b) => a - b);
  const round = value => Number(value.toFixed(3));
  return { samples: sorted.length, p50Ms: round(sorted[Math.ceil(sorted.length * 0.50) - 1]),
    p95Ms: round(sorted[Math.ceil(sorted.length * 0.95) - 1]), maxMs: round(sorted.at(-1)) };
};
const bounds = values => ({ min: Math.min(...values), max: Math.max(...values) });
const hash = source => createHash("sha256").update(source).digest("hex");
const flush = async () => { for (let i = 0; i < 32; i++) await Promise.resolve(); };

function page({ installParser = true, installBundle = true, rendererScript = renderer, pending = true } = {}) {
  const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
    runScripts: "outside-only", pretendToBeVisual: true, url: "http://127.0.0.1/",
  });
  const { window } = dom;
  // Only teardown bookkeeping: prevent queued jsdom observer deliveries after close.
  const observers = [];
  const NativeObserver = window.MutationObserver;
  window.MutationObserver = class extends NativeObserver {
    constructor(callback) { super(callback); observers.push(this); }
  };
  if (installParser) window.eval(parser);
  if (installBundle) window.eval(bundle);
  return { window, document: window.document,
    set: content => { window.document.body.innerHTML = envelope(content, pending); },
    scope: () => window.document.querySelector(".anki-fence-scope"),
    start: () => window.eval(rendererScript),
    close: () => { for (const observer of observers) observer.disconnect(); window.close(); } };
}

function inventory(html) {
  const sample = page({ installParser: false, installBundle: false });
  try {
    sample.set(html);
    const scope = sample.scope();
    const walker = sample.document.createTreeWalker(scope, sample.window.NodeFilter.SHOW_ALL);
    let descendants = 0, textNodes = 0;
    while (walker.nextNode()) { descendants++; if (walker.currentNode.nodeType === 3) textNodes++; }
    return { sourceUtf16Units: html.length, sourceUtf8Bytes: Buffer.byteLength(html),
      displayedTextUtf16Units: scope.textContent.length, descendantNodes: descendants,
      elements: scope.querySelectorAll("*").length, textNodes };
  } finally { sample.close(); }
}

function verify(sample, fixture) {
  const codes = [...sample.scope().querySelectorAll("pre > code")];
  assert.equal(codes.length, fixture.expectedBlocks, `${fixture.name}: invalid benchmark code count`);
  assert.deepEqual(codes.map(code => code.textContent), fixture.texts,
    `${fixture.name}: benchmark must preserve every code character`);
}

function verifyReady(sample, fixture) {
  assert.equal(sample.scope().hasAttribute("data-anki-fence-pending"), false,
    `${fixture.name}: measured warm template must have released its field gate`);
  for (const button of sample.scope().querySelectorAll(".anki-code-copy button")) {
    assert.equal(button.disabled, false, `${fixture.name}: copy control must be ready after settlement`);
  }
}

async function parserTiming(fixture) {
  const sample = page({ installBundle: false });
  const elapsed = [], unchanged = [];
  try {
    for (let index = 0; index < iterations + warmups; index++) {
      sample.set(fixture.fenced);
      let started = performance.now();
      const result = sample.window.AnkiFencedCodeV1.convert(sample.scope());
      const duration = performance.now() - started;
      assert.equal(result.failed, false, `${fixture.name}: fixture conversion failed`);
      verify(sample, fixture);
      // Repeated template execution must reuse the already converted scope.
      started = performance.now();
      sample.window.AnkiFencedCodeV1.convert(sample.scope());
      const repeated = performance.now() - started;
      if (index >= warmups) { elapsed.push(duration); unchanged.push(repeated); }
    }
    return { freshScope: summarize(elapsed), unchangedScope: summarize(unchanged) };
  } finally { sample.close(); }
}

async function pairedTiming(fixture, mode) {
  const html = page(), fenced = page();
  const samples = { html: [], fenced: [], delta: [], htmlHighlighted: [], fencedHighlighted: [] };
  try {
    // Install globals and warm each grammar outside the measured paired loop.
    for (const sample of [html, fenced]) {
      sample.set(fixture.html);
      sample.start();
      await flush();
    }
    for (let index = 0; index < iterations + warmups; index++) {
      const pair = {};
      // Alternate AB/BA order to reduce systematic warm-up and load-order bias.
      for (const arm of (index % 2 ? ["fenced", "html"] : ["html", "fenced"])) {
        const sample = arm === "html" ? html : fenced;
        sample.set(fixture[arm]);
        const started = performance.now();
        let metrics;
        if (mode === "rendererApi") {
          if (arm === "fenced") sample.window.AnkiFencedCodeV1.convert(sample.scope());
          metrics = await sample.window.AnkiCodeHighlightV1.render();
        } else {
          sample.start();
        }
        await flush();
        pair[arm] = performance.now() - started;
        verify(sample, fixture);
        if (mode === "template") verifyReady(sample, fixture);
        const highlighted = metrics?.highlighted ?? sample.scope().querySelectorAll("code.hljs").length;
        if (index >= warmups) {
          samples[arm].push(pair[arm]);
          samples[`${arm}Highlighted`].push(highlighted);
        }
      }
      if (index >= warmups) samples.delta.push(pair.fenced - pair.html);
    }
    return { html: summarize(samples.html), fenced: summarize(samples.fenced),
      pairedDeltaFencedMinusHtml: summarize(samples.delta),
      highlightedCounts: { html: bounds(samples.htmlHighlighted), fenced: bounds(samples.fencedHighlighted) } };
  } finally { html.close(); fenced.close(); }
}

async function legacyTemplateTiming(fixture) {
  const samples = { before: [], after: [], delta: [] };
  const before = page({ rendererScript: baselineRenderer, pending: false }), after = page();
  try {
    for (const sample of [before, after]) {
      sample.set(fixture.html);
      sample.start();
      await flush();
    }
    for (let index = 0; index < iterations + warmups; index++) {
      const pair = {};
      for (const arm of (index % 2 ? ["after", "before"] : ["before", "after"])) {
        const sample = arm === "before" ? before : after;
        sample.set(fixture.html);
        const started = performance.now();
        sample.start();
        await flush();
        pair[arm] = performance.now() - started;
        verify(sample, fixture);
        verifyReady(sample, fixture);
        if (index >= warmups) samples[arm].push(pair[arm]);
      }
      if (index >= warmups) samples.delta.push(pair.after - pair.before);
    }
    return { before: summarize(samples.before), after: summarize(samples.after),
      pairedDeltaAfterMinusBefore: summarize(samples.delta) };
  } finally { before.close(); after.close(); }
}

function grammarTiming(fixture) {
  const sample = page({ installParser: false });
  const engineMs = [], tokenDomMs = [], combinedMs = [];
  const engine = sample.window.AnkiSyntaxHighlightLibraryV1;
  let tokenSpans = 0, highlightedHtmlUtf16Units = 0;
  try {
    sample.set("");
    // Compile this grammar before warm timing. Cold grammar compilation is separate.
    engine.highlight(fixture.text, { language: fixture.language, ignoreIllegals: true });
    for (let index = 0; index < iterations + warmups; index++) {
      const code = sample.document.createElement("code");
      sample.scope().replaceChildren(code);
      const started = performance.now();
      const result = engine.highlight(fixture.text, { language: fixture.language, ignoreIllegals: true });
      const afterEngine = performance.now();
      code.innerHTML = result.value;
      const finished = performance.now();
      assert.equal(code.textContent, fixture.text, "grammar benchmark text must remain exact");
      if (index >= warmups) {
        engineMs.push(afterEngine - started);
        tokenDomMs.push(finished - afterEngine);
        combinedMs.push(finished - started);
      }
      tokenSpans = code.querySelectorAll("span").length;
      highlightedHtmlUtf16Units = result.value.length;
    }
    return { inputUtf16Units: fixture.text.length, inputUtf8Bytes: Buffer.byteLength(fixture.text),
      tokenSpans, highlightedHtmlUtf16Units,
      engineHighlightOnly: summarize(engineMs), tokenDomInsertionOnly: summarize(tokenDomMs),
      combinedEngineAndTokenDom: summarize(combinedMs) };
  } finally { sample.close(); }
}

const report = {
  environment: "Node/jsdom synthetic; not Mac Anki/iPhone device or first-paint proof",
  mode: grammarOnly ? "grammar-only" : parserOnly ? "parser-only" : "full",
  node: process.version, jsdom: jsdomVersion, platform: platform(), arch: arch(), cpu: cpus()[0]?.model,
  iterations, warmups, coldSamples: Math.min(iterations, 30),
  bundle: manifest.asset,
  sourceHashes: { parserSha256: hash(parser), rendererSha256: hash(renderer) },
  definitions: {
    parser: "Synchronous convert(scope) on fresh DOM, parser global already installed",
    rendererApi: "Fence arm includes convert(scope), both arms await render() and observer microtasks; UI mount excluded",
    template: "Current renderer script invocation with initial field pending marker, copy disable/re-enable, and observer/Promise settlement, engine already available; not first paint or a complete managed-card template",
    cold: "Fresh jsdom window; parser and bundle eval timed independently before first template invocation; no file/network loading",
    pairedDelta: "Per-pair fenced minus equivalent HTML elapsed time; negative values and variation are retained",
    exclusions: "DOM construction/HTML parsing, layout/paint, native I/O, media fetch, MathJax, font/image readiness, 50ms network wait",
    policy: "Heavy fenced blocks may intentionally remain plain while existing HTML blocks retain existing colour limits; consult highlightedCounts",
    target: "Typical short-note parser p95 <= 1ms is provisional; reported numbers are not a device acceptance gate",
    grammar: "Fixed repeated/truncated JS/bash/JSON/XML samples at 512/1024/2048/4096 UTF-16 units; syntax may end mid-token. Warm engine and token DOM insertion measured separately; no WebView layout/paint",
    legacyBaseline: "Optional pre-fence renderer uses the same pinned bundle, current static CSS, field contents, and AB/BA ordering. Only the current arm has its initial field pending marker. Set ANKI_FENCED_BASELINE_RENDERER; absent means pre/post regression is unmeasured",
  },
  fixtureInventory: fixtures.map(fixture => ({ name: fixture.name, description: fixture.description,
    category: fixture.category, expectedBlocks: fixture.expectedBlocks,
    codeUtf16Units: fixture.texts.reduce((sum, text) => sum + text.length, 0),
    largestCodeUtf16Units: Math.max(0, ...fixture.texts.map(text => text.length)),
    fenced: inventory(fixture.fenced), html: inventory(fixture.html) })),
  grammarInventory: grammarFixtures.map(fixture => ({ language: fixture.language,
    inputUtf16Units: fixture.text.length, inputUtf8Bytes: Buffer.byteLength(fixture.text),
    inputSha256: hash(fixture.text) })),
  cold: {}, grammar: { coldFirstHighlight512: {}, warm: {} }, cases: {},
  legacyHtmlTemplate: baselineRenderer ? { status: "measured", rendererSha256: hash(baselineRenderer),
    css: "Current static CSS used for both arms", cases: {} } : { status: "unmeasured",
    reason: "ANKI_FENCED_BASELINE_RENDERER not set; equivalent HTML/fence pairing is not pre/post evidence" },
};

if (parserOnly) {
  for (const fixture of fixtures) report.cases[fixture.name] = { parser: await parserTiming(fixture) };
  process.stdout.write(JSON.stringify(report, null, 2) + "\n");
  process.exit(0);
}

for (const [language, seed] of Object.entries(grammarSeeds)) {
  const elapsed = [];
  const text = seed.repeat(Math.ceil(512 / seed.length)).slice(0, 512);
  for (let index = 0; index < report.coldSamples; index++) {
    const sample = page({ installParser: false });
    try {
      const started = performance.now();
      sample.window.AnkiSyntaxHighlightLibraryV1.highlight(text, { language, ignoreIllegals: true });
      elapsed.push(performance.now() - started);
    } finally { sample.close(); }
  }
  report.grammar.coldFirstHighlight512[language] = summarize(elapsed);
}
for (const fixture of grammarFixtures) {
  report.grammar.warm[`${fixture.language}${fixture.length}`] = grammarTiming(fixture);
}
if (grammarOnly) {
  process.stdout.write(JSON.stringify(report, null, 2) + "\n");
  process.exit(0);
}

const parserEval = [], bundleEval = [], firstTemplate = [];
for (let index = 0; index < report.coldSamples; index++) {
  const sample = page({ installParser: false, installBundle: false });
  try {
    sample.set(fixtures[0].fenced);
    let started = performance.now();
    sample.window.eval(parser);
    parserEval.push(performance.now() - started);
    started = performance.now();
    sample.window.eval(bundle);
    bundleEval.push(performance.now() - started);
    started = performance.now();
    sample.start();
    await flush();
    firstTemplate.push(performance.now() - started);
    verify(sample, fixtures[0]);
    verifyReady(sample, fixtures[0]);
  } finally { sample.close(); }
}
report.cold = { parserEval: summarize(parserEval), highlightBundleEval: summarize(bundleEval),
  firstTemplateWithInstalledParserAndEngine: summarize(firstTemplate) };
for (const fixture of fixtures) {
  report.cases[fixture.name] = { parser: await parserTiming(fixture),
    rendererApi: await pairedTiming(fixture, "rendererApi"),
    template: await pairedTiming(fixture, "template") };
  if (baselineRenderer) report.legacyHtmlTemplate.cases[fixture.name] = await legacyTemplateTiming(fixture);
}
process.stdout.write(JSON.stringify(report, null, 2) + "\n");
