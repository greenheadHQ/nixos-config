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

  -- ── auto-save.nvim: 자동 저장 ──
  -- 변경 후 일정 시간(debounce) 경과 시 자동 저장
  -- lazygit, fork 등 외부 도구에서 실시간 diff 확인 가능
  {
    "okuuva/auto-save.nvim",
    event = { "InsertLeave", "TextChanged" },
    opts = {
      -- 저장 전 debounce 시간 (ms)
      debounce_delay = 1000,
      -- 저장 조건: 일반 파일 버퍼만
      condition = function(buf)
        local buftype = vim.bo[buf].buftype
        local filetype = vim.bo[buf].filetype
        -- 특수 버퍼 제외
        if buftype ~= "" then return false end
        -- 민감한 파일 제외
        if filetype == "gitcommit" then return false end
        return true
      end,
      noautocmd = false,
    },
  },

  -- ── nvim-treesitter-context: 코드 컨텍스트 상단 고정 ──
  -- 현재 커서가 있는 함수/클래스/조건문의 시작 줄을 상단에 고정 표시
  -- VSCode/Cursor의 sticky scroll과 동일한 기능
  -- <leader>ut 로 토글 가능
  {
    "nvim-treesitter/nvim-treesitter-context",
    event = "VeryLazy",
    opts = {
      max_lines = 3, -- 상단에 표시할 최대 줄 수
    },
  },

  -- ── flash.nvim: 점프/선택 레이블 가독성 개선 ──
  -- backdrop = true: 배경을 어둡게 해서 레이블이 눈에 띄게
  {
    "folke/flash.nvim",
    opts = {
      highlight = {
        backdrop = true,
      },
      modes = {
        -- Ctrl+Space treesitter selection 모드
        treesitter = {
          highlight = {
            backdrop = true,
          },
        },
        -- treesitter_search 모드 (R in o-pending)
        treesitter_search = {
          highlight = {
            backdrop = true,
          },
        },
      },
    },
  },

  -- ── vim-abolish: case 전환 + 약어 ──
  -- 커서가 단어 위에 있을 때 cr{문자}로 case 전환:
  --   crs → snake_case    (fooBar → foo_bar)
  --   crc → camelCase     (foo_bar → fooBar)
  --   crm → PascalCase    (foo_bar → FooBar)
  --   cru → UPPER_CASE    (fooBar → FOO_BAR)
  --   cr- → kebab-case    (fooBar → foo-bar)
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
        -- Tab/Shift+Tab: 순수 이동 (기본 select_and_next/prev → list_down/up)
        -- Space: 선택 토글 (normal 모드만 — insert에서 공백 입력 유지)
        actions = {
          toggle_select = function(picker)
            picker.list:select()
          end,
        },
        win = {
          input = {
            keys = {
              ["<Tab>"] = { "list_down", mode = { "i", "n" } },
              ["<S-Tab>"] = { "list_up", mode = { "i", "n" } },
              ["<Space>"] = { "toggle_select", mode = { "n" } },
            },
          },
          list = {
            keys = {
              ["<Tab>"] = { "list_down", mode = { "n", "x" } },
              ["<S-Tab>"] = { "list_up", mode = { "n", "x" } },
              ["<Space>"] = { "toggle_select", mode = { "n", "x" } },
            },
          },
        },
        -- grep: Option+S로 대소문자 구분 토글
        -- rg 기본값은 --smart-case (소문자만 → insensitive, 대문자 포함 → sensitive)
        -- 이 토글은 전부 소문자 쿼리에서 case-sensitive 검색이 필요할 때 사용
        sources = {
          grep = {
            case_sens = false,
            finder = function(opts, ctx)
              local args_extend = { "--case-sensitive" }
              opts.args = vim.iter(opts.args or {}):filter(function(val)
                return not vim.list_contains(args_extend, val)
              end):totable()
              if opts.case_sens then
                opts.args = vim.list_extend(vim.deepcopy(opts.args or {}), args_extend)
              end
              return require("snacks.picker.source.grep").grep(opts, ctx)
            end,
            actions = {
              toggle_live_case_sens = function(picker)
                picker.opts.case_sens = not picker.opts.case_sens
                picker:find()
              end,
            },
            win = {
              input = {
                keys = {
                  ["<M-s>"] = { "toggle_live_case_sens", mode = { "i", "n" } },
                },
              },
            },
          },
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
