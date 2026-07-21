# mise 전역 config 선언 관리 (macOS + NixOS 공통)
#
# 범위: ~/.config/mise/config.toml 하나만 선언한다.
#   - 바이너리 설치는 libraries/packages.nix(pkgs.mise), 셸 활성화는 shell/default.nix,
#     NixOS 컴파일 차단 환경변수는 shell/nixos.nix가 각각 담당 (기존 구조 유지).
#   - 도구 설치본(~/.local/share/mise/installs)은 선언하지 않는다 — activation에서
#     mise를 실행하는 순간 제한 PATH·reshim fragility로 회귀한다는 것이 #814→#890의
#     교훈이므로, 미설치 도구는 대화형 셸에서 `mise install`로 해결한다.
#
# 마이그레이션: 기존 ~/.config/mise/config.toml이 regular file이면 첫 nrs가 충돌한다.
#   macOS는 home-manager backupCommand가 처리하고, NixOS는 백업 정책이 없으므로
#   `mv ~/.config/mise/config.toml{,.bak}` 후 nrs한다.
{ ... }:
{
  xdg.configFile."mise/config.toml".source = ./config.toml;
}
