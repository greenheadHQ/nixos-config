# Ghostty 터미널 설정 (macOS 전용)
{ ... }:

{
  xdg.configFile."ghostty/config".text = ''
    # 폰트 설정 — Ghostty font-family fallback chain
    #
    # font-family를 여러 줄 지정하면 fallback chain으로 동작한다.
    # 각 문자를 렌더링할 때 1순위 폰트에서 글리프를 먼저 찾고,
    # 없는 경우에만 2순위 이하로 넘어간다.
    #
    # 1순위: JetBrainsMono Nerd Font — 영문/숫자/기호/Nerd Font 아이콘
    # 2순위: D2Coding — 한글 (Nix 설치, 네이버 코딩 전용 폰트)
    font-family = JetBrainsMono Nerd Font
    font-family = D2Coding

    # macOS Option 키를 Alt로 사용 (왼쪽만)
    macos-option-as-alt = left
  '';
}
