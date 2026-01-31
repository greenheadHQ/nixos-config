-- ============================================================================
-- 편집 관련 플러그인 설정
-- ============================================================================
return {
  -- ── nvim-surround: 텍스트 감싸기/변경/삭제 ──
  -- 사용 예시:
  --   ysiw" → 단어를 "따옴표"로 감싸기 (you surround inner word ")
  --   cs"'  → "따옴표"를 '작은따옴표'로 변경 (change surround " to ')
  --   ds"   → "따옴표" 삭제 (delete surround ")
  --   ysa"} → "text" → {"text"} (add surround around " with })
  {
    "kylechui/nvim-surround",
    -- version = "*": 최신 안정 릴리스 태그 사용 (vs false: 최신 커밋)
    version = "*",
    -- event = "VeryLazy": nvim 시작 직후가 아니라 첫 키 입력 이후에 로드
    -- 시작 속도에 영향을 주지 않으면서, 필요할 때 바로 사용 가능
    event = "VeryLazy",
    -- opts = {}: 기본 설정 그대로 사용 (setup() 호출만 하면 됨)
    opts = {},
  },

  -- ── neo-tree: 왼쪽 파일 탐색기 (VS Code의 Explorer 패널과 유사) ──
  -- <leader>e 로 열기/닫기. 파일 생성(a), 삭제(d), 이름 변경(r) 등 지원
  {
    "nvim-neo-tree/neo-tree.nvim",
    opts = {
      window = {
        -- width: 파일 탐색기의 가로 너비 (칸 수)
        -- 함수로 지정하면 화면 크기에 따라 동적으로 계산됨
        -- 화면의 25%를 차지하되, 최소 30칸은 보장 (파일명이 잘리지 않도록)
        width = function()
          return math.max(30, math.floor(vim.o.columns * 0.25))
        end,
      },
      filesystem = {
        filtered_items = {
          -- visible = true: 숨김 파일도 목록에 표시 (흐릿하게)
          -- false면 .으로 시작하는 파일이 완전히 숨겨짐
          visible = true,
          -- .gitignore, .env, .config 등 dotfile을 숨기지 않음
          hide_dotfiles = false,
          -- .gitignore에 등록된 파일(node_modules 등)도 숨기지 않음
          hide_gitignored = false,
        },
      },
    },
  },

  -- ── telescope: 퍼지 검색 (VS Code의 Cmd+P / Cmd+Shift+F와 유사) ──
  -- <leader>ff = 파일 이름으로 검색
  -- <leader>fg = 파일 내용(텍스트)으로 검색 (ripgrep 사용)
  -- <leader>fb = 열린 버퍼 목록에서 검색
  {
    "nvim-telescope/telescope.nvim",
    opts = {
      defaults = {
        -- layout_strategy = "flex": 화면 크기에 따라 자동으로 레이아웃 전환
        -- 넓은 화면 → 가로 배치 (왼쪽: 검색 결과, 오른쪽: 미리보기)
        -- 좁은 화면 → 세로 배치 (위: 검색 결과, 아래: 미리보기)
        layout_strategy = "flex",
        layout_config = {
          flex = {
            -- flip_columns: 이 칸 수 미만이면 세로 레이아웃으로 전환
            -- 100 미만 (iPad 등) → 세로 배치
            flip_columns = 100,
          },
          horizontal = {
            -- preview_cutoff: 이 칸 수 미만이면 미리보기 패널 숨김
            -- 좁은 화면에서 미리보기가 검색 결과를 가리지 않도록
            preview_cutoff = 100,
          },
          vertical = {
            -- 세로 레이아웃에서의 미리보기 최소 높이 기준
            preview_cutoff = 20,
          },
        },
      },
    },
  },
}
