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
- 100컬럼 미만: `autocmds.lua`에서 `relativenumber=false`, `wrap=true` 등으로 폭 기반 UI 조정
- snacks.picker 레이아웃: `editor.lua`에서 100컬럼 미만은 `vertical`, 그 이상은 `default` preset으로 전환

## 클립보드 전략

`clipboard = "unnamedplus"`는 SSH에서도 켠다(`y` = 시스템 클립보드). provider는 `lua/config/options.lua`가 환경별로 정한다.

| 환경 | provider | `y` | `p` |
|------|----------|-----|-----|
| macOS (SSH로 들어온 세션 포함) | pbcopy | Mac 클립보드 | Mac 클립보드 |
| SSH + tmux 안 | nvim 내장 tmux | tmux 버퍼 (`tmux load-buffer -w`). 바깥 터미널 클립보드에 닿는지는 실제 세션 확인 대상(#1453 L2) | tmux 버퍼. 먼저 `tmux refresh-client -l`로 바깥 터미널에 클립보드를 요청하므로 Ghostty 허용 창이 뜰 수 있다 |
| SSH + tmux 밖 (Linux) | `g:clipboard` `OSC 52 (copy only)` | OSC 52로 SSH 클라이언트 터미널의 클립보드 | 이 nvim에서 마지막으로 복사한 내용 |

- SSH 판정은 `SSH_CONNECTION` 또는 `SSH_TTY`, tmux 판정은 `$TMUX`다(빈 값은 없는 것으로 본다). tmux 안에서는 tmux 플러그인을 거치지 않는다.
- tmux 밖 SSH의 `p`는 터미널에 클립보드를 묻지 않는다. 묻게 하면(`g:clipboard = "osc52"`) `p`마다 Ghostty 허용 창이 뜨고, 응답하지 않는 터미널에서는 최대 10초 기다린다. Mac에서 복사한 텍스트는 터미널 붙여넣기(Cmd+V)로 넣는다.
- tmux 밖 SSH의 레지스터: `+`·`*`는 각자 복사한 내용이 있으면 각자, 한쪽만 있으면 그쪽을 쓴다. 이 nvim에서 복사하기 전에는 레지스터 0(ShaDa가 되살린 마지막 yank)을 쓴다. 복사 내용은 nvim 인스턴스마다 따로라 다른 nvim에서 복사한 것은 `p`로 받지 못하므로 Cmd+V로 넣는다.
- 확인: `:checkhealth vim.provider`의 Clipboard 항목
- Termius: OSC 52 미지원 (알려진 Termius 제한)

## 주요 키맵

LazyVim 기본 키맵 (which-key로 탐색):
- `<leader>ff` 파일 찾기 | `<leader>fg` Git 파일 찾기 | `<leader>/` 텍스트 검색 | `<leader>e` snacks.explorer
- `<leader>gg` lazygit | `<leader>cf` 포맷 | `K` hover
- `gd` 정의 | `gr` 참조 | `H`/`L` 이전/다음 버퍼

커스텀 키맵:
- `jk` → Esc (Insert 모드)
- `<C-\>` → 터미널 Normal 모드
