import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { resolve } from "node:path";
import test from "node:test";
import { addonPath, packagePath, escape } from "./harness.mjs";

const require = createRequire(resolve(packagePath, "package.json"));
const { JSDOM } = require("jsdom");
const source = await readFile(resolve(addonPath, "fenced-code.js"), "utf8");

function fixture(html) {
  const dom = new JSDOM(`<section id="field">${html}</section>`, { runScripts: "outside-only" });
  const { window } = dom;
  const field = window.document.getElementById("field");
  window.eval(source);
  return { dom, window, field, convert: () => window.AnkiFencedCodeV1.convert(field),
    close: () => window.close() };
}

function converts(html, expected, language = "bash") {
  const h = fixture(html);
  try {
    const result = h.convert();
    assert.equal(result.failed, false);
    assert.equal(result.codes.length, 1);
    assert.equal(result.codes[0].textContent, expected);
    assert.equal(result.codes[0].className, language ? `language-${language}` : "");
    assert.equal(result.codes[0].parentNode.tagName, "PRE");
    assert.equal(h.field.dataset.ankiFenceState, "converted");
  } finally { h.close(); }
}

test("converts a synthetic ADB example's BR input and excludes delimiter line separators", () => {
  const text = "❯ adb pair 198.51.100.123:12345\nEnter pairing code: 000000\nerror: protocol fault (couldn't read status message): Undefined error: 0";
  converts(`\`\`\`bash<br>${escape(text).replaceAll("\n", "<br>")}<br>\`\`\`<br><br>질문`, text);
});

test("accepts actual newlines and preserves indentation, tabs, blank lines, and NBSP", () => {
  const text = "  alpha\n\n\tbeta\u00a0 \n ";
  converts(escape(`   \`\`\`bash additional-info\n${text}\n \`\`\`\`\t`), text);
});

test("reads split inline text and entity-decoded code as literal characters", () => {
  converts('<b>``</b><span>`bash</span><br><strong>&lt;script&gt;window.changed=true&lt;/script&gt;</strong><br><a href="https://example.com">[표시|nid1234567890123]</a><br>$x$<br>```',
    '<script>window.changed=true</script>\n[표시|nid1234567890123]\n$x$');
  const h = fixture('```html<br>&lt;img src=x onerror=&quot;window.changed=true&quot;&gt;<br>```');
  try {
    h.convert();
    assert.equal(h.window.changed, undefined);
    assert.equal(h.field.querySelector("img"), null);
  } finally { h.close(); }
});

test("supports DIV, P, nested editor wrappers, and empty editor lines", () => {
  converts('<div>```bash</div><div>one</div><div><br></div><div>\ttwo&nbsp;</div><div>```</div>', "one\n\n\ttwo\u00a0");
  converts('<p>```bash</p><p>one</p><p></p><p>two</p><p>```</p>', "one\n\ntwo");
  converts('<div><p>```bash</p><p>one</p><p>two</p><p>```</p></div>', "one\ntwo");
  converts('<div>```bash<br>one<br>```</div>', "one");
  converts('<div>```bash<br></div><div>one<br></div><div>```<br></div>', "one");
});

test("three or more fences support shorter literal fences and longer closing fences", () => {
  converts("````bash\n```\ninside\n```\n`````", "```\ninside\n```");
  converts("```\nplain\n```", "plain", "");
  converts("```mystery-language\nplain\n```", "plain", "mystery-language");
});

test("does not recognize missing closers, inline ticks, tildes, four-space indent, or invalid info", () => {
  for (const html of [
    "```bash<br>unclosed", "prefix ```bash<br>one<br>```", "~~~bash<br>one<br>~~~",
    "    ```bash<br>one<br>```", "\t```bash<br>one<br>```", "&nbsp;```bash<br>one<br>```",
    "```ba`sh<br>one<br>```", "````bash<br>one<br>```", "```bash<br>one<br>```suffix",
  ]) {
    const h = fixture(html);
    try {
      const original = h.field.innerHTML;
      const result = h.convert();
      assert.equal(result.codes.length, 0, html);
      assert.equal(result.failed, false, html);
      assert.equal(h.field.innerHTML, original, html);
    } finally { h.close(); }
  }
});

