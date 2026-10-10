(function () {
  "use strict";
  if (window.AnkiFencedCodeV1) return;

  const BLOCKS = new Set(["DIV", "P"]);
  const INLINE = new Set([
    "SPAN", "B", "I", "STRONG", "EM", "A", "U", "S", "STRIKE", "SUB", "SUP",
    "MARK", "SMALL", "FONT", "ABBR", "KBD", "SAMP", "VAR", "WBR",
  ]);
  const SKIP = new Set(["PRE", "CODE", "SCRIPT", "STYLE", "TEXTAREA"]);
  const hiddenInMarkup = node => {
    if (node.hasAttribute("hidden") || node.getAttribute("aria-hidden") === "true") return true;
    if (!node.hasAttribute("style")) return false;
    const style = node.style;
    return style.display === "none" || style.visibility === "hidden" ||
      style.visibility === "collapse" || style.opacity === "0";
  };
  // Match the copy control's conclusive alpha-zero color checks. A shadow or
  // stroke may paint transparent text, but preserving such markup is safer than
  // guessing whether flattening would disclose an originally hidden answer.
  const transparentColor = color => {
    const value = (color || "").trim().toLowerCase();
    if (value === "transparent") return true;
    const alpha = value.match(/^(?:rgba|hsla)\([^,]+,[^,]+,[^,]+,\s*([^,()]+)\)$/)?.[1] ||
      value.match(/^(?:rgba?|hsla?|hwb|lab|lch|oklab|oklch|color)\([^()]*\/\s*([^/()]+)\)$/)?.[1];
    return !!alpha && /^[+-]?(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?%?$/.test(alpha.trim()) &&
      Number(alpha.trim().replace(/%$/, "")) === 0;
  };
  const hidden = (node, styles) => {
    if (node.hasAttribute("hidden") || node.getAttribute("aria-hidden") === "true") return true;
    if (styles.has(node)) return styles.get(node);
    const style = window.getComputedStyle(node);
    const fill = style.getPropertyValue("-webkit-text-fill-color").trim().toLowerCase();
    const foreground = !fill || fill === "currentcolor" ? style.color : fill;
    const result = style.display === "none" || style.visibility === "hidden" ||
      style.visibility === "collapse" || style.opacity === "0" ||
      style.contentVisibility === "hidden" || parseFloat(style.fontSize) === 0 ||
      transparentColor(foreground);
    styles.set(node, result);
    return result;
  };
  const unsafe = (node, styles) => SKIP.has(node.tagName) || hidden(node, styles) ||
    node.hasAttribute("contenteditable") || /(?:^|\s)(?:katex|MathJax|mjx-)[^\s]*/.test(node.getAttribute("class") || "") ||
    (!BLOCKS.has(node.tagName) && !INLINE.has(node.tagName) && node.tagName !== "BR");
  const point = (node, offset) => ({ node, offset });
  const before = (node, positions) => point(node.parentNode, positions.get(node));
  const after = (node, positions) => { const value = before(node, positions); value.offset++; return value; };

  // Text and editor line breaks are read without rebuilding the field. Each
  // logical chunk retains its DOM position so only fenced regions are replaced.
  function read(scope) {
    const chunks = [];
    const barriers = [];
    const blocks = new WeakMap();
    const positions = new WeakMap();
    const styles = new WeakMap();
    const contentElements = [];
    const nodeBefore = node => before(node, positions);
    const nodeAfter = node => after(node, positions);
    let length = 0;
    let last = "";
    function append(text, start, end, textNode) {
      if (!text) return;
      chunks.push({ start: length, end: length + text.length, text, from: start, to: end, textNode });
      length += text.length;
      last = text[text.length - 1];
    }
    function boundary(where) {
      if (length && last !== "\n") append("\n", where, where, null);
    }
    function visit(node, index) {
      positions.set(node, index);
      if (node.nodeType === 3) {
        append(node.data, point(node, 0), point(node, node.data.length), node);
        return;
      }
      if (node.nodeType !== 1) return;
      const tag = node.tagName;
      if (SKIP.has(tag) || hiddenInMarkup(node)) {
        barriers.push({ offset: length, node });
        if (!hiddenInMarkup(node) && (tag === "PRE" || tag === "CODE" || tag === "TEXTAREA")) {
          if (tag === "PRE") boundary(nodeBefore(node));
          append("\ufffc", nodeBefore(node), nodeAfter(node), null);
          if (tag === "PRE") boundary(nodeAfter(node));
        }
        return;
      }
      if (tag === "BR") {
        append("\n", nodeBefore(node), nodeAfter(node), null);
        return;
      }
      // Structural reading must not ask for every outside element's CSS. A
      // matched region checks its content and ancestors before flattening them.
      // Empty BR/WBR nodes contain no hidden characters to expose.
      if (node.childNodes.length) contentElements.push({ offset: length, node });
      const block = BLOCKS.has(tag);
      if (block) boundary(nodeBefore(node));
      if (node.hasAttribute("contenteditable") || /(?:^|\s)(?:katex|MathJax|mjx-)[^\s]*/.test(node.getAttribute("class") || "") ||
        (!block && !INLINE.has(tag))) {
        barriers.push({ offset: length, node });
        if (!node.childNodes.length) append("\ufffc", nodeBefore(node), nodeAfter(node), null);
      }
      const start = length;
      for (let index = 0; index < node.childNodes.length; index++) visit(node.childNodes[index], index);
      const contentEnd = length;
      if (block) {
        // A completely empty editor DIV/P still represents an empty line.
        if (length === start) append("\n", nodeAfter(node), nodeAfter(node), null);
        else boundary(nodeAfter(node));
        blocks.set(node, { start, contentEnd, end: length });
      }
    }
    for (let index = 0; index < scope.childNodes.length; index++) visit(scope.childNodes[index], index);
    return { text: chunks.map(chunk => chunk.text).join(""), chunks, barriers, blocks, positions, styles, contentElements };
  }

  function position(chunks, offset, end) {
    let low = 0;
    let high = chunks.length - 1;
    while (low <= high) {
      const middle = (low + high) >>> 1;
      const chunk = chunks[middle];
      if (offset < chunk.start || (end && offset === chunk.start)) high = middle - 1;
      else if (offset > chunk.end || (!end && offset === chunk.end)) low = middle + 1;
      else if (chunk.textNode) return point(chunk.textNode, offset - chunk.start);
      else return end ? chunk.to : chunk.from;
    }
    // The end of the final line has no following chunk.
    return chunks[chunks.length - 1].to;
  }

  function lineBlock(scope, where, blocks, start, end) {
    let node = where.node.nodeType === 1 ? where.node : where.node.parentNode;
    for (; node && node !== scope; node = node.parentNode) {
      const bounds = blocks.get(node);
      if (bounds && bounds.start === start && (bounds.contentEnd === end || bounds.contentEnd === end + 1)) return node;
    }
    return null;
  }

  function fail(scope) {
    scope.dataset.ankiFenceState = "failed";
    if (!scope.querySelector(".anki-fence-error")) {
      const notice = scope.ownerDocument.createElement("small");
      notice.className = "anki-fence-error";
      notice.setAttribute("role", "status");
      notice.textContent = "코드 블록을 안전하게 변환하지 못해 원문을 표시합니다.";
      scope.appendChild(notice);
    }
    return { codes: [], failed: true };
  }

  function convert(scope) {
    const state = scope.dataset.ankiFenceState;
    if (state) return {
      codes: state === "converted" ? Array.from(scope.querySelectorAll("code[data-anki-fenced]")) : [],
      failed: state === "failed",
    };
    if (scope.textContent.indexOf("```") === -1) {
      scope.dataset.ankiFenceState = "plain";
      return { codes: [], failed: false };
    }
    try {
      const source = read(scope);
      const plans = [];
      let opener = null;
      let start = 0;
      while (start <= source.text.length) {
        const newline = source.text.indexOf("\n", start);
        const end = newline === -1 ? source.text.length : newline;
        const line = source.text.slice(start, end);
        const match = /^ {0,3}(`{3,})([^`]*)$/.exec(line);
        if (!opener && match) {
          opener = { start, end, body: newline === -1 ? end : end + 1,
            count: match[1].length, language: match[2].trim().split(/\s+/)[0] };
        } else if (opener && match && match[1].length >= opener.count && /^[ \t]*$/.test(match[2])) {
          // Remove the separator before the closing fence, never trim the body.
          const bodyEnd = Math.max(opener.body, start - 1);
          plans.push({ open: opener, start, end, text: source.text.slice(opener.body, bodyEnd) });
          opener = null;
        }
        if (newline === -1) break;
        start = end + 1;
      }
      if (!plans.length) {
        scope.dataset.ankiFenceState = "plain";
        return { codes: [], failed: false };
      }
      // Validate every region before committing any conversion in this field.
      let barrierIndex = 0;
      let contentIndex = 0;
      const range = scope.ownerDocument.createRange();
      const prepared = plans.map(plan => {
        let from = position(source.chunks, plan.open.start, false);
        let to = position(source.chunks, plan.end, true);
        // An unsupported ancestor may begin before the opening line; its entry
        // offset alone would not catch a fence nested inside it.
        for (let node = from.node.nodeType === 1 ? from.node : from.node.parentNode;
          node && node !== scope; node = node.parentNode) {
          if (unsafe(node, source.styles)) throw new Error("unsafe fenced ancestor");
        }
        const firstBlock = lineBlock(scope, from, source.blocks, plan.open.start, plan.open.end);
        const lastBlock = lineBlock(scope, to, source.blocks, plan.start, plan.end);
        if (firstBlock) from = before(firstBlock, source.positions);
        if (lastBlock) to = after(lastBlock, source.positions);
        range.setStart(from.node, from.offset);
        range.setEnd(to.node, to.offset);
        while (barrierIndex < source.barriers.length && source.barriers[barrierIndex].offset < plan.open.start) barrierIndex++;
        while (barrierIndex < source.barriers.length && source.barriers[barrierIndex].offset <= plan.end) {
          if (range.intersectsNode(source.barriers[barrierIndex++].node)) throw new Error("unsafe fenced content");
        }
        while (contentIndex < source.contentElements.length && source.contentElements[contentIndex].offset < plan.open.start) contentIndex++;
        while (contentIndex < source.contentElements.length && source.contentElements[contentIndex].offset <= plan.end) {
          const node = source.contentElements[contentIndex++].node;
          if (range.intersectsNode(node) && hidden(node, source.styles)) throw new Error("hidden fenced content");
        }
        const pre = scope.ownerDocument.createElement("pre");
        const code = scope.ownerDocument.createElement("code");
        code.dataset.ankiFenced = "";
        if (plan.open.language) code.className = "language-" + plan.open.language;
        code.textContent = plan.text;
        pre.appendChild(code);
        return { from, to, common: range.commonAncestorContainer, pre, code };
      });
      // A Range can split endpoint text/ancestors. Keep original references for
      // only those touched parents, so rollback preserves outside listeners and
      // live state without cloning or snapshotting every descendant in a field.
      const savedParents = new Map();
      const savedTexts = new Map();
      function saveParent(node) {
        if (!savedParents.has(node)) savedParents.set(node, Array.from(node.childNodes));
      }
      function saveBoundary(node, common) {
        if (node.nodeType === 3) savedTexts.set(node, node.data);
        while (node && node !== common) {
          if (node.nodeType === 1) saveParent(node);
          node = node.parentNode;
        }
        if (common.nodeType === 3) {
          savedTexts.set(common, common.data);
          saveParent(common.parentNode);
        } else saveParent(common);
      }
      for (const item of prepared) {
        saveBoundary(item.from.node, item.common);
        saveBoundary(item.to.node, item.common);
      }
      try {
        for (let i = prepared.length - 1; i >= 0; i--) {
          const item = prepared[i];
          range.setStart(item.from.node, item.from.offset);
          range.setEnd(item.to.node, item.to.offset);
          range.extractContents();
          range.insertNode(item.pre);
        }
      } catch (error) {
        for (const [node, children] of savedParents) node.replaceChildren(...children);
        for (const [node, data] of savedTexts) node.data = data;
        throw error;
      }
      scope.dataset.ankiFenceState = "converted";
      return { codes: prepared.map(item => item.code), failed: false };
    } catch (error) {
      return fail(scope);
    }
  }
  window.AnkiFencedCodeV1 = { convert };
})();
