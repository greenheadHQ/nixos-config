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

  -- ── vim-abolish: case 전환 + 약어 ──
  -- 커서가 단어 위에 있을 때 cr{문자}로 case 전환:
  --   crs → snake_case    (fooBar → foo_bar)
  --   crc → camelCase     (foo_bar → fooBar)
  --   crm → MixedCase     (foo_bar → FooBar)
  --   cru → UPPER_CASE    (fooBar → FOO_BAR)
  --   cr- → dash-case     (fooBar → foo-bar)
  --   cr. → dot.case      (fooBar → foo.bar)
  {
    "tpope/vim-abolish",
    event = "VeryLazy",
  },

  -- ── snacks.nvim: 파일 탐색기 + 퍼지 검색 ──
  -- explorer: <leader>e 로 열기/닫기 (snacks.explorer, LazyVim v14+ 기본)
  -- picker: <leader>ff = 파일 이름으로 검색, <leader>fg = Git 파일 찾기, <leader>/ = 텍스트 검색
  {
    "folke/snacks.nvim",
    opts = {
      explorer = {
        -- .env, .config 등 dotfile 표시 (기존 neo-tree hide_dotfiles=false와 동일)
        hidden = true,
        -- node_modules 등 .gitignore 파일도 표시 (기존 neo-tree hide_gitignored=false와 동일)
        ignored = true,
      },
      picker = {
        -- 화면 크기에 따라 레이아웃 자동 전환
        -- 100칸 미만 (iPad 등 좁은 화면) → 세로 배치 (기존 telescope flex와 동일 기준)
        layout = {
          preset = function()
            return vim.o.columns >= 100 and "default" or "vertical"
          end,
        },
      },
    },
  },

  -- ── im-select.nvim: 한영 입력 소스 자동 전환 (macOS) ──
  -- InsertLeave / CmdlineLeave → 영문(ABC)으로 전환 (Vim 키맵 정상 동작)
  -- InsertEnter → 이전 입력 소스 복원 (한글 입력 중이었으면 한글로 복원)
  -- macism이 없는 환경(NixOS, SSH)에서는 조용히 무시됨
  {
    "keaising/im-select.nvim",
    event = "VeryLazy",
    opts = {
      -- macOS 기본 영문 입력 소스
      default_im_select = "com.apple.keylayout.ABC",
      -- macism: macOS 입력 소스 전환 CLI (brew install macism)
      default_command = "macism",
      -- Insert/Command 모드를 벗어날 때 영문으로 전환
      set_default_events = { "InsertLeave", "CmdlineLeave" },
      -- Insert 모드 진입 시 이전 입력 소스 복원
      set_previous_events = { "InsertEnter" },
      -- macism이 없는 환경(NixOS, SSH)에서 에러 알림 억제
      keep_quiet_on_no_binary = true,
      -- 비동기 전환 (UI 블로킹 방지)
      async_switch_im = true,
    },
  },
}
