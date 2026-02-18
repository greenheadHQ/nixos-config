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
    # 현재 구성:
    #   1순위: Sarasa Mono K — Iosevka(라틴) + Source Han Sans(CJK) 합성 폰트.
    #          라틴:CJK = 1:2 너비 비율이 정확히 설계되어 한영 혼용 시 정렬이 완벽함.
    #          라틴 글리프도 포함하므로 사실상 대부분의 문자를 여기서 처리.
    #   2순위: JetBrainsMono — Sarasa에 없는 Nerd Font 특수 글리프 등을 보완.
    #
    # 기본 폰트를 JetBrains Mono로 바꾸고 싶다면:
    #   아래 두 줄의 순서만 바꾸면 된다.
    #   단, JetBrains Mono가 1순위이면 라틴은 JBM, CJK는 Sarasa에서 가져오므로
    #   서로 다른 폰트 메트릭이 섞여 한영 혼용 줄에서 너비 정렬이 어긋날 수 있다.
    #   영문 위주 작업이라면 문제없고, 한글이 많이 섞이면 체감될 수 있음.
    font-family = Sarasa Mono K Nerd Font
    font-family = JetBrainsMono Nerd Font

    # macOS Option 키를 Alt로 사용 (왼쪽만)
    macos-option-as-alt = left
  '';
}
