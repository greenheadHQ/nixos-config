# Neovim 설정 (LazyVim)
# 플러그인은 lazy.nvim이 관리, LSP/포매터/린터는 Nix extraPackages로 관리
{
  config,
  pkgs,
  lib,
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

    extraPackages =
      with pkgs;
      [
        # ── LSP 서버 ──
        lua-language-server # Lua
        nil # Nix
        vtsls # TypeScript/JavaScript
        tailwindcss-language-server # Tailwind CSS
        yaml-language-server # YAML
        vscode-langservers-extracted # JSON, HTML, CSS, ESLint
        markdown-oxide # Markdown (Rust — marksman은 .NET→Swift 의존성으로 macOS 빌드 실패)

        # ── 포매터 ──
        prettier # JS/TS/CSS/JSON/YAML/MD
        stylua # Lua
        nixfmt-rfc-style # Nix (바이너리명: nixfmt)

        # ── 린터 ──
        statix # Nix

        # ── 빌드 도구 ──
        nodejs # 일부 LSP 런타임 의존성
      ]
      # ── Linux 전용 ──
      # WARNING: gcc를 무조건 추가하지 마세요. macOS에서는 LLVM 전체 소스 빌드를 트리거합니다.
      # macOS는 clang이 이미 있어 tree-sitter 파서 컴파일이 가능합니다.
      ++ lib.optionals pkgs.stdenv.isLinux [
        gcc # tree-sitter 파서 컴파일 (NixOS 전용 — macOS는 clang 사용)
      ];
  };

  # NOTE: programs.neovim 외부에 배치 (home.file은 HM 최상위 속성)
  home.file.".config/nvim".source = config.lib.file.mkOutOfStoreSymlink nvimConfigPath;
}
