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

    # 명령어 완료 알림 (1.3.0+)
    # 포커스되지 않은 창에서 10초 이상 걸린 명령어 완료 시 macOS 알림 전송
    notify-on-command-finish = unfocused
    notify-on-command-finish-action = notify
    # CIR: 10s 선택 — 기본값 5s는 짧은 명령(git push 등)에도 알림이 와서 노이즈 발생
    notify-on-command-finish-after = 10s

    # Split zoom 유지 (1.3.0+)
    # Ghostty 네이티브 split 간 이동 시 zoom 상태 유지
    split-preserve-zoom = navigation
  '';
}