test("keeps existing HTML code and all outside elements, handlers, and state", () => {
  const h = fixture('<details open><summary>outside</summary></details><p id="before">before <a id="link" href="#">link</a></p><div>```bash</div><div>new</div><div>```</div><pre id="existing"><code class="language-bash">```literal</code></pre><p id="after">after <input value="draft"></p>');
  try {
    const ids = ["before", "link", "existing", "after"].map(id => h.window.document.getElementById(id));
    const details = h.field.querySelector("details");
    const input = h.field.querySelector("input");
    input.value = "live draft";
    let clicked = 0;
    ids[1].addEventListener("click", () => clicked++);
    const result = h.convert();
    assert.equal(result.failed, false);
    assert.equal(result.codes[0].textContent, "new");
    for (const node of ids) assert.equal(h.window.document.getElementById(node.id), node);
    assert.equal(h.field.querySelector("details"), details);
    assert.equal(details.open, true);
    assert.equal(h.field.querySelector("input"), input);
    assert.equal(input.value, "live draft");
    ids[1].dispatchEvent(new h.window.Event("click"));
    assert.equal(clicked, 1);
    assert.equal(ids[2].querySelector("code").textContent, "```literal");
  } finally { h.close(); }
});

test("existing PRE/CODE fences are skipped and cannot be consumed by an outer fence", () => {
  for (const html of ['<pre><code>```bash\none\n```</code></pre>', '<code>```bash\none\n```</code>']) {
    const h = fixture(html);
    try {
      const original = h.field.innerHTML;
      assert.equal(h.convert().codes.length, 0);
      assert.equal(h.field.innerHTML, original);
    } finally { h.close(); }
  }
  const h = fixture('```bash<br><pre><code>old</code></pre><br>```');
  try { assert.equal(h.convert().failed, true); } finally { h.close(); }
  const inline = fixture('<code>prefix</code>```bash<br>one<br>```');
  try { assert.equal(inline.convert().codes.length, 0); } finally { inline.close(); }
});

test("multiple blocks convert once, and a new FrontSide DOM converts independently", () => {
  const html = "```bash<br>one<br>```<br>between<br>```python<br>two<br>```";
  const h = fixture(html);
  try {
    const first = h.convert();
    assert.deepEqual(Array.from(first.codes, node => node.textContent), ["one", "two"]);
    const second = h.convert();
    assert.equal(second.codes[0], first.codes[0]);
    assert.equal(h.field.querySelectorAll("pre").length, 2);
    h.window.eval(source);
    const clone = h.window.document.createElement("section");
    clone.innerHTML = html;
    h.field.after(clone);
    const cloned = h.window.AnkiFencedCodeV1.convert(clone);
    assert.equal(cloned.codes.length, 2);
    assert.notEqual(cloned.codes[0], first.codes[0]);
  } finally { h.close(); }
});

test("unsupported fenced content fails the whole field before changing any original node", () => {
  for (const unsafe of [
    '<img src="example.png">', '<span hidden>hidden</span>', '<span style="display:none">hidden</span>',
    '<span aria-hidden="true">hidden</span>', '<script>window.changed=true</script>',
    '<textarea>draft</textarea>', '<table><tbody><tr><td>cell</td></tr></tbody></table>',
    '<input value="draft">', '<svg><text>drawing</text></svg>',
    '<span contenteditable="true">live draft</span>', '<span class="katex">x</span>',
    '<span class="MathJax">x</span>',
  ]) {
    const h = fixture(`\`\`\`bash<br>safe<br>\`\`\`<br>\`\`\`bash<br>${unsafe}<br>\`\`\``);
    try {
      const nodes = Array.from(h.field.childNodes);
      const original = h.field.innerHTML;
      const result = h.convert();
      assert.equal(result.failed, true, unsafe);
      assert.equal(result.codes.length, 0);
      assert.equal(h.field.querySelectorAll("code[data-anki-fenced]").length, 0);
      for (let i = 0; i < nodes.length; i++) assert.equal(h.field.childNodes[i], nodes[i]);
      assert.equal(h.field.innerHTML.startsWith(original), true);
      assert.equal(h.field.querySelectorAll(".anki-fence-error").length, 1);
      assert.equal(h.convert().failed, true);
      assert.equal(h.field.querySelectorAll(".anki-fence-error").length, 1);
      assert.equal(h.window.changed, undefined);
    } finally { h.close(); }
  }
});

