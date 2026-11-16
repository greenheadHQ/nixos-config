-- ============================================================================
-- 비활성화할 플러그인
-- ============================================================================
-- Mason = LSP 서버, 포매터, 린터를 자동 다운로드/관리하는 플러그인
-- 우리는 Nix extraPackages로 이 도구들을 관리하므로 Mason이 불필요함
-- Mason을 끄지 않으면: Mason이 자체 다운로드한 도구와 Nix가 설치한 도구가 충돌할 수 있음
--
-- Mason의 현재 공식 저장소는 mason-org 아래에 있음
-- lazy.nvim은 기본적으로 repo 이름을 식별자로 병합하므로 owner 변경만으로
-- 비활성화가 실패하지는 않음. 저장소 주소는 현재 upstream과 맞춰 유지
-- ============================================================================
return {
  -- mason.nvim: LSP/포매터/린터 패키지 매니저 UI (:Mason 명령)
  { "mason-org/mason.nvim", enabled = false },

  -- mason-lspconfig: Mason이 설치한 LSP 서버를 nvim-lspconfig에 자동 연결
  -- Mason을 껐으므로 이것도 불필요
  { "mason-org/mason-lspconfig.nvim", enabled = false },

  -- mason-nvim-dap: Mason이 DAP 어댑터를 설치/연결 (dap.core extra가 가져옴)
  -- js-debug는 Nix extraPackages로 제공하므로 Mason 경로 비활성화
  -- (core.lua의 LazyVim.has("mason-nvim-dap.nvim") 체크가 자연히 skip됨)
  { "jay-babu/mason-nvim-dap.nvim", enabled = false },

  -- mini.surround: LazyVim 기본 surround 플러그인 (키맵: gza, gzd, gzr)
  -- nvim-surround (editor.lua)을 대신 사용하므로 비활성화 (키맵: ys, ds, cs — 더 표준적)
  -- NOTE: mini.nvim 0.17.0 (2025-12)에서 echasnovski → nvim-mini 조직으로 이전됨
  { "nvim-mini/mini.surround", enabled = false },

  -- tokyonight: LazyVim 기본 테마이지만, catppuccin을 사용하므로 불필요
  { "folke/tokyonight.nvim", enabled = false },

  -- indent-blankline: snacks.indent로 대체됨 (LazyVim v14+)
  { "lukas-reineke/indent-blankline.nvim", enabled = false },

  -- neo-tree: snacks.explorer로 대체됨 (LazyVim v14+)
  -- hijack_netrw_behavior가 `nvim .` 시 메인 영역에 트리를 표시하므로 비활성화
  { "nvim-neo-tree/neo-tree.nvim", enabled = false },
}
