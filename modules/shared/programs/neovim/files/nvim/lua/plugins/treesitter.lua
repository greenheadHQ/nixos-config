-- ============================================================================
-- Tree-sitter 설정
-- ============================================================================
-- Tree-sitter = 코드를 AST(추상 구문 트리)로 파싱하는 도구
-- 전통적 정규식 기반 구문 강조보다 훨씬 정확하고 빠름
--
-- 각 언어별로 "파서(parser)"를 설치해야 함:
--   파서 = 해당 언어의 문법을 이해하는 C 라이브러리 (첫 실행 시 gcc로 컴파일됨)
--
-- Tree-sitter가 제공하는 기능:
--   - 구문 강조 (키워드, 함수, 변수 등에 정확한 색상)
--   - 코드 접기 (함수/블록 단위로 접기)
--   - 텍스트 오브젝트 (vaf = 함수 전체 선택, vii = 조건문 내부 선택 등)
--   - 들여쓰기 자동 계산
-- ============================================================================
return {
  {
    "nvim-treesitter/nvim-treesitter",
    opts = {
      -- ensure_installed: nvim 첫 실행 시 자동으로 설치할 파서 목록
      -- 없는 파서는 해당 파일을 열 때 자동 설치됨 (ensure_installed는 사전 설치)
      -- NOTE: LazyVim extras가 이미 설치하는 파서도 포함 (한눈에 보기 위한 전체 목록)
      ensure_installed = {
        -- 웹 개발
        "javascript", -- .js 파일
        "typescript", -- .ts 파일
        "tsx", -- .tsx 파일 (React JSX + TypeScript)
        "html", -- .html 파일
        "css", -- .css 파일
        "scss", -- .scss 파일 (Sass)

        -- 데이터 형식
        "json", -- .json 파일 (엄격한 JSON)
        "jsonc", -- .jsonc 파일 (주석 허용 JSON, tsconfig.json 등)
        "yaml", -- .yaml/.yml 파일

        -- 설정 언어
        "nix", -- .nix 파일 (이 프로젝트의 주요 언어)
        "lua", -- .lua 파일 (Neovim 설정 언어)
        "bash", -- .sh 파일

        -- 문서
        "markdown", -- .md 파일
        "markdown_inline", -- 마크다운 내 인라인 코드 블록

        -- Neovim 내부
        "vim", -- Vimscript (:set 등 레거시 설정)
        "vimdoc", -- Neovim 도움말 파일 (:help)
        "regex", -- 정규 표현식 하이라이트
        "query", -- Tree-sitter 쿼리 파일 (.scm)

        -- Git
        "diff", -- git diff 출력
        "gitcommit", -- 커밋 메시지
        "git_rebase", -- git rebase -i 화면
      },
    },
  },
}
