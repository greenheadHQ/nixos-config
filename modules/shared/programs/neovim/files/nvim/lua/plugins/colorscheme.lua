-- ============================================================================
-- 컬러스킴 (테마) 설정
-- ============================================================================
-- Catppuccin = 파스텔 톤의 인기 컬러 테마 (VS Code, iTerm, tmux 등에도 있음)
-- 4가지 맛(flavour): Latte(밝은), Frappe(중간), Macchiato(어두운), Mocha(가장 어두운)
-- ============================================================================
return {
  {
    -- "catppuccin/nvim" = GitHub 저장소 주소 (catppuccin 조직의 nvim 플러그인)
    -- lazy.nvim이 이 주소에서 플러그인을 자동 다운로드함
    "catppuccin/nvim",

    -- name: lazy.nvim 내부에서 이 플러그인을 식별하는 이름
    -- 기본값은 repo명("nvim")이지만, 다른 플러그인과 겹칠 수 있으므로 명시적으로 지정
    name = "catppuccin",

    -- lazy, priority는 설정하지 않음:
    -- lazy.lua에서 LazyVim opts에 colorscheme = "catppuccin"을 지정했으므로
    -- LazyVim이 자동으로 이 플러그인을 최우선 로드함

    -- opts: 플러그인의 setup() 함수에 전달되는 설정 테이블
    -- 즉, require("catppuccin").setup(opts) 와 동일
    opts = {
      -- flavour: 테마의 밝기/분위기 선택
      -- "mocha" = 가장 어두운 변종 (다크 테마)
      flavour = "mocha",

      -- integrations: 다른 플러그인들과의 색상 통합 설정
      -- true로 설정하면 해당 플러그인의 UI 요소에 Catppuccin 색상이 적용됨
      -- false면 해당 플러그인은 자체 기본 색상을 사용
      integrations = {
        -- cmp (nvim-cmp): 자동완성 팝업 메뉴에 Catppuccin 색상 적용
        -- 코드 작성 중 나타나는 제안 목록의 배경, 텍스트, 아이콘 색상
        cmp = true,

        -- gitsigns: 줄번호 왼쪽에 표시되는 git 변경 표시에 Catppuccin 색상 적용
        -- 초록(추가), 파랑(수정), 빨강(삭제) 등의 색상이 테마와 조화됨
        gitsigns = true,

        -- neotree (neo-tree): 왼쪽 파일 탐색기에 Catppuccin 색상 적용
        -- 폴더 아이콘, 파일명, 선택 하이라이트 등
        neotree = true,

        -- treesitter: 코드 구문 강조(syntax highlighting)에 Catppuccin 색상 적용
        -- 함수명, 변수명, 키워드, 문자열 등의 색상
        -- treesitter = 코드를 파싱해서 의미 단위로 색칠하는 도구 (정규식 기반보다 정확)
        treesitter = true,

        -- telescope: 파일/텍스트 검색 팝업(fuzzy finder)에 Catppuccin 색상 적용
        -- <leader>ff 등으로 열리는 검색 창의 배경, 테두리, 선택 하이라이트
        telescope = { enabled = true },

        -- which-key: Space 키 누르면 나타나는 키맵 도움말 팝업에 Catppuccin 색상 적용
        which_key = true,

        -- indent-blankline: 들여쓰기 가이드 라인(세로 점선)에 Catppuccin 색상 적용
        -- 코드 블록의 깊이를 시각적으로 구분하는 세로선
        indent_blankline = { enabled = true },

        -- native_lsp: Neovim 내장 LSP 클라이언트의 진단 표시에 Catppuccin 색상 적용
        -- LSP = Language Server Protocol (VS Code가 IntelliSense를 제공하는 것과 같은 기술)
        native_lsp = {
          enabled = true,
          -- underlines: 코드의 에러/경고/힌트/정보를 밑줄 스타일로 표시
          underlines = {
            -- "undercurl" = 물결 모양 밑줄 (직선 밑줄보다 눈에 잘 띔)
            -- 터미널이 undercurl을 지원하지 않으면 자동으로 일반 밑줄로 대체됨
            errors = { "undercurl" }, -- 빨간 물결선 (에러)
            hints = { "undercurl" }, -- 회색 물결선 (힌트)
            warnings = { "undercurl" }, -- 노란 물결선 (경고)
            information = { "undercurl" }, -- 파란 물결선 (정보)
          },
        },

        -- mini: mini.nvim 플러그인 모음에 Catppuccin 색상 적용
        -- LazyVim이 mini.indentscope(활성 블록 강조), mini.ai(텍스트 오브젝트) 등을 사용
        mini = { enabled = true },
      },
    },
  },
}
