-- ============================================================================
-- 한국어 입력 지원
-- ============================================================================
-- 문제: 외부 앱에서 Neovim으로 돌아왔을 때 한글 IM 활성 상태로
--       Normal 모드 플러그인 키맵(<leader>ff 등)이 동작하지 않음
-- 해결: langmapper.nvim이 vim.keymap.set()을 래핑하여
--       모든 플러그인 키맵의 한글 등가를 자동 등록
-- 예: <leader>ff 등록 시 → <leader>ㄹㄹ도 함께 등록됨
-- NOTE: Vim 내장 명령(dd, yy, w 등)은 FocusGained가 영문 전환으로 처리 (autocmds.lua)
-- ============================================================================
return {
  {
    "Wansmer/langmapper.nvim",
    -- macOS에서만 로드 (NixOS에서는 한글 IME 설정이 다르므로 불필요한 오버헤드 방지)
    cond = vim.fn.executable("macism") == 1,
    lazy = false,
    -- LazyVim 코어(priority=50)보다 먼저 로드하여 vim.keymap.set 래핑이
    -- 모든 플러그인의 키맵 등록보다 앞서 적용되게 함
    priority = 10000,
    opts = {
      -- vim.keymap.set을 래핑: 이후 등록되는 모든 키맵에 한글 등가 자동 추가
      hack_keymap = true,
      -- Insert 모드에서는 래핑 비활성화 (한글 텍스트 입력 방해 방지)
      disable_hack_modes = { "i" },
      -- 한글 레이아웃만 활성화 (기본 설정에 러시아어가 포함되어 있어 명시 필요)
      use_layouts = { "ko" },
      -- 한글 2벌식 레이아웃 정의
      layouts = {
        ko = {
          -- macOS 한글 2벌식 입력소스 ID
          id = "com.apple.inputmethod.Korean.2SetKorean",
          -- default_layout과 1:1 대응하는 69자 한글 레이아웃 (QWERTY 물리 키 순서)
          -- default_layout: ~QWERTYUIOP{}|ASDFGHJKL:"ZXCVBNM<>?`qwertyuiop[]asdfghjkl;'zxcvbnm,./
          -- 구조: [Shift 35자: ~ Shift+QWERTY행 + Shift+특수키] [Unshift 34자: ` qwerty행 + 특수키]
          -- stylua: ignore
          layout = [[~ㅃㅉㄸㄲㅆㅛㅕㅑㅒㅖ{}|ㅁㄴㅇㄹㅎㅗㅓㅏㅣ:"ㅋㅌㅊㅍㅠㅜㅡ<>?`ㅂㅈㄷㄱㅅㅛㅕㅑㅐㅔ[]ㅁㄴㅇㄹㅎㅗㅓㅏㅣ;'ㅋㅌㅊㅍㅠㅜㅡ,./]],
        },
      },
    },
  },
}
