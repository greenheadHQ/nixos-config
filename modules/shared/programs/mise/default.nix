# mise 전역 config 선언 관리 (macOS + NixOS 공통)
#
# 범위: ~/.config/mise/config.toml 하나만 선언한다.
#   - 바이너리 설치는 libraries/packages.nix(pkgs.mise), 셸 활성화는 shell/default.nix,
#     NixOS 컴파일 차단 환경변수는 shell/nixos.nix가 각각 담당 (기존 구조 유지).
#   - 도구 설치본(~/.local/share/mise/installs)은 선언하지 않는다 — activation에서
#     mise를 실행하는 순간 제한 PATH·reshim fragility로 회귀한다는 것이 #814→#890의
#     교훈이므로, 미설치 도구는 대화형 셸에서 `mise install`로 해결한다.
#
# 마이그레이션: 기존 ~/.config/mise/config.toml이 regular file이면 첫 nrs에서
#   home-manager 백업 정책이 처리한다 — macOS는 backupCommand(darwin/home.nix),
#   NixOS는 backupFileExtension = "backup"(flake.nix)으로 자동 백업된다.
#   단 NixOS에서 같은 이름의 .backup 파일이 이미 있으면 activation이 중단되므로
#   그 경우에만 기존 .backup을 먼저 정리한다.
{ ... }:
{
  xdg.configFile."mise/config.toml".source = ./config.toml;
}
