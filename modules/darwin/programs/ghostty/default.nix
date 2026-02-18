# Ghostty 터미널 설정 (macOS 전용)
{ ... }:

{
  xdg.configFile."ghostty/config".text = ''
    # 폰트 설정 (Sarasa Mono K: CJK 2:1 정확한 너비)
    font-family = Sarasa Mono K Nerd Font
    font-family = JetBrainsMono Nerd Font

    # macOS Option 키를 Alt로 사용 (왼쪽만)
    macos-option-as-alt = left
  '';
}
