-- ============================================================================
-- lazy.nvim 부트스트랩 + LazyVim 설정
-- ============================================================================
-- lazy.nvim = Neovim 플러그인 매니저 (npm/pnpm 같은 역할)
-- LazyVim = lazy.nvim 위에 구축된 "Neovim 배포판" (CRA/Next.js 같은 역할)
--   → 수십 개의 플러그인을 미리 조합해서 IDE처럼 동작하게 만들어 둔 것
-- ============================================================================

-- lazy.nvim이 아직 설치되지 않았으면 GitHub에서 자동 다운로드
-- stdpath("data") = ~/.local/share/nvim (Neovim 데이터 디렉토리)
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", lazyrepo, lazypath })
  if vim.v.shell_error ~= 0 then
    vim.api.nvim_echo({
      { "Failed to clone lazy.nvim:\n", "ErrorMsg" },
      { out, "WarningMsg" },
      { "\nPress any key to exit..." },
    }, true, {})
    vim.fn.getchar()
    os.exit(1)
  end
end
-- rtp(runtimepath) = Neovim이 설정/플러그인을 찾는 디렉토리 목록
-- prepend = 목록 맨 앞에 추가 → lazy.nvim이 다른 플러그인보다 먼저 로드됨
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  -- ── spec: 어떤 플러그인을 설치할지 정의 ──
  spec = {
    -- LazyVim 코어: 기본 플러그인 세트 (telescope, treesitter, lsp, cmp 등)를 한번에 가져옴
    -- colorscheme: LazyVim에게 catppuccin을 테마로 사용하라고 지정 (기본값은 tokyonight)
    -- 이 설정이 없으면 colorscheme.lua에서 catppuccin을 설치해도 tokyonight가 적용됨
    { "LazyVim/LazyVim", import = "lazyvim.plugins", opts = { colorscheme = "catppuccin" } },

    -- LazyVim extras: 특정 언어/도구 지원을 선택적으로 활성화
    -- 각 extra는 해당 언어의 LSP, 포매터, 린터, treesitter 파서 등을 자동 설정함
    { import = "lazyvim.plugins.extras.lang.typescript" }, -- vtsls (TS/JS LSP) + TS 전용 도구
    { import = "lazyvim.plugins.extras.lang.nix" }, -- nil (Nix LSP) + nixfmt + statix
    { import = "lazyvim.plugins.extras.lang.json" }, -- jsonls (JSON LSP) + schemastore
    { import = "lazyvim.plugins.extras.lang.yaml" }, -- yamlls (YAML LSP) + schemastore
    { import = "lazyvim.plugins.extras.lang.markdown" }, -- marksman (Markdown LSP) + 미리보기
    { import = "lazyvim.plugins.extras.lang.tailwind" }, -- tailwindcss LSP + 색상 미리보기
    { import = "lazyvim.plugins.extras.linting.eslint" }, -- ESLint를 LSP로 동작시킴
    { import = "lazyvim.plugins.extras.formatting.prettier" }, -- prettier 저장 시 자동 포맷

    -- 커스텀 플러그인: lua/plugins/ 디렉토리의 모든 .lua 파일을 자동 로드
    { import = "plugins" },
  },

  -- ── defaults: 플러그인 기본 동작 설정 ──
  defaults = {
    -- lazy = false → 모든 플러그인을 nvim 시작 시 즉시 로드 (true면 필요할 때만 로드)
    lazy = false,
    -- version = false → 항상 최신 커밋 사용 (true면 안정 릴리스 태그만 사용)
    version = false,
  },

  -- ── checker: 플러그인 업데이트 확인 ──
  checker = {
    enabled = true, -- 백그라운드에서 새 버전 있는지 주기적으로 확인
    notify = false, -- 새 버전이 있어도 알림 팝업을 띄우지 않음 (MiniPC 등 서버 환경)
  },

  -- ── performance: 시작 속도 최적화 ──
  performance = {
    rtp = {
      -- Neovim에 기본 내장된 플러그인 중 사용하지 않는 것들을 비활성화
      disabled_plugins = {
        "gzip", -- .gz 파일 읽기 (거의 사용 안 함)
        "tarPlugin", -- .tar 파일 읽기
        "tohtml", -- 버퍼를 HTML로 변환
        "tutor", -- Neovim 튜토리얼 (:Tutor)
        "zipPlugin", -- .zip 파일 읽기
      },
    },
  },
})
