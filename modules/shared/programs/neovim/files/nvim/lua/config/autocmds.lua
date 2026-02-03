-- ============================================================================
-- 자동 명령 (autocmd)
-- ============================================================================
-- autocmd = 특정 이벤트가 발생할 때 자동으로 실행되는 함수
-- 예: 파일 저장 시, 창 크기 변경 시, Neovim 시작 시 등
--
-- augroup = autocmd들을 묶는 그룹. clear=true로 중복 등록을 방지
-- ============================================================================

-- 모바일 화면 최적화: 터미널 폭에 따라 UI를 자동 조정
local function adjust_for_width()
  -- vim.o.columns = 현재 터미널의 가로 칸 수 (예: 80, 120, 200...)
  local columns = vim.o.columns

  if columns < 100 then
    -- ── 좁은 화면 (iPad portrait, 작은 tmux pane 등) ──

    -- 상대 줄번호 끄기 → 줄번호 표시 영역이 좁아져서 코드 공간 확보
    -- (절대 줄번호는 LazyVim이 켜둔 상태로 유지됨)
    vim.opt.relativenumber = false

    -- 줄 바꿈 켜기 → 긴 줄이 다음 줄로 내려감 (수평 스크롤 불필요)
    vim.opt.wrap = true

    -- 단어 단위로 줄 바꿈 (단어 중간에서 끊기지 않음)
    vim.opt.linebreak = true

    -- signcolumn = 줄번호 왼쪽의 기호 열 (에러 표시, git 변경 표시 등)
    -- "yes:1" = 항상 1칸만 표시 (공간 절약)
    vim.opt.signcolumn = "yes:1"

    -- foldcolumn = 코드 접기(fold) 표시 열. "0" = 숨김 (공간 절약)
    vim.opt.foldcolumn = "0"
  else
    -- ── 넓은 화면 (데스크탑) ──

    vim.opt.relativenumber = true -- 상대 줄번호 표시 (5j, 10k 등 이동에 유용)
    vim.opt.wrap = false -- 줄 바꿈 끄기 (긴 줄은 수평 스크롤)
    vim.opt.linebreak = false
    vim.opt.signcolumn = "yes" -- 기호 열 기본 표시
    vim.opt.foldcolumn = "auto" -- 접기 열 자동 표시
  end
end

vim.api.nvim_create_autocmd(
  -- VimResized = 터미널 크기가 변경될 때마다 실행
  -- NOTE: VimEnter는 사용하지 않음. LazyVim은 이 파일을 VeryLazy 이벤트(VimEnter 이후)에
  -- 로드하므로, VimEnter를 등록해도 이미 이벤트가 지나간 뒤라 실행되지 않음.
  { "VimResized" },
  {
    group = vim.api.nvim_create_augroup("mobile_layout", { clear = true }),
    callback = adjust_for_width,
  }
)

-- 이 파일이 로드되는 시점(VeryLazy)에 즉시 한 번 실행하여 초기 레이아웃 설정
adjust_for_width()

-- ── Markdown: 맞춤법 검사 비활성화 ──
-- LazyVim lang.markdown extra가 spell을 활성화하지만, 한글에서는 노이즈만 발생
-- vim.schedule: LazyVim autocmd보다 나중에 실행되도록 지연
vim.api.nvim_create_autocmd("FileType", {
  group = vim.api.nvim_create_augroup("markdown_spell_off", { clear = true }),
  pattern = { "markdown", "markdown.mdx" },
  callback = function()
    vim.schedule(function()
      vim.opt_local.spell = false
    end)
  end,
})

-- ── FocusGained: 외부 앱에서 돌아올 때 영문 IM 전환 (macOS) ──
-- Vim 내장 명령(dd, yy, w, gj 등)은 한글 키맵 등가를 만들 수 없으므로
-- 포커스 복귀 시 영문으로 전환하여 내장 명령이 정상 동작하게 함
-- 플러그인 키맵(<leader>ff 등)은 langmapper.nvim이 별도 처리 (plugins/korean.lua)
-- macism이 없는 환경(NixOS, SSH)에서는 자동으로 건너뜀
if vim.fn.executable("macism") == 1 then
  vim.api.nvim_create_autocmd("FocusGained", {
    group = vim.api.nvim_create_augroup("korean_im_focus", { clear = true }),
    callback = function()
      -- Normal 계열(Normal, Operator-pending, Insert-Normal, Terminal-Normal)과
      -- Visual 계열(Visual, Visual Line, Visual Block) 모드일 때만 전환
      -- Insert, Command-line, Terminal 모드에서는 사용자의 한글 입력 의도를 존중
      local mode = vim.api.nvim_get_mode().mode
      if mode:find("^n") or mode == "v" or mode == "V" or mode:find("^\22") then
        vim.fn.jobstart({ "macism", "com.apple.keylayout.ABC" })
      end
    end,
  })
end
