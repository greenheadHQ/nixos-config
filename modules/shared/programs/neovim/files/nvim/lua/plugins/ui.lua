-- ============================================================================
-- UI (사용자 인터페이스) 플러그인 설정
-- ============================================================================
return {
  -- ── bufferline: 상단 버퍼(탭) 바 ──
  -- VS Code의 탭 바와 유사. 열린 파일들을 탭처럼 표시.
  -- H(이전 탭) / L(다음 탭) 으로 전환. <leader>bd 로 닫기.
  {
    "akinsho/bufferline.nvim",
    opts = {
      options = {
        -- max_name_length: 탭에 표시되는 파일명 최대 길이 (20자 초과 시 잘림)
        -- 긴 파일명(예: useAuthenticationContext.tsx)이 탭 바를 독점하지 않도록
        max_name_length = 20,
        -- tab_size: 각 탭의 최소 너비 (18칸)
        tab_size = 18,
        -- 탭 바 오른쪽 끝의 X(닫기) 아이콘 숨김 → 공간 절약
        show_close_icon = false,
        -- 각 탭의 X(닫기) 아이콘 숨김 → 공간 절약 (닫기는 <leader>bd 사용)
        show_buffer_close_icons = false,
      },
    },
  },

  -- ── lualine: 하단 상태 바 ──
  -- 현재 모드(NORMAL/INSERT/VISUAL), 파일명, git 브랜치, 에러 수, 커서 위치 등 표시
  {
    "nvim-lualine/lualine.nvim",
    -- opts를 함수로 전달: LazyVim이 먼저 설정한 opts를 받아서 일부만 수정
    opts = function(_, opts)
      opts.options = vim.tbl_deep_extend("force", opts.options or {}, {
        -- component_separators: 상태 바 내 각 항목 사이의 구분 기호
        -- "" (빈 문자열) = 구분선 없이 깔끔하게 (좁은 화면에서 공간 절약)
        -- 기본값은 "" "" 같은 화살표 모양 (Powerline 폰트 필요)
        component_separators = { left = "", right = "" },
        -- section_separators: 상태 바의 큰 섹션(왼쪽/가운데/오른쪽) 사이 구분 기호
        section_separators = { left = "", right = "" },
      })
    end,
  },

  -- ── indent-blankline: 들여쓰기 가이드 라인 ──
  -- 코드 블록의 깊이를 세로 점선으로 시각적으로 표시
  -- 예: if 블록, 함수 블록의 시작과 끝을 세로선으로 연결
  {
    "lukas-reineke/indent-blankline.nvim",
    -- main = "ibl": v3에서 모듈 이름이 "indent_blankline" → "ibl"로 변경됨
    -- 이 값이 없으면 lazy.nvim이 플러그인명에서 모듈명을 추론 → setup() 호출 실패
    main = "ibl",
    opts = {
      scope = {
        -- show_start = false: 현재 스코프(블록)의 시작 줄에 밑줄 표시하지 않음
        -- true면 현재 커서가 있는 블록의 첫 줄에 밑줄이 그어짐
        show_start = false,
        -- show_end = false: 현재 스코프의 마지막 줄에 밑줄 표시하지 않음
        show_end = false,
      },
    },
  },

  -- ── noice: 명령줄, 메시지, 알림 UI 개선 ──
  -- Neovim의 기본 명령줄(:)과 메시지 표시를 모던한 팝업으로 대체
  -- SSH 환경에서도 안정적으로 동작하도록 보수적으로 설정
  {
    "folke/noice.nvim",
    opts = {
      cmdline = {
        -- view = "cmdline": 명령 입력을 화면 하단에 표시 (기존 Vim 방식)
        -- 기본값("cmdline_popup")은 화면 중앙 팝업인데, SSH에서 깜빡임 발생 가능
        view = "cmdline",
      },
      messages = {
        -- view_search = false: /검색 시 "N/M 결과" 카운트 팝업 비활성화
        -- SSH에서 팝업이 잔상을 남길 수 있으므로 끔
        view_search = false,
      },
      presets = {
        -- bottom_search = true: / 검색을 화면 하단에 표시 (기존 Vim 방식)
        bottom_search = true,
        -- long_message_to_split = true: 긴 메시지는 별도 split 창에 표시
        -- 긴 에러 메시지가 화면을 덮지 않고, 별도 창에서 스크롤 가능
        long_message_to_split = true,
      },
    },
  },
}
