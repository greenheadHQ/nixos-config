# 한국어 입력 지원 (macOS)

외부 앱에서 한글을 쓰다가 Neovim으로 돌아왔을 때 Normal 모드에서 키맵이 동작하지 않는 문제를 2계층으로 방어:

| 레이어 | 도구 | 파일 | 담당 |
|--------|------|------|------|
| 1차 | FocusGained autocmd | `autocmds.lua` | 외부 앱 복귀 시 영문 IM 전환 → 내장/플러그인 명령 정상 동작 |
| 2차 | im-select.nvim | `editor.lua` | Insert↔Normal 전환 시 영문/한글 자동 전환 |

- macOS 전용: `vim.fn.executable("macism") == 1`로 NixOS/SSH 환경에서 자동 비활성화
- macism 설치: `modules/darwin/programs/homebrew.nix`에서 선언적 관리 (`nrs` 시 자동 설치). nixpkgs는 Swift 빌드 실패로 Homebrew 전용
- langmap/langmapper 미사용: 한글 IME 조합(자음+모음→음절) 특성상 extra keystroke 문제 발생. 러시아어(키릴)처럼 1:1 매핑이 되지 않아 실용성 없음

## Insert·명령줄의 Ctrl+n / Ctrl+p

한글 입력소스에서도 자동완성 목록 이동(Ctrl+n/Ctrl+p)이 동작하도록 `keymaps.lua`가 처리한다. 입력소스는 바꾸지 않는다.

- 원인: Neovim은 시작할 때 kitty keyboard protocol을 켠다(`:h tui-csiu`). 이 모드에서 Ghostty는 Ctrl+글자를 현재 입력소스가 그 키로 내는 글자로 보낸다. 한글 두벌식에서 Ctrl+n은 `CSI 12636;5u`(`<C-ㅜ>`), Ctrl+p는 `CSI 12628;5u`(`<C-ㅔ>`)로 도착하고, 매핑이 없으면 'ㅜ'·'ㅔ'가 입력된다.
- 처리: Insert·명령줄 모드에서 `<C-ㅜ>`/`<C-ㅔ>`를 remap으로 `<C-n>`/`<C-p>`에 넘긴다. 그래서 blink.cmp 목록 이동, snacks picker 이동, 내장 완성, 명령줄 히스토리가 진짜 Ctrl+n/Ctrl+p와 같게 동작한다. 회귀 테스트: `tests/suites/neovim-korean-ctrl.sh`
- langmapper와 다른 점: Ctrl 조합은 한글 조합(preedit)을 거치지 않고 바로 도착하므로 extra keystroke 문제가 없다.
- Hammerspoon과의 경계: 다른 Ctrl 키(y·e·k·f 등)는 Hammerspoon이 Ghostty에서 영문으로 바꾼 뒤 다시 보낸다(`modules/darwin/programs/hammerspoon/files/init.lua`의 `ghosttyCtrlKeys`). n·p를 그 목록에 넣으면 Hammerspoon이 먼저 가로채 누를 때마다 영문으로 바뀐다.
- 재확인 (2026-11 Ghostty 1.4.0 실측): nvim에서 `:lua vim.on_key(function(_, t) if t ~= "" then print(vim.fn.keytrans(t)) end end)`를 실행하고 한글 입력소스로 Insert 모드에서 Ctrl+n을 누른다. `<C-ㅜ>`가 찍히면 이 매핑이 맞다. 다른 값이면 터미널 인코딩이 바뀐 것이다. 확인 뒤에는 nvim을 다시 연다.

## 알려진 제한

- Neovim 내부에서 한글로 전환 후 Normal 모드 명령 사용 시, FocusGained가 발동하지 않아 수동으로 영문 전환 필요
- 한글 IME 조합 지연은 macOS/터미널 레이어 문제로 Neovim 플러그인에서 해결 불가 (터미널 IME escape sequence 미지원)
- 한글 조합 중(마지막 글자가 아직 확정되지 않은 상태)에 누른 Ctrl+n/Ctrl+p는 Ghostty가 Neovim에 보내지 않아 동작하지 않는다(Ghostty 소스 `SurfaceView_AppKit.swift`의 `keyDown` 조합 중 처리, Hammerspoon 합성 키 실측도 같음). 조합 중에는 ↓/↑를 쓴다. Ghostty는 한글 조합을 확정한 뒤 방향키를 다시 보낸다(같은 파일의 `shouldReplayCommittedPreeditKey`). 제안 목록은 대부분 영문을 입력하는 중에 뜨므로 따로 대응하지 않았다.
