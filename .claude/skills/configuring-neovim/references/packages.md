# extraPackages & LazyVim Extras

## extraPackages (Nix가 관리하는 도구)

| 카테고리 | 패키지 | 용도 |
|----------|--------|------|
| LSP | `lua-language-server` | Lua |
| LSP | `nil` | Nix |
| LSP | `vtsls` | TypeScript/JS |
| LSP | `tailwindcss-language-server` | Tailwind CSS |
| LSP | `yaml-language-server` | YAML |
| LSP | `vscode-langservers-extracted` | JSON, HTML, CSS, ESLint |
| LSP | `markdown-oxide` | Markdown (Rust — marksman은 dotnet→Swift 의존성으로 macOS 빌드 실패) |
| 포매터 | `prettier` | JS/TS/CSS/JSON/YAML/MD |
| 포매터 | `stylua` | Lua |
| 포매터 | `nixfmt` | Nix |
| 린터 | `statix` | Nix |
| 빌드 | `tree-sitter` | nvim-treesitter 파서 컴파일 CLI |
| 빌드 | `gcc` | tree-sitter 파서 컴파일 **(Linux 전용)** |
| 빌드 | `nodejs` | LSP 런타임 의존성 |

> `ripgrep`, `fd`, `fzf`, `lazygit`은 `libraries/packages.nix`에서 이미 설치됨 — 중복 추가 금지

### 플랫폼 주의사항

`gcc`는 `lib.optionals pkgs.stdenv.isLinux`로 Linux 전용 추가. macOS에서 `gcc`를 무조건 추가하면 **LLVM 전체 소스 빌드가 트리거되어 빌드가 수십 분 멈춤**. macOS는 clang이 이미 있어 tree-sitter 파서 컴파일 가능.

## LazyVim extras

활성화된 extras:
- `lang.typescript` — vtsls + TS 도구
- `lang.nix` — nil_ls + nixfmt + statix
- `lang.json` — jsonls
- `lang.yaml` — yamlls
- `lang.markdown` — marksman 비활성화, `markdown_oxide`로 대체 (lsp.lua)
- `lang.tailwind` — tailwindcss LSP
- `linting.eslint` — ESLint LSP
- `formatting.prettier` — prettier 통합