test("unsupported content outside closed regions does not prevent conversion", () => {
  const h = fixture('<img id="outside"><span hidden>```bash<br>hidden<br>```</span><div>```bash</div><div>one</div><div>```</div>');
  try {
    const image = h.field.querySelector("img");
    assert.equal(h.convert().failed, false);
    assert.equal(h.field.querySelector("img"), image);
  } finally { h.close(); }
});

test("a fence inside an unsupported ancestor fails without flattening that ancestor", () => {
  const h = fixture('<blockquote><p>context</p><p>```bash</p><p>one</p><p>```</p></blockquote>');
  try {
    const quote = h.field.firstChild;
    const original = quote.innerHTML;
    assert.equal(h.convert().failed, true);
    assert.equal(h.field.firstChild, quote);
    assert.equal(quote.innerHTML, original);
  } finally { h.close(); }
});

test("commit errors restore original references, text, handlers, and field state atomically", () => {
  const h = fixture('<p id="outside">context <input value="draft"></p><span id="start">before\n```bash</span><b id="middle">\none\n```\nafter</b><br>```python<br>two<br>```');
  try {
    const originals = Array.from(h.field.querySelectorAll("*"));
    const originalChildren = new Map([h.field, ...originals].map(node => [node, Array.from(node.childNodes)]));
    const texts = Array.from(originalChildren.values()).flat().filter(node => node.nodeType === 3);
    const originalData = texts.map(node => node.data);
    const originalHTML = h.field.innerHTML;
    const input = h.field.querySelector("input");
    input.value = "live draft";
    let clicked = 0;
    const outside = h.window.document.getElementById("outside");
    outside.addEventListener("click", () => clicked++);
    const insert = h.window.Range.prototype.insertNode;
    let calls = 0;
    h.window.Range.prototype.insertNode = function (node) {
      if (++calls === 2) throw new Error("injected second commit failure");
      return insert.call(this, node);
    };
    const result = h.convert();
    assert.equal(result.failed, true);
    assert.equal(calls, 2);
    assert.equal(h.field.querySelectorAll("code[data-anki-fenced]").length, 0);
    assert.equal(h.field.innerHTML.startsWith(originalHTML), true);
    for (const [node, children] of originalChildren) {
      const actual = Array.from(node.childNodes).filter(child => child.nodeType !== 1 || child.className !== "anki-fence-error");
      assert.deepEqual(actual, children);
    }
    for (let i = 0; i < texts.length; i++) assert.equal(texts[i].data, originalData[i]);
    assert.equal(input.value, "live draft");
    outside.dispatchEvent(new h.window.Event("click"));
    assert.equal(clicked, 1);
    assert.equal(h.convert().failed, true);
    assert.equal(calls, 2);
  } finally { h.close(); }
});

test("empty code and explicit trailing blank content are not trimmed", () => {
  converts("```bash\n```", "");
  converts("```bash\nline\n\n\n```", "line\n\n");
});

test("CSS-hidden contents fail safely, while visible styled text and an opacity gate remain supported", () => {
  for (const rule of ["display:none", "visibility:hidden", "visibility:collapse", "opacity:0"]) {
    for (const tag of ["span", "div"]) {
      const h = fixture(`\`\`\`bash<br><${tag} class="concealed">secret</${tag}><br>\`\`\``);
      try {
        const style = h.window.document.createElement("style");
        style.textContent = `.concealed { ${rule} }`;
        h.window.document.head.appendChild(style);
        const original = h.field.innerHTML;
        assert.equal(h.convert().failed, true, `${tag}: ${rule}`);
        assert.equal(h.field.innerHTML.startsWith(original), true);
      } finally { h.close(); }
    }
  }
  const h = fixture('```bash<br><span class="visible" style="font-weight:bold">shown</span><br>```');
  try {
    h.window.document.body.className = "night_mode";
    h.field.style.opacity = "0";
    h.field.style.pointerEvents = "none";
    const style = h.window.document.createElement("style");
    style.textContent = ".night_mode { background:#111; color:white } .visible { font-style:italic }";
    h.window.document.head.appendChild(style);
    const result = h.convert();
    assert.equal(result.failed, false);
    assert.equal(result.codes[0].textContent, "shown");
  } finally { h.close(); }
});

