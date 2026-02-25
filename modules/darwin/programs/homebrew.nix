# Homebrew 패키지 관리 (GUI 앱)
# personal 호스트에서만 활성화 (work 호스트는 회사 정책에 따라 별도 관리)
{
  config,
  pkgs,
  lib,
  hostType,
  ...
}:

{
  homebrew = lib.mkIf (hostType == "personal") {
    enable = true;

    # 선언되지 않은 앱 정리
    onActivation = {
      autoUpdate = true;
      upgrade = true; # 선언된 모든 패키지를 최신 버전으로 업그레이드
      cleanup = "none"; # 선언되지 않은 앱을 자동 삭제하지 않음
    };

    # [업그레이드 정책]
    # upgrade=true + greedyCasks=true 조합:
    # - upgrade=true: nrs 실행 시 brew upgrade를 자동 실행
    # - greedyCasks=true: auto_updates가 있는 cask도 brew upgrade 대상에 포함
    # 자체 업데이터가 있는 앱(Cursor 등)이 Homebrew와 독립적으로 버전을 변경해도
    # nrs 실행 시 Homebrew가 최신 버전으로 동기화하여 버전 드리프트를 방지한다.
    greedyCasks = true;

    # Homebrew Tap (서드파티 저장소)
    taps = [
      "laishulu/homebrew" # macism (macOS 입력 소스 전환 CLI)
    ];

    # Homebrew Formula (CLI 도구)
    brews = [
      "laishulu/homebrew/macism" # macOS 입력 소스 전환 (Neovim 한영 전환 자동화)
    ];

    # Homebrew Cask (GUI 앱)
    #
    # [adopt 가이드] 새 Mac 또는 직접 설치된 앱이 있는 경우
    #
    # nix-darwin은 이 목록을 기반으로 `brew install --cask <앱>`을 실행한다.
    # 그런데 Homebrew Cask는 /Applications에 동일 앱이 이미 존재하면 설치를 거부한다:
    #   Error: It seems there is already an App at '/Applications/Cursor.app'
    #
    # 이때 선택지는 3가지:
    #   1) 기존 앱 삭제 후 brew install → 앱 설정/로그인 상태 유실 위험
    #   2) 이 목록에서 해당 cask 제거 → 선언적 관리 포기
    #   3) brew install --cask --adopt → 기존 앱을 삭제하지 않고 Homebrew가
    #      "내가 설치한 것"으로 인식하도록 등록만 수행. 이후 brew upgrade로 관리 가능.
    #
    # 따라서 nrs 실행 전에 직접 설치된 앱을 --adopt로 전환해야 한다:
    #   brew install --cask --adopt cursor docker-desktop ...
    #
    # adopt 후에는 nrs(darwin-rebuild)가 해당 cask를 정상적으로 인식하여 에러 없이 통과한다.
    # cleanup="none"이므로 미adopt 앱이 남아있어도 삭제되지는 않지만,
    # brew가 해당 앱의 존재를 모르므로 업데이트/관리가 불가능한 상태로 남는다.
    #
    # [Nix 패키지로 전환한 앱]
    # shottr → libraries/packages.nix darwinOnly로 이동 (pkgs.shottr가 macOS .app 번들 포함)
    #
    # [Nix 전환이 불가능한 앱]
    # cursor: pkgs.code-cursor가 존재하지만, Nix store와 /Applications에 각각 설치되어
    #         Spotlight에 동일 앱이 2개 표시되는 문제 발생. programs.vscode.package로 관리 시
    #         Nix가 별도 .app 번들을 생성하기 때문. 이를 회피하려면 Homebrew Cask 단독 관리 필요.
    #         (자세한 내용: .claude/skills/managing-cursor/references/troubleshooting.md)
    # ghostty: pkgs.ghostty-bin은 CLI 바이너리만 제공하고 macOS .app 번들을 포함하지 않음.
    #          Ghostty.app은 Homebrew Cask로만 설치 가능.
    # docker-desktop: Docker Desktop은 nixpkgs에 macOS용 패키지 없음 (CLI만 존재)
    # fork: 상용 Git GUI, nixpkgs에 없음
    # [Homebrew에서 제거한 앱]
    # figma: 자체 업데이터가 적극적으로 버전을 변경하여 Homebrew가 관리하는 버전과 불일치 발생.
    #        adopt 시 버전 불일치로 설치 거부됨. 자체 업데이터에 위임.
    # slack: 수동 설치 선호. 자체 업데이터에 위임.
    #
    casks = [
      "codex"
      "cursor"
      "ghostty"
      "raycast"
      "rectangle"
      "hammerspoon"
      "homerow"
      "docker-desktop"
      "fork"
      "monitorcontrol"
    ];

    # Mac App Store 앱 (mas 필요)
    # masApps = {
    #   # "앱이름" = 앱스토어ID;
    # };
  };
}
