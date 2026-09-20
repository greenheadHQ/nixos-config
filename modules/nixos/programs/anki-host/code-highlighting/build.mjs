import { build } from "esbuild";
import { createHash } from "node:crypto";
import { mkdir, readFile, readdir, unlink, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { gzipSync } from "node:zlib";

const directory = dirname(fileURLToPath(import.meta.url));
const check = process.argv.includes("--check");
if (process.argv.slice(2).some((arg) => arg !== "--check")) {
  throw new Error("Usage: node build.mjs [--check]");
}
const readJSON = async (path) => JSON.parse(await readFile(path, "utf8"));
const lock = await readJSON(join(directory, "package-lock.json"));
const packageJSON = await readJSON(join(directory, "package.json"));
const dependencies = ["highlight.js", "esbuild"];
for (const dependency of dependencies) {
  const installed = await readJSON(join(directory, "node_modules", dependency, "package.json"));
  const locked = lock.packages[`node_modules/${dependency}`];
  if (installed.version !== locked.version || locked.version !== packageJSON.devDependencies[dependency]) {
    throw new Error(`${dependency} version differs from the exact package/lock pin; run npm ci`);
  }
}
const upstream = lock.packages["node_modules/highlight.js"];
const license = await readFile(join(directory, "node_modules/highlight.js/LICENSE"));
// Anki canonicalizes media filenames to lowercase; the on-disk/readback name must match.
const licenseFilename = `_anki-syntax-hljs-${upstream.version}.license.txt`;
const result = await build({
  absWorkingDir: directory,
  entryPoints: ["library.js"],
  bundle: true,
  minify: true,
  format: "iife",
  platform: "browser",
  target: "es2018",
  charset: "utf8",
  legalComments: "none",
  banner: {
    js: `/*! highlight.js ${upstream.version} | BSD-3-Clause | See ${licenseFilename} */`,
  },
  write: false,
});
const output = result.outputFiles[0].contents;
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
const sha256 = hash(output);
const filename = `_anki-syntax-hljs-${upstream.version}-${sha256.slice(0, 16)}.min.js`;
const manifest = {
  schemaVersion: 1,
  namespace: "AnkiSyntaxHighlightLibraryV1",
  library: {
    name: "highlight.js",
    version: upstream.version,
    integrity: upstream.integrity,
    license: "BSD-3-Clause",
  },
  grammars: ["bash", "c", "css", "http", "java", "javascript", "json", "python", "sql", "typescript", "xml", "yaml"],
  asset: {
    filename,
    sha256,
    integrity: `sha256-${createHash("sha256").update(output).digest("base64")}`,
    bytes: output.byteLength,
  },
  license: { filename: licenseFilename, sha256: hash(license) },
  build: { esbuild: lock.packages["node_modules/esbuild"].version, target: "es2018" },
};
const expected = new Map([
  [filename, output],
  [licenseFilename, license],
  ["manifest.json", Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`)],
]);
const dist = join(directory, "dist");
if (check) {
  const actualNames = (await readdir(dist)).sort();
  const expectedNames = [...expected.keys()].sort();
  if (JSON.stringify(actualNames) !== JSON.stringify(expectedNames)) {
    throw new Error("dist file list differs from the reproducible build; run npm run build");
  }
  for (const [name, bytes] of expected) {
    if (!Buffer.from(bytes).equals(await readFile(join(dist, name)))) {
      throw new Error(`dist/${name} differs from the reproducible build; run npm run build`);
    }
  }
} else {
  await mkdir(dist, { recursive: true });
  // Delete only prior outputs owned by this build, never unrelated files.
  for (const name of await readdir(dist)) {
    if (name.startsWith("_anki-syntax-hljs-") && !expected.has(name)) {
      await unlink(join(dist, name));
    }
  }
  for (const [name, bytes] of expected) await writeFile(join(dist, name), bytes);
}
console.log(`${check ? "Verified" : "Built"} ${filename}: ${manifest.asset.bytes} bytes (${gzipSync(output, { level: 9 }).byteLength} gzip)`);
