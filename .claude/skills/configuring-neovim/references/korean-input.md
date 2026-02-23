# 한국어 입력 지원 (macOS)

외부 앱에서 한글을 쓰다가 Neovim으로 돌아왔을 때 Normal 모드에서 키맵이 동작하지 않는 문제를 2계층으로 방어:

| 레이어 | 도구 | 파일 | 담당 |
|--------|------|------|------|
| 1차 | FocusGained autocmd | `autocmds.lua` | 외부 앱 복귀 시 영문 IM 전환 → 내장/플러그인 명령 정상 동작 |
| 2차 | im-select.nvim | `editor.lua` | Insert↔Normal 전환 시 영문/한글 자동 전환 |

- **macOS 전용**: `vim.fn.executable("macism") == 1`로 NixOS/SSH 환경에서 자동 비활성화
- **macism 설치**: `modules/darwin/programs/homebrew.nix`에서 선언적 관리 (`nrs` 시 자동 설치). nixpkgs는 Swift 빌드 실패로 Homebrew 전용
- **langmap/langmapper 미사용**: 한글 IME 조합(자음+모음→음절) 특성상 extra keystroke 문제 발생. 러시아어(키릴)처럼 1:1 매핑이 되지 않아 실용성 없음

## 알려진 제한

- Neovim 내부에서 한글로 전환 후 Normal 모드 명령 사용 시, FocusGained가 발동하지 않아 수동으로 영문 전환 필요
- 한글 IME 조합 지연은 macOS/터미널 레이어 문제로 Neovim 플러그인에서 해결 불가 (터미널 IME escape sequence 미지원)
