-- ============================================================================
-- Vim 옵션 설정
-- ============================================================================
-- LazyVim이 이미 설정하는 옵션 (number, relativenumber, termguicolors,
-- expandtab, smartindent, shiftwidth=2, tabstop=2, wrap=false 등)은
-- 여기서 재설정하지 않음. 여기서는 LazyVim 기본값과 다른 옵션만 설정.
--
-- LazyVim 기본 옵션 전체 목록: https://www.lazyvim.org/configuration/general
-- vim.opt = Vim의 :set 명령과 동일 (예: vim.opt.wrap = false ↔ :set nowrap)
-- ============================================================================
local opt = vim.opt

-- 클립보드: yank(복사)/delete(삭제) 시 시스템 클립보드와 자동 동기화
-- "unnamedplus" = Cmd+V로 붙여넣을 수 있고, 외부에서 복사한 텍스트를 p로 붙여넣기 가능
-- NOTE: LazyVim은 SSH에서 클립보드를 비활성화하지만(느려짐 방지),
-- tmux-yank이 클립보드를 처리하므로 항상 활성화
opt.clipboard = "unnamedplus"

-- 자동 들여쓰기 시 기존 줄의 들여쓰기 문자(탭/스페이스)를 그대로 복사
opt.copyindent = true

-- 커서 위아래로 항상 8줄의 여백을 유지 (스크롤 시 맥락을 잃지 않도록)
-- 예: 커서가 화면 맨 아래에서 8줄 위에 도달하면 자동으로 스크롤됨
-- (LazyVim 기본값은 4줄, 8줄로 늘려서 더 넓은 맥락 유지)
opt.scrolloff = 8

-- 맞춤법 검사 비활성화 (LazyVim lang.markdown이 활성화하지만 한글에서 노이즈만 발생)
opt.spell = false
