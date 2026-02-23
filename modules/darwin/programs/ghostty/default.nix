# Ghostty 터미널 설정 (macOS 전용)
{ ... }:

{
  xdg.configFile."ghostty/config".text = ''
    # 폰트 설정 — Ghostty font-family
    #
    # font-family를 여러 줄 지정하면 fallback chain으로 동작한다.
    # 각 문자를 렌더링할 때 1순위 폰트에서 글리프를 먼저 찾고,
    # 없는 경우에만 2순위 이하로 넘어간다.
    # CJK(한글 등) 문자는 macOS 시스템 폰트가 자동으로 폴백 처리한다.
    #
    # 폰트를 추가하려면 font-family 줄을 아래에 추가하면 된다.
    font-family = JetBrainsMono Nerd Font

    # macOS Option 키를 Alt로 사용 (왼쪽만)
    macos-option-as-alt = left
  '';
}
