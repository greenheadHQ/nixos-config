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
-- "unnamedplus" = y가 곧 시스템 클립보드 복사. SSH에서도 이 사용감을 유지한다.
-- NOTE: LazyVim은 SSH에서 이 값을 비워 nvim이 OSC 52를 자동 선택하게 하지만,
-- 여기서 다시 켜므로 SSH용 provider는 아래 g:clipboard가 정한다.
opt.clipboard = "unnamedplus"

-- 클립보드 provider: 환경마다 어디로 복사되는가
-- - macOS: pbcopy. SSH로 Mac에 들어온 세션도 같다.
-- - tmux 안: nvim 내장 tmux provider(tmux load-buffer -w)가 tmux 버퍼와 바깥 터미널
--   클립보드를 함께 채운다. tmux 플러그인은 거치지 않는다.
-- - tmux 밖 SSH(Linux): 복사는 OSC 52로 SSH 클라이언트 터미널(Mac Ghostty)의 클립보드에 보낸다.
--   'clipboard'가 설정돼 있으면 nvim이 OSC 52를 자동 선택하지 않으므로 g:clipboard로 지정한다.
--   붙여넣기(p)는 터미널에 클립보드를 묻지 않고 이 nvim에서 마지막으로 복사한 내용을 쓴다.
--   묻는 방식은 p마다 Ghostty 허용 창이 뜨고, 응답이 없는 터미널에서는 최대 10초 기다린다.
--   Mac에서 복사한 텍스트는 터미널 붙여넣기(Cmd+V)로 넣는다.
-- g:clipboard는 provider 초기화(has('clipboard')) 전에 정해야 한다 (:help g:clipboard).
local function env_set(name)
  local value = vim.env[name]
  return value ~= nil and value ~= ""
end

if vim.fn.has("mac") == 0 and (env_set("SSH_CONNECTION") or env_set("SSH_TTY")) and not env_set("TMUX") then
  local osc52 = require("vim.ui.clipboard.osc52")
  local last_copy = {} -- 레지스터("+"/"*")별 { lines, regtype }

  local function copy(reg)
    local send = osc52.copy(reg)
    return function(lines, regtype)
      last_copy[reg] = { lines, regtype }
      send(lines)
    end
  end

  local function paste(reg)
    return function()
      return last_copy[reg] or {}
    end
  end

  vim.g.clipboard = {
    name = "OSC 52 (copy only)",
    copy = { ["+"] = copy("+"), ["*"] = copy("*") },
    paste = { ["+"] = paste("+"), ["*"] = paste("*") },
  }
end

-- 자동 들여쓰기 시 기존 줄의 들여쓰기 문자(탭/스페이스)를 그대로 복사
opt.copyindent = true

-- 커서 위아래로 항상 8줄의 여백을 유지 (스크롤 시 맥락을 잃지 않도록)
-- 예: 커서가 화면 맨 아래에서 8줄 위에 도달하면 자동으로 스크롤됨
-- (LazyVim 기본값은 4줄, 8줄로 늘려서 더 넓은 맥락 유지)
opt.scrolloff = 8

-- 맞춤법 검사 비활성화 (LazyVim lang.markdown이 활성화하지만 한글에서 노이즈만 발생)
opt.spell = false
