// Synthetic Node/jsdom timing only. This is not Mac Anki/iPhone device proof.
import { performance } from "node:perf_hooks";
import { block, examples, harness, manifest, scope } from "./harness.mjs";

const iterations = Number(process.env.ANKI_SYNTAX_BENCH_ITERATIONS || 100);
if (!Number.isSafeInteger(iterations) || iterations < 10 || iterations > 1000) throw new Error("iterations must be between 10 and 1000");
const summarize = values => {
  const sorted = [...values].sort((a, b) => a - b);
  const round = value => Number(value.toFixed(3));
  return { samples: sorted.length, p50Ms: round(sorted[Math.ceil(sorted.length * 0.50) - 1]),
    p95Ms: round(sorted[Math.ceil(sorted.length * 0.95) - 1]), maxMs: round(sorted.at(-1)) };
};
const shortText = "const dataBuffer = Buffer.from('ABC', 'utf8');\nconsole.log(dataBuffer.toString('utf8'));";
const normalText = (shortText + "\n// 한글 설명: 버퍼에서 문자열을 다시 읽는다.\n").padEnd(237, " ");
const longText = ("const value = Buffer.from('ABC');\n".repeat(128)).slice(0, 4096);
const cases = {
  currentShortOneBlock: scope(block(shortText)),
  currentLongerThreeBlocks: scope(block(normalText) + block(examples.bash, "bash") + block('전체: "ABC\\nDEF\\n"', "plaintext")),
  synthetic4096OneBlock: scope(block(longText)),
  synthetic4097PlainFallback: scope(block(longText + " ")),
  synthetic33SmallBlocks: scope(Array.from({ length: 33 }, () => block(shortText)).join("")),
};
const report = { environment: "Node/jsdom synthetic; excludes WebView layout/paint and device I/O",
  node: process.version, bundle: manifest.asset, cases: {} };

const coldEval = [];
const coldFirstRender = [];
for (let i = 0; i < Math.min(iterations, 30); i++) {
  const page = harness(cases.currentShortOneBlock, { preload: false, freezeClock: false });
  try {
    let started = performance.now();
    page.installBundle();
    coldEval.push(performance.now() - started);
    started = performance.now();
    page.start();
    await page.flush();
    coldFirstRender.push(performance.now() - started);
  } finally { page.close(); }
}
report.coldBundleEval = summarize(coldEval);
report.coldFirstTemplateRender = summarize(coldFirstRender);

for (const [name, html] of Object.entries(cases)) {
  const page = harness(html, { freezeClock: false });
  const elapsed = [];
  const highlight = [];
  const renderedCounts = [];
  try {
    page.start();
    await page.flush();
    // Same globals/grammar cache, but fresh code nodes as in question/answer or
    // next-card replacement. DOM setup is outside the timed renderer call.
    for (let i = 0; i < iterations + 10; i++) {
      page.document.body.innerHTML = html;
      const started = performance.now();
      const metrics = await page.api().render();
      const duration = performance.now() - started;
      if (i >= 10) {
        elapsed.push(duration);
        highlight.push(metrics.highlightMs);
        renderedCounts.push(metrics.highlighted);
      }
    }
    report.cases[name] = { renderer: summarize(elapsed), highlight: summarize(highlight),
      highlightedBlocksMin: Math.min(...renderedCounts), highlightedBlocksMax: Math.max(...renderedCounts) };
  } finally { page.close(); }
}
process.stdout.write(JSON.stringify(report, null, 2) + "\n");
