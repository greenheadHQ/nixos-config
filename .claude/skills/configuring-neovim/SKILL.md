---
name: configuring-neovim
description: |
  Neovim/LazyVim setup: LSP, plugins, im-select, extraPackages.
  Triggers: "nvim 플러그인", "lazy.nvim", "한글 입력", "im-select",
  "extraPackages", Mason migration, tree-sitter build errors.
---

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
            ├── disabled.lua         # Mason (mason-org/), mini.surround (nvim-mini/), tokyonight.nvim, indent-blankline.nvim, neo-tree.nvim 비활성화
            ├── colorscheme.lua      # Catppuccin Mocha
            ├── lsp.lua              # 추가 LSP (cssls, html)
            ├── treesitter.lua       # 파서 목록
            ├── editor.lua           # nvim-surround, auto-save, treesitter-context, flash.nvim, vim-abolish, snacks.nvim, im-select
            ├── lint.lua             # markdownlint-cli2 설정
            └── ui.lua               # bufferline, lualine, noice
```

## extraPackages 요약

Nix `extraPackages`로 관리하는 도구 카테고리:

- **LSP**: lua-language-server, nil, vtsls, tailwindcss-language-server, yaml-language-server, vscode-langservers-extracted, markdown-oxide
- **포매터**: prettier, stylua, nixfmt
- **린터**: statix
- **빌드**: tree-sitter, gcc (Linux 전용), nodejs

> `ripgrep`, `fd`, `fzf`는 `libraries/packages.nix`에서, `lazygit`은 Home Manager (`programs.lazygit.enable = true`)로 설치됨 — 중복 추가 금지

## 제약사항

- `programs.neovim`에 `plugins`/`initLua`/`extraConfig` 추가 금지 (심볼릭 링크 충돌)
- DAP 디버깅 미지원 (Mason 비활성화로 js-debug-adapter 미설치)
- `default.nix` 함수 시그니처에 `nixosConfigPath` 명시 필수
- **extraPackages에 C 컴파일러(gcc 등) 추가 시 반드시 `lib.optionals pkgs.stdenv.isLinux` 사용** — macOS에서 LLVM 소스 빌드 방지
- **marksman 사용 금지** → `markdown-oxide` 사용. marksman은 dotnet→Swift 의존성 체인으로 macOS에서 Swift 소스 빌드 실패

## 레퍼런스
- 패키지/extras 상세: [references/packages.md](references/packages.md)
- 키맵/치트시트: [references/cheatsheet.md](references/cheatsheet.md)
- 한국어 입력: [references/korean-input.md](references/korean-input.md)
- 기타 상세: [references/details.md](references/details.md)
- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
