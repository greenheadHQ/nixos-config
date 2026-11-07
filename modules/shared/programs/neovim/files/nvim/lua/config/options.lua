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
-- 여기서 다시 켜므로 tmux 밖 SSH용 provider는 아래 g:clipboard가 정한다.
opt.clipboard = "unnamedplus"

-- 클립보드 provider: 환경마다 어디로 복사되는가
-- - macOS: pbcopy. SSH로 Mac에 들어온 세션도 같다.
-- - tmux 안: nvim 내장 tmux provider가 tmux load-buffer -w로 tmux 버퍼를 채우고 바깥
--   터미널 클립보드에도 보낸다. 바깥 클립보드에 실제로 닿는지는 실제 세션 확인 대상이다.
--   p는 먼저 tmux refresh-client -l로 바깥 터미널에 클립보드를 요청하므로 Ghostty 허용
--   창이 뜰 수 있다. tmux 플러그인은 거치지 않는다.
-- - tmux 밖 SSH(Linux): 복사는 OSC 52로 SSH 클라이언트 터미널(Mac Ghostty)의 클립보드에 보낸다.
--   'clipboard'가 설정돼 있으면 nvim이 OSC 52를 자동 선택하지 않으므로 g:clipboard로 지정한다.
--   붙여넣기(p)는 터미널에 클립보드를 묻지 않고 이 nvim에서 마지막으로 복사한 내용을 쓴다.
--   묻는 방식은 p마다 Ghostty 허용 창이 뜨고, 응답이 없는 터미널에서는 최대 10초 기다린다.
--   복사 내용은 nvim 인스턴스마다 따로라 다른 nvim에서 복사한 것은 p로 받지 못한다.
--   Mac이나 다른 nvim에서 복사한 텍스트는 터미널 붙여넣기(Cmd+V)로 넣는다.
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

  -- 이 nvim에서 아직 복사하지 않았으면 레지스터 0(ShaDa가 되살린 마지막 yank)을 쓴다.
  -- copy가 받는 형식에 맞춰 regtype은 한 글자(v/V/b)로 줄이고, V·b는 끝에 빈 줄을 붙인다.
  -- 폭이 붙은 blockwise regtype("\0222")을 돌려주면 nvim이 잘못된 값으로 거부한다.
  local function last_yank()
    local lines = vim.fn.getreg("0", 1, true)
    if #lines == 0 then
      return {}
    end
    local regtype = ({ v = "v", V = "V", ["\022"] = "b" })[vim.fn.getregtype("0"):sub(1, 1)] or "v"
    if regtype ~= "v" then
      table.insert(lines, "")
    end
    return { lines, regtype }
  end

  -- "+"와 "*"는 각자 복사한 내용이 있으면 각자 쓰고, 한쪽만 있으면 그쪽을 쓴다.
  local function paste(reg)
    local other = reg == "+" and "*" or "+"
    return function()
      return last_copy[reg] or last_copy[other] or last_yank()
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
