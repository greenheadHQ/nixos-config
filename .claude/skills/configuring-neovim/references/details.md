# Neovim 상세 설정

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
