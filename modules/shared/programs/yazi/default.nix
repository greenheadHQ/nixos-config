# yazi TUI 파일 매니저
# - Ghostty + tmux + SSH 경로에서 Kitty graphics 이미지 프리뷰 전제로 통합
#   (추가 전제: tmux `allow-passthrough on`, Ghostty `shell-integration-features = ssh-env`, sshd `AcceptEnv`)
# - `pkgs.yazi` 래퍼가 file/jq/poppler-utils/7zz/ffmpeg/fd/ripgrep/fzf/zoxide/imagemagick/chafa/resvg를 PATH에 자동 주입
{
  inputs,
  pkgs,
  ...
}:
{
  programs.yazi = {
    enable = true;
    enableZshIntegration = true;

    # HM stateVersion 25.05 기본값은 "yy" + deprecation warn.
    # 공식 권장값 "y"로 명시 (stateVersion 26.05+ 기본값과 동일).
    shellWrapperName = "y";

    package = pkgs.yazi;

    plugins = {
      inherit (pkgs.yaziPlugins) full-border git starship;
    };

    # catppuccin-mocha flavor: nixpkgs에 yaziFlavors/yaziPlugins.catppuccin-mocha 없어 flake input 사용.
    # path 타입 필요 (HM: attrsOf (oneOf [path package])) → 문자열 interpolation 대신 path 연산.
    flavors.catppuccin-mocha = inputs.yazi-flavors + "/catppuccin-mocha.yazi";
    theme.flavor.dark = "catppuccin-mocha";

    # git.yazi 플러그인 등록: git repo의 파일 목록에 git 상태 linemode 표시.
    # 두 패턴 모두 필요: "*"는 개별 파일, "*/"는 디렉터리 매칭 (git.yazi 공식 README 기준).
    settings.plugin.prepend_fetchers = [
      {
        id = "git";
        url = "*";
        run = "git";
        group = "git";
      }
      {
        id = "git";
        url = "*/";
        run = "git";
        group = "git";
      }
    ];

    # 세 플러그인 모두 명시적 setup 필요 (upstream README 기준).
    initLua = ''
      require("full-border"):setup()
      require("starship"):setup()
      require("git"):setup()
    '';
  };
}
