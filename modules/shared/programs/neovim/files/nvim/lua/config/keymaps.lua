-- ============================================================================
-- 커스텀 키맵
-- ============================================================================
-- vim.keymap.set(모드, 키, 동작, 옵션)
--   모드: "n" = Normal, "i" = Insert, "v" = Visual, "t" = Terminal
--   키: 누를 키 조합
--   동작: 실행할 명령 또는 키 시퀀스
--   desc: which-key 팝업에 표시되는 설명
--
-- LazyVim 기본 키맵 (which-key로 Space 누르면 전체 목록 확인 가능):
--   <leader>ff → 파일 찾기 (snacks.picker)
--   <leader>fg → 텍스트 검색 (grep)
--   <leader>e  → 파일 탐색기 (neo-tree) 토글
--   <leader>gg → lazygit 열기
--   H / L      → 이전/다음 버퍼(탭) 전환
--   gd         → 함수/변수 정의로 이동 (Go to Definition)
--   gr         → 참조 목록 (Go to References)
--   K          → 호버 문서 (함수 설명 팝업)
-- ============================================================================

-- Insert 모드에서 "jk"를 빠르게 입력하면 Esc (Normal 모드로 전환)
-- iPad Termius 소프트웨어 키보드에서 Esc 키가 툴바에 있어 누르기 불편하므로,
-- 일반 알파벳 키만으로 모드 전환 가능하게 함
-- 부작용: "j" 입력 후 300ms 동안 "k" 대기 (체감상 짧음)
vim.keymap.set("i", "jk", "<Esc>", { desc = "Esc (모바일 UX)" })

-- Terminal 모드에서 Ctrl+\ → Normal 모드로 탈출
-- Neovim 내장 터미널(:terminal)에서 명령을 실행하다가 Normal 모드로 돌아갈 때 사용
-- 기본 키는 <C-\><C-n> 두 번 눌러야 하는데, 한 번으로 줄임
vim.keymap.set("t", "<C-\\>", "<C-\\><C-n>", { desc = "터미널 Normal 모드" })
