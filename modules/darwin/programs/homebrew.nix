# Homebrew 패키지 관리 (GUI 앱)
{ config, pkgs, ... }:

{
  # Homebrew 활성화
  homebrew = {
    enable = true;

    # 선언되지 않은 앱 정리
    onActivation = {
      autoUpdate = true;
      cleanup = "zap";
    };

    # Homebrew Tap (서드파티 저장소)
    taps = [
      "laishulu/homebrew" # macism (macOS 입력 소스 전환 CLI)
    ];

    # Homebrew Formula (CLI 도구)
    brews = [
      "macism" # macOS Input Source Manager (Neovim 한영 전환 자동화)
    ];

    # Homebrew Cask (GUI 앱)
    casks = [
      "cursor"
      "ghostty"
      "raycast"
      "rectangle"
      "hammerspoon"
      "homerow"
      "docker"
      "fork"
      "slack"
      "figma"
      "monitorcontrol"
    ];

    # Mac App Store 앱 (mas 필요)
    # masApps = {
    #   # "앱이름" = 앱스토어ID;
    # };
  };
}
