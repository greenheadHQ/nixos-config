# Ghostty 터미널 설정 (macOS 전용)
{ ... }:

{
  xdg.configFile."ghostty/config".text = ''
    # macOS Option 키를 Alt로 사용 (왼쪽만)
    macos-option-as-alt = left
  '';
}
