# inshellisense 설정 (IDE 스타일 쉘 자동완성)
# https://github.com/microsoft/inshellisense
#
# === Change Intent Record ===
# v1 (legacy, 2026-01-05): nixpkgs rc.21로 도입. tmux 비호환으로 환경별 분기
#     (inshellisense=non-tmux, fzf-tab=tmux) 시도 후 리포 구조 변경 시 미포함.
# v2 (이번 변경): Homebrew tap으로 0.0.1 stable 설치.
#     0.0.1에서 tmux 지원 확인 (Issue #306). 사용자가 tmux 비주력.
#     fzf-tab과 공존 — fzf-tab은 zsh completion widget 대체,
#     inshellisense는 독립 overlay UI로 레이어가 다름.
#     trade-off: 두 자동완성 시스템 병행 관리 비용 발생하나,
#               역할이 다르고 추후 fzf-tab 제거 가능.
#
#     [왜 nixpkgs가 아닌 Homebrew tap인가]
#     nixpkgs의 inshellisense는 0.0.1-rc.21 (2025-05 패키징). 0.0.1 stable은
#     2026-03-22 릴리즈되어 아직 nixpkgs bump PR이 없음. maintainer(malob)는
#     활동 중이나 업데이트 시점은 미정.
#     검토한 대안 3가지:
#       A) nixpkgs rc.21 그대로 사용 — tmux 수정 미포함. 사용자가 tmux 비주력이라
#          큰 문제는 아니지만, rc.21→0.0.1 사이 버그 수정 10건+ 누락.
#       B) overlay로 0.0.1 소스 빌드 — buildNpmPackage 기반이라 가능하나,
#          Hydra 바이너리 캐시 미스로 소스 빌드 필요 + src/npmDepsHash 관리 부담 +
#          overlay가 NixOS(MiniPC)에도 불필요하게 영향. libraries/nixpkgs/default.nix의
#          anki overlay CIR(PR #175→#183)에서 동일 문제로 제거한 전례 있음.
#       C) Homebrew tap (채택) — microsoft/inshellisense 공식 리포에 Formula 포함.
#          `brew tap microsoft/inshellisense`로 0.0.1 즉시 설치 가능.
#          nix-darwin homebrew 모듈로 선언적 관리 유지. macOS 전용이므로 NixOS 무영향.
#          Homebrew가 Node.js 의존성도 자동 관리.
#     trade-off: Nix 순수성(nixpkgs 단일 소스)을 포기하나, 이미 macism/sox/ghostty 등
#     Homebrew로 관리하는 패키지가 있어 혼합 전략은 기존 패턴과 일관됨.
#     nixpkgs가 0.0.1+로 업데이트되면 Homebrew→nixpkgs 전환 검토.
{
  config,
  pkgs,
  lib,
  ...
}:

{
  # rc.toml 키바인딩 (~/.config/inshellisense/rc.toml)
  xdg.configFile."inshellisense/rc.toml".text = ''
    [bindings.acceptSuggestion]
    key = "return"

    [bindings.nextSuggestion]
    key = "tab"

    [bindings.previousSuggestion]
    key = "tab"
    shift = true

    [bindings.dismissSuggestions]
    key = "escape"
  '';

  # Zsh 초기화
  # is init zsh: 내부적으로 createShellConfigs() 호출하여
  # ~/.inshellisense/zsh/init.zsh를 자동 생성한 뒤 source 명령을 stdout에 출력.
  # 별도 HM activation 불필요 (--generate-full-configs 플래그는 0.0.1에 미존재).
  programs.zsh.initContent = lib.mkAfter ''
    if command -v is >/dev/null 2>&1; then
      eval "$(is init zsh)"
    fi
  '';
}