test("tag and descendant CSS cannot expose classless hidden content or ancestors", () => {
  const cases = [
    [".concealed span { display:none }", '<div class="concealed">```bash<br><span>secret</span><br>```</div>'],
    ["section > span { visibility:hidden }", '<span>```bash<br>secret<br>```</span>'],
    ["section > div { opacity:0 }", '<div>```bash<br>secret<br>```</div>'],
    ["section span { visibility:collapse }", '```bash<br><span>secret</span><br>```'],
  ];
  for (const [rule, html] of cases) {
    const h = fixture(html);
    try {
      const style = h.window.document.createElement("style");
      style.textContent = rule;
      h.window.document.head.appendChild(style);
      const original = h.field.innerHTML;
      const result = h.convert();
      assert.equal(result.failed, true, rule);
      assert.equal(result.codes.length, 0);
      assert.equal(h.field.querySelectorAll("code[data-anki-fenced]").length, 0);
      const clone = h.field.cloneNode(true);
      clone.querySelector(".anki-fence-error").remove();
      assert.equal(clone.innerHTML, original, "CSS-hidden markup must remain exactly preserved");
    } finally { h.close(); }
  }
});

test("zero-size, content-hidden and alpha-zero text keep the entire original field", () => {
  for (const declaration of [
    "font-size:0", "content-visibility:hidden", "color:transparent",
    "color:rgba(20,30,40,0)", "color:color(display-p3 1 0 0 / 0%)",
    "color:oklab(50% 0 0 / 0)",
    "-webkit-text-fill-color:transparent", "color:transparent;-webkit-text-fill-color:currentColor",
    "color:transparent;text-shadow:0 0 1px black",
  ]) {
    const h = fixture(`\`\`\`bash<br><span style="${declaration}">secret</span><br>\`\`\``);
    try {
      const original = h.field.innerHTML;
      const result = h.convert();
      assert.equal(result.failed, true, declaration);
      assert.equal(result.codes.length, 0);
      const clone = h.field.cloneNode(true);
      clone.querySelector(".anki-fence-error").remove();
      assert.equal(clone.innerHTML, original);
    } finally { h.close(); }
  }
});

test("partially transparent color or opacity and opaque text fill remain readable code", () => {
  for (const declaration of [
    "color:rgba(20,30,40,0.5)", "opacity:0.5", "color:color(display-p3 1 0 0 / 50%)",
    "color:oklab(50% 0 0 / 50%)",
    "color:transparent;-webkit-text-fill-color:black",
  ]) {
    converts(`\`\`\`bash<br><span style="${declaration}">visible</span><br>\`\`\``, "visible");
  }
});

test("CSS validation skips rich outside prose and only inspects a complete fenced region", () => {
  const prose = '<p class="outside"><b>outside</b><span style="font-weight:bold"> prose</span></p>'.repeat(80);
  for (const code of ['```bash<br>one<br>```', '```bash<br>unfinished']) {
    const h = fixture(prose + code);
    try {
      h.window.getComputedStyle = () => { throw new Error("outside CSS must not be inspected"); };
      assert.equal(h.convert().failed, false);
    } finally { h.close(); }
  }
});

test("plain and simple fenced input avoid computed-style reads; styled nodes are read once", () => {
  for (const html of ["ordinary field", "```bash<br>one<br>```", "```bash\none\n```"]) {
    const h = fixture(html);
    try {
      h.window.getComputedStyle = () => { throw new Error("unexpected style query"); };
      assert.equal(h.convert().failed, false, html);
    } finally { h.close(); }
  }
  const h = fixture('```bash<br><span class="visible">one</span><br>```');
  try {
    let reads = 0;
    const computedStyle = h.window.getComputedStyle.bind(h.window);
    h.window.getComputedStyle = node => { reads++; return computedStyle(node); };
    assert.equal(h.convert().failed, false);
    assert.equal(reads, 1);
  } finally { h.close(); }
  const nested = fixture('<div>```bash</div><div><span>one</span></div><div>```</div>');
  try {
    const reads = new Map();
    const computedStyle = nested.window.getComputedStyle.bind(nested.window);
    nested.window.getComputedStyle = node => {
      reads.set(node, (reads.get(node) || 0) + 1);
      return computedStyle(node);
    };
    assert.equal(nested.convert().failed, false);
    assert.equal(reads.size, 4, "the three editor DIVs and content SPAN need CSS validation");
    assert.ok([...reads.values()].every(count => count === 1), "ancestor and region checks must share style results");
  } finally { nested.close(); }
});
