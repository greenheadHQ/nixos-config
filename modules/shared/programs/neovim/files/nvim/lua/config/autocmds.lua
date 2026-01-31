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
