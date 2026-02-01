# Neovim (LazyVim) 설정

## 아키텍처

**Hybrid 방식**: Nix가 바이너리/외부 도구 관리, lazy.nvim이 플러그인 관리.

- **Mason 비활성화**: LSP/포매터/린터는 `extraPackages`로 Nix가 설치
- **lazy.nvim**: 런타임에 플러그인 다운로드 및 관리
- **mkOutOfStoreSymlink**: `~/.config/nvim` → repo의 `files/nvim/` 심볼릭 링크 (양방향 수정 가능)

## 파일 구조

```
modules/shared/programs/neovim/
├── default.nix                      # Nix 설정 (extraPackages, 심볼릭 링크)
└── files/nvim/                      # → ~/.config/nvim
    ├── init.lua                     # 진입점 (require("config.lazy"))
    ├── stylua.toml                  # Lua 포매터 (2-space indent)
    ├── lazy-lock.json               # 플러그인 버전 잠금 (자동 생성, 커밋 대상)
    ├── lazyvim.json                 # LazyVim extras 추적 (자동 관리)
    └── lua/
        ├── config/
        │   ├── lazy.lua             # lazy.nvim 부트스트랩 + extras 목록
        │   ├── options.lua          # Vim 옵션
        │   ├── keymaps.lua          # 커스텀 키맵 (jk→Esc)
        │   └── autocmds.lua         # 모바일 화면 감지, FocusGained 한글 IM 전환
        └── plugins/
            ├── disabled.lua         # Mason 비활성화 (mason-org/), mini.surround 비활성화 (nvim-mini/)
            ├── colorscheme.lua      # Catppuccin Mocha
            ├── lsp.lua              # 추가 LSP (cssls, html)
            ├── treesitter.lua       # 파서 목록
            ├── editor.lua           # surround, im-select, neo-tree
            └── ui.lua               # bufferline, lualine, noice
```

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

### extraPackages 플랫폼 주의사항

`gcc`는 `lib.optionals pkgs.stdenv.isLinux`로 Linux 전용 추가. macOS에서 `gcc`를 무조건 추가하면 **LLVM 전체 소스 빌드가 트리거되어 빌드가 수십 분 멈춤**. macOS는 clang이 이미 있어 tree-sitter 파서 컴파일 가능.

## Mason 비활성화 주의사항

Mason 프로젝트가 `williamboman`에서 `mason-org`로 마이그레이션됨:
```lua
-- 올바른 방법 (mason-org/)
{ "mason-org/mason.nvim", enabled = false }

-- 잘못된 방법 (매칭 실패)
{ "williamboman/mason.nvim", enabled = false }
```

## mini.nvim 조직 이전 주의사항

mini.nvim 0.17.0 (2025-12)에서 `echasnovski` → `nvim-mini` 조직으로 이전됨:
```lua
-- 올바른 방법 (nvim-mini/)
{ "nvim-mini/mini.surround", enabled = false }

-- 잘못된 방법 (매칭 실패 → 경고 발생)
{ "echasnovski/mini.surround", enabled = false }
```

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

## 모바일 최적화 (iPad Termius)

- `jk` → Esc (Insert 모드) — 소프트웨어 키보드 UX
- 100컬럼 미만: `relativenumber=false`, `wrap=true`, 좁은 neo-tree
- telescope `flex` 레이아웃: 좁은 화면에서 수직 전환

## 클립보드 전략

`clipboard = "unnamedplus"` 설정:
- **macOS 로컬**: 시스템 클립보드 직접 연동
- **SSH + tmux**: tmux-yank + OSC 52 (터미널 앱이 지원하는 경우)
- **Termius**: OSC 52 미지원 → tmux-thumbs (`prefix+F`)로 보완

## 주요 키맵

LazyVim 기본 키맵 (which-key로 탐색):
- `<leader>ff` 파일 찾기 | `<leader>fg` Git 파일 찾기 | `<leader>/` 텍스트 검색 | `<leader>e` snacks.explorer
- `<leader>gg` lazygit | `<leader>cf` 포맷 | `K` hover
- `gd` 정의 | `gr` 참조 | `H`/`L` 이전/다음 버퍼

커스텀 키맵:
- `jk` → Esc (Insert 모드)
- `<C-\>` → 터미널 Normal 모드

## 한국어 입력 지원 (macOS)

외부 앱에서 한글을 쓰다가 Neovim으로 돌아왔을 때 Normal 모드에서 키맵이 동작하지 않는 문제를 2계층으로 방어:

| 레이어 | 도구 | 파일 | 담당 |
|--------|------|------|------|
| 1차 | FocusGained autocmd | `autocmds.lua` | 외부 앱 복귀 시 영문 IM 전환 → 내장/플러그인 명령 정상 동작 |
| 2차 | im-select.nvim | `editor.lua` | Insert↔Normal 전환 시 영문/한글 자동 전환 |

- **macOS 전용**: `vim.fn.executable("macism") == 1`로 NixOS/SSH 환경에서 자동 비활성화
- **langmap/langmapper 미사용**: 한글 IME 조합(자음+모음→음절) 특성상 extra keystroke 문제 발생. 러시아어(키릴)처럼 1:1 매핑이 되지 않아 실용성 없음

### 알려진 제한

- Neovim 내부에서 한글로 전환 후 Normal 모드 명령 사용 시, FocusGained가 발동하지 않아 수동으로 영문 전환 필요
- 한글 IME 조합 지연은 macOS/터미널 레이어 문제로 Neovim 플러그인에서 해결 불가 (터미널 IME escape sequence 미지원)

## 제약사항

- `programs.neovim`에 `plugins`/`initLua`/`extraConfig` 추가 금지 (심볼릭 링크 충돌)
- DAP 디버깅 미지원 (Mason 비활성화로 js-debug-adapter 미설치)
- `default.nix` 함수 시그니처에 `nixosConfigPath` 명시 필수
- **extraPackages에 C 컴파일러(gcc 등) 추가 시 반드시 `lib.optionals pkgs.stdenv.isLinux` 사용** — macOS에서 LLVM 소스 빌드 방지
- **marksman 사용 금지** → `markdown-oxide` 사용. marksman은 dotnet→Swift 의존성 체인으로 macOS에서 Swift 소스 빌드 실패
