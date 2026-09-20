import hljs from "highlight.js/lib/core";
import bash from "highlight.js/lib/languages/bash";
import c from "highlight.js/lib/languages/c";
import css from "highlight.js/lib/languages/css";
import http from "highlight.js/lib/languages/http";
import java from "highlight.js/lib/languages/java";
import javascript from "highlight.js/lib/languages/javascript";
import json from "highlight.js/lib/languages/json";
import python from "highlight.js/lib/languages/python";
import sql from "highlight.js/lib/languages/sql";
import typescript from "highlight.js/lib/languages/typescript";
import xml from "highlight.js/lib/languages/xml";
import yaml from "highlight.js/lib/languages/yaml";

// XML is also the embedded markup grammar used by JavaScript/TypeScript JSX.
// Register only the explicit authoring languages, not the upstream common set.
for (const [name, grammar] of Object.entries({
  bash, c, css, http, java, javascript, json, python, sql, typescript, xml, yaml,
})) {
  hljs.registerLanguage(name, grammar);
}
hljs.registerAliases("shell", { languageName: "bash" });
// The HTTP grammar otherwise auto-detects the body even with an explicit HTTP
// label. No auto-detection is allowed, including embedded-language fallbacks.
hljs.configure({ languages: [] });

// Older note types can load their own window.hljs in the same reused webview.
// Expose only our isolated explicit-language API, never highlightAuto/DOM hooks.
globalThis.AnkiSyntaxHighlightLibraryV1 = Object.freeze({
  version: hljs.versionString,
  highlight(code, options) {
    return hljs.highlight(code, options);
  },
  getLanguage(name) {
    return hljs.getLanguage(name);
  },
});
