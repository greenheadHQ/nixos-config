# direnv 설정 (디렉토리별 개발 환경 자동 활성화)
#
# 사용법:
#   1. 프로젝트 루트에 .envrc 파일 생성: echo "use flake" > .envrc
#   2. direnv allow 실행
#   3. 이후 디렉토리 진입 시 자동으로 devShell 환경 활성화
#
# nix-direnv는 devShell 평가 결과를 캐싱하여 재로드 시 빠름
{
  config,
  pkgs,
  lib,
  ...
}:

{
  programs.direnv = {
    enable = true;
    enableZshIntegration = true; # zsh hook 자동 등록 (기본값이지만 명시)
    nix-direnv.enable = true; # use flake 지원 + 결과 캐싱

    # ~/Workspace 하위 .envrc 자동 허용
    config = {
      whitelist = {
        prefix = [
          "~/Workspace"
        ];
      };
    };
  };
}
