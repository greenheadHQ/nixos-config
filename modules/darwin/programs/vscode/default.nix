# VSCode 설정
# Nix로 확장 관리, settings/keybindings는 mkOutOfStoreSymlink (양방향)
#
# === Change Intent Record ===
# Cursor → VSCode 마이그레이션 (Issue #171, PR #181)
#
# 1) 설정 관리: profiles.default.userSettings(Nix store 읽기전용)는 mkOutOfStoreSymlink과
#    충돌하므로 사용하지 않음. settings/keybindings만 mkOutOfStoreSymlink으로 양방향 편집 보장.
# 2) 확장 소스: open-vsx 우선, 미등록 4개만 vscode-marketplace. Cursor는 전부
#    vscode-marketplace였으나 VSCode는 open-vsx 호환이므로 오픈소스 소스 선호.
# 3) 스니펫: Cursor의 별도 JSON 4개를 languageSnippets로 통합 (DRY).
# 4) 설치 방식: Nix 단독 (Homebrew Cask 미사용). Cursor는 Cask+Nix 병행 시
#    Spotlight 중복 문제가 있었음 (homebrew.nix:66-69 주석 참조).
# 5) Nix LSP: VSCode=nixd, Neovim=nil로 에디터별 독립 운용.
#    trade-off: LSP 2종 관리 부담이 있으나, 각 에디터에 최적화된 경험 제공.
{
  config,
  pkgs,
  lib,
  nixosConfigPath,
  ...
}:

let
  vscodeFilesPath = "${nixosConfigPath}/modules/darwin/programs/vscode/files";

  # VSCode bundle identifier (macOS 앱 식별자)
  vscodeBundleId = "com.microsoft.VSCode";

  # VSCode로 열 파일 확장자 목록
  codeExtensions = [
    "txt"
    "text"
    "md"
    "mdx"
    "js"
    "jsx"
    "ts"
    "tsx"
    "mjs"
    "cjs"
    "json"
    "yaml"
    "yml"
    "toml"
    "css"
    "scss"
    "sass"
    "less"
    "nix"
    "sh"
    "bash"
    "zsh"
    "py"
    "rb"
    "go"
    "rs"
    "lua"
    "sql"
    "graphql"
    "gql"
    "xml"
    "svg"
    "conf"
    "ini"
    "cfg"
    "env"
    "gitignore"
    "editorconfig"
    "prettierrc"
    "eslintrc"
  ];

  logSnippet = {
    "Print to console" = {
      prefix = "log";
      body = [
        "console.log('$1');"
        "$2"
      ];
      description = "Log output to console";
    };
  };
in
{
  home.packages = [
    pkgs.duti # macOS 파일 연결 CLI 도구
    pkgs.nixd # Nix LSP (nix-ide 확장 의존성)
    pkgs.nixfmt # Nix 포매터 (nixd formatting 의존성)
  ];

  programs.vscode = {
    enable = true;
    package = pkgs.vscode;
    mutableExtensionsDir = false;

    profiles.default = {
      extensions =
        # open-vsx (오픈소스 마켓플레이스): https://open-vsx.org/
        (with pkgs.open-vsx; [
          # 개발 도구
          dbaeumer.vscode-eslint
          esbenp.prettier-vscode
          usernamehw.errorlens
          streetsidesoftware.code-spell-checker
          aaron-bond.better-comments

          # Git
          eamodio.gitlens
          github.vscode-pull-request-github

          # 언어
          jnoortheen.nix-ide

          # 유틸리티
          buenon.scratchpads
          kisstkondoros.vscode-gutter-preview

          # 테마/UI
          k--kato.intellij-idea-keybindings

          # Terraform
          hashicorp.terraform

          # Claude Code
          # === Change Intent Record ===
          # VSCode 확장 anthropic.claude-code 유지 결정 (2026-03-12)
          #
          # 검토 배경: CLI auto-updater(~/.local/bin/claude)와 Nix 패키지(확장 의존성)로
          #   업데이트 채널이 이중화됨. 확장 제거하여 Nix 채널 제거를 검토.
          #
          # 거부 이유: 다음 2개 기능이 확장의 WebSocket MCP 서버에 의존함을 확인:
          #   1) Cmd+Opt+K 단축키 — 에디터 선택 영역을 @mention으로 Claude 프롬프트에 삽입
          #      (확장 package.json의 keybindings에 등록, CLI에는 이 기능 없음)
          #   2) ide - getDiagnostics (MCP) — 확장이 WebSocket MCP 서버를 띄우고
          #      ~/.claude/ide/<port>.lock 파일로 CLI와 연결. CLI는 MCP 클라이언트일 뿐,
          #      vscode.languages.getDiagnostics() API는 확장 호스트에서만 호출 가능.
          #
          # trade-off: nrs 시 nixpkgs 경유로 claude-code Nix 패키지도 갱신되어
          #   업데이트 채널이 이중화되나, Nix 쪽은 DISABLE_AUTOUPDATER=1로 격리되어
          #   터미널 CLI(auto-updater)와 충돌하지 않음. 실질적 부작용 없음.
          anthropic.claude-code
        ])

        # vscode-marketplace (open-vsx에 없는 확장): https://marketplace.visualstudio.com/vscode
        ++ (with pkgs.vscode-marketplace; [
          fuzionix.code-case-converter
          wix.vscode-import-cost
          imekachi.webstorm-darcula
          atommaterial.a-file-icon-vscode
        ]);

      # 스니펫 (HM이 자동으로 snippets/ 디렉토리에 배치)
      languageSnippets = {
        javascript = logSnippet;
        javascriptreact = logSnippet;
        typescript = logSnippet;
        typescriptreact = logSnippet;
      };

      # CIR: profiles.default.userSettings/keybindings 의도적 미사용
      # → HM 모듈이 Nix store 기반 읽기전용 파일을 생성하여 mkOutOfStoreSymlink과 충돌.
      #   enableUpdateCheck/enableExtensionUpdateCheck도 내부적으로 userSettings를 생성하므로 사용 금지.
      #   대신 settings.json에 직접 "update.mode": "none" 등을 기입.
    };
  };

  # settings.json / keybindings.json — 양방향 수정 가능
  home.file = {
    "Library/Application Support/Code/User/settings.json".source =
      config.lib.file.mkOutOfStoreSymlink "${vscodeFilesPath}/settings.json";
    "Library/Application Support/Code/User/keybindings.json".source =
      config.lib.file.mkOutOfStoreSymlink "${vscodeFilesPath}/keybindings.json";
  };

  # VSCode를 기본 에디터로 설정 (duti)
  home.activation.setVSCodeAsDefaultEditor = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    echo "Setting VSCode as default editor for code files..."

    ${lib.concatMapStringsSep "\n" (
      ext: "${pkgs.duti}/bin/duti -s ${vscodeBundleId} .${ext} all"
    ) codeExtensions}

    # UTI 설정 (public.data 제거 — 범위가 너무 넓음)
    ${pkgs.duti}/bin/duti -s ${vscodeBundleId} public.plain-text all
    ${pkgs.duti}/bin/duti -s ${vscodeBundleId} public.source-code all

    echo "VSCode default settings applied successfully."
  '';
}
