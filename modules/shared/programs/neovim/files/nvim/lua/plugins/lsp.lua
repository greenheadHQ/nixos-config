-- ============================================================================
-- 추가 LSP 서버 설정
-- ============================================================================
-- LSP (Language Server Protocol):
--   에디터와 언어 서버 사이의 통신 규약. VS Code의 IntelliSense와 같은 원리.
--   자동완성, 에러 표시, 정의로 이동(gd), 참조 찾기(gr), 호버 문서(K) 등을 제공.
--
-- LazyVim extras가 이미 설정하는 LSP 서버:
--   typescript → vtsls, nix → nil, json → jsonls, yaml → yamlls,
--   markdown → marksman, tailwind → tailwindcss-language-server,
--   eslint → vscode-eslint-language-server
--
-- 여기서는 extras가 관리하지 않는 LSP 서버만 추가.
-- 바이너리는 Nix extraPackages의 vscode-langservers-extracted에 포함되어 있음.
-- ============================================================================
return {
  {
    -- nvim-lspconfig: LSP 서버를 쉽게 설정하는 공식 플러그인
    -- LazyVim이 이미 설치했으므로 여기서는 opts만 추가 (기존 설정에 병합됨)
    "neovim/nvim-lspconfig",
    opts = {
      -- servers: LSP 서버별 설정. 키 = 서버 이름, 값 = 설정 테이블
      -- {} (빈 테이블) = 기본 설정으로 활성화 (추가 커스텀 불필요)
      servers = {
        cssls = {}, -- CSS LSP: 자동완성, 색상 미리보기, 선택자 검증
        html = {}, -- HTML LSP: 태그 자동완성, 닫는 태그, 속성 제안
      },
    },
  },
}
