# Anki code highlighting assets

The browser bundle contains highlight.js core and only the grammars listed in
`dist/manifest.json`. All dependencies are exact versions in `package.json` and
integrity-pinned in `package-lock.json`. Run the build from this directory:

```sh
mise exec -- npm ci --ignore-scripts --no-audit --no-fund
mise exec -- npm run build
mise exec -- npm run check
mise exec -- npm run test:library
```

`build` produces the versioned, content-hashed JavaScript media file, its upstream
BSD license, and a manifest. `check` rebuilds in memory and compares all bytes and
the complete file list, so stale or edited artifacts fail verification. Commit
both the source/lockfile and generated `dist` files when changing the bundle.

Copy the actual files (not symlinks) to Anki's media collection through the host's
media workflow. The leading underscore prevents unused-media cleanup from
removing template assets; it does not prove that another device has synced them.
The license file accompanies the JavaScript. No CDN or runtime download is used.

The bundle exposes only `window.AnkiSyntaxHighlightLibraryV1` with `version`,
`getLanguage(name)`, and `highlight(code, options)`. It neither reads nor replaces
the legacy `window.hljs`. Explicit language labels are required by the renderer;
internal HTTP body auto-detection is disabled too. JSX/TSX and HTML use the XML
grammar, with embedded CSS/JavaScript supported. Optional GraphQL/Ruby embedded
fragments are plain text because those grammars are outside the supported set.

`jsdom` is a development dependency for DOM tests only; it is not bundled or
deployed to Anki. The generated JavaScript targets ES2018.
