# Neovim 설정 (LazyVim)
# 플러그인은 lazy.nvim이 관리, LSP/포매터/린터는 Nix extraPackages로 관리
{
  config,
  pkgs,
  nixosConfigPath,
  ...
}:

let
  nvimConfigPath = "${nixosConfigPath}/modules/shared/programs/neovim/files/nvim";
in
{
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;

    # WARNING: plugins, initLua, extraConfig를 여기에 추가하지 마세요.
    # 모든 neovim 설정은 files/nvim/에서 lazy.nvim이 관리합니다.
    # HM이 xdg.configFile."nvim/" 파일을 생성하면 디렉토리 심볼릭 링크와 충돌합니다.

    extraPackages = with pkgs; [
      # ── LSP 서버 ──
      lua-language-server # Lua
      nil # Nix
      vtsls # TypeScript/JavaScript
      tailwindcss-language-server # Tailwind CSS
      yaml-language-server # YAML
      vscode-langservers-extracted # JSON, HTML, CSS, ESLint
      marksman # Markdown

      # ── 포매터 ──
      prettier # JS/TS/CSS/JSON/YAML/MD
      stylua # Lua
      nixfmt-rfc-style # Nix (바이너리명: nixfmt)

      # ── 린터 ──
      statix # Nix

      # ── 빌드 도구 ──
      gcc # tree-sitter 파서 컴파일 (NixOS 필수)
      nodejs # 일부 LSP 런타임 의존성
    ];
  };

  # NOTE: programs.neovim 외부에 배치 (home.file은 HM 최상위 속성)
  home.file.".config/nvim".source = config.lib.file.mkOutOfStoreSymlink nvimConfigPath;
}
