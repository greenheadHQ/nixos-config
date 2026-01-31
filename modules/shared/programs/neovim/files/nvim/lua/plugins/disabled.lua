-- ============================================================================
-- 비활성화할 플러그인
-- ============================================================================
-- Mason = LSP 서버, 포매터, 린터를 자동 다운로드/관리하는 플러그인
-- 우리는 Nix extraPackages로 이 도구들을 관리하므로 Mason이 불필요함
-- Mason을 끄지 않으면: Mason이 자체 다운로드한 도구와 Nix가 설치한 도구가 충돌할 수 있음
--
-- WARNING: Mason 프로젝트가 "williamboman" → "mason-org"로 이전됨
-- lazy.nvim은 "owner/repo" 문자열로 플러그인을 매칭하므로,
-- "williamboman/mason.nvim"으로 쓰면 매칭 실패 → Mason이 계속 활성화됨!
-- ============================================================================
return {
  -- mason.nvim: LSP/포매터/린터 패키지 매니저 UI (:Mason 명령)
  { "mason-org/mason.nvim", enabled = false },

  -- mason-lspconfig: Mason이 설치한 LSP 서버를 nvim-lspconfig에 자동 연결
  -- Mason을 껐으므로 이것도 불필요
  { "mason-org/mason-lspconfig.nvim", enabled = false },

  -- mini.surround: LazyVim 기본 surround 플러그인 (키맵: gza, gzd, gzr)
  -- nvim-surround (editor.lua)을 대신 사용하므로 비활성화 (키맵: ys, ds, cs — 더 표준적)
  { "echasnovski/mini.surround", enabled = false },
}
