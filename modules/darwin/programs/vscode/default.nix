# VSCode 설정
# Nix로 확장 관리, settings/keybindings는 mkOutOfStoreSymlink (양방향)
#
# === Change Intent Record ===
# Cursor → VSCode 마이그레이션 (Issue #171, PR #181)
#
# 1) 설정 관리: profiles.default.userSettings(Nix store 읽기전용)는 mkOutOfStoreSymlink과
#    충돌하므로 사용하지 않음. settings/keybindings만 mkOutOfStoreSymlink으로 양방향 편집 보장.
# 2) 확장 소스: open-vsx 우선, open-vsx 미등록 확장만 vscode-marketplace.
#    Cursor는 전부 vscode-marketplace였으나 VSCode는 open-vsx 호환이므로 오픈소스 소스 선호.
# 3) 스니펫: Cursor의 별도 JSON 4개를 languageSnippets로 통합 (DRY).
# 4) 설치 방식: Nix 단독 (Homebrew Cask 미사용). Cursor는 Cask+Nix 병행 시
#    Spotlight 중복 문제가 있었음 (homebrew.nix 주석 참조).
# 5) Nix LSP: VSCode=nixd, Neovim=nil로 에디터별 독립 운용.
#    trade-off: LSP 2종 관리 부담이 있으나, 각 에디터에 최적화된 경험 제공.
#
# === Change Intent Record (Zed → VSCode 롤백) ===
# Zed 1달 사용 후 VSCode 복귀 (이전 마이그레이션 #329/#330의 reverse).
#
# 6) 롤백 동기: Zed 1달 사용 중 누적된 7개 pain point — Cold Start이 VSCode보다 느림,
#    `zed`/`zed .` hang 버그(좀비 프로세스 강제 종료 필요), Claude Code의 외부 터미널↔에디터
#    라인 참조 path 미지원, 체감 속도 개선 부족, 단축키 부적응, 내장 Git 미흡(외부 클라이언트
#    의존), Markdown viewer 미감.
# 7) Claude Code 통합: 공식 `anthropic.claude-code` VSCode 확장 사용. Marketplace itemName과
#    Nix attr 모두 lowercase. 통합 단축키 (확장 v2.1.x package.json 기준):
#    - `claude-vscode.focus`: `Cmd+Esc` — editor↔Claude panel focus toggle (vendor default 그대로 사용).
#    - `claude-vscode.insertAtMention`: `Alt+K` — @mention 삽입 vendor default. 별도 명령으로 active.
#    - `claude-code.insertAtMentioned`: `Cmd+Alt+K` vendor default. 본 repo는 keybindings.json에서
#      `Ctrl+Alt+Cmd+K`로 override + vendor `Cmd+Alt+K` 비활성화 (JetBrains keymap 충돌 회피).
#      `claude-vscode.insertAtMention`(`Alt+K`)는 그대로 두어 `Alt+K` 단축키 자체는 작동.
#    - 외부 터미널 `claude --ide` (CLI flag, `~/.local/bin/claude --help` 참조) 또는 in-CLI `/ide`:
#      실행 중 VSCode 자동 인식하여 파일/라인 참조 가능 (Zed의 ACP 패널 미지원이던 path).
# 8) duti activation: 동적 UTI(.mdx/.nix/.toml 등)는 macOS LaunchServices에 정적 UTI가 없어
#    duti가 -50을 반환할 수 있다. set -eu 환경에서 첫 실패가 darwin-rebuild를 exit 2로 종료
#    시키므로, set_handler/register_public_uti helper로 실패를 카운터로 흡수 + public UTI
#    실패는 즉시 보이게 분리. (Zed 모듈에서 같은 패턴이 작동했으므로 그대로 이식.)
#
# === Change Intent Record (LaunchServices stale 정정) ===
# statusline 의 vscode:// 클릭 동작 점검 중 사용자 macOS 에서 그 클릭이
# Finder 등 fallback 핸들러로 dispatch 되는 증상 발견. macOS LaunchServices DB 가 nix store
# 의 VSCode .app bundle URL scheme handler 정보를 어느 시점에 stale 처리하면서
# CFBundleURLTypes 의 vscode:// scheme 매핑이 사라진 상태였다.
#
# 9) Home Manager Apps trampoline 갱신 후 lsregister -f 로 VSCode .app bundle 을
#    LaunchServices DB 에 강제 재등록한다. duti (파일 UTI 매핑, CIR 8) 와 별개 영역이며
#    .app 의 Info.plist CFBundleURLTypes 를 LS DB 에 fresh 로 반영해 vscode:// 클릭의
#    dispatch 를 VSCode 로 고정한다. nix VSCode 업데이트나 macOS LS DB reset 후에도 자동
#    복구되어 영구 fix 역할. activation 실패는 set -eu 종료를 회피하려 || true 로 흡수
#    하되 사용자 가시 메시지로 원인 식별 가능하도록 분기를 명시한다.
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
          # 공식 anthropic.claude-code VSCode 확장 (publisher/extension 모두 lowercase).
          # 외부 터미널 CLI ↔ VSCode 통합은 확장의 WebSocket MCP 서버를 통해 이루어진다:
          #   1) Cmd+Esc — editor ↔ Claude panel focus toggle.
          #   2) Option+K — 에디터 선택 영역을 `@file#Lx-Ly` @mention으로 Claude 프롬프트에 삽입.
          #   3) `claude --ide` (또는 in-CLI `/ide`) — 외부 터미널이 실행 중 VSCode를 자동 인식,
          #      ~/.claude/ide/<port>.lock 파일로 CLI ↔ 확장이 결합된다.
          # CLI는 MCP 클라이언트이고, getDiagnostics 같은 vscode.languages.* API는 확장 호스트
          # 안에서만 호출 가능하므로 확장이 필수. nrs로 nixpkgs 경유 claude-code Nix 패키지가
          # 갱신되어도 DISABLE_AUTOUPDATER=1로 격리되어 터미널 CLI(auto-updater)와 충돌 없음.
          anthropic.claude-code
        ])

        # vscode-marketplace (open-vsx에 없는 확장): https://marketplace.visualstudio.com/vscode
        ++ (with pkgs.vscode-marketplace; [
          fuzionix.code-case-converter
          wix.vscode-import-cost
          imekachi.webstorm-darcula
          atommaterial.a-file-icon-vscode
          mermaidchart.vscode-mermaid-chart
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
  # macOS LaunchServices에 정적 UTI가 없는 확장자(.mdx, .nix, .toml 등)는 동적 UTI(dyn.*)로
  # 매핑되어 duti가 -50을 반환한다. activate 스크립트는 set -eu로 실행되므로 첫 실패 시
  # darwin-rebuild가 exit 2로 종료되므로 helper로 감싸 실패를 카운터로 집계한다.
  home.activation.setVSCodeAsDefaultEditor = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    echo "Setting VSCode as default editor for code files..."

    skipped=0
    total=0
    first_failure=""
    first_failure_err=""
    public_uti_failed=0
    set_handler() {
      total=$((total + 1))
      local err
      if ! err=$(${pkgs.duti}/bin/duti -s ${vscodeBundleId} "$1" all 2>&1); then
        skipped=$((skipped + 1))
        if [ -z "$first_failure" ]; then
          first_failure="$1"
          first_failure_err="$err"
        fi
      fi
    }

    # public.plain-text / public.source-code는 정적 UTI라 정상 등록되어야 한다.
    # 실패는 카운트로 흡수하지 않고 즉시 출력 + 별도 카운터 — 정적 UTI fallback이 깨지면
    # codeExtensions 매핑에 없는 파일이 VSCode로 열리지 않을 수 있다.
    register_public_uti() {
      local err
      if ! err=$(${pkgs.duti}/bin/duti -s ${vscodeBundleId} "$1" all 2>&1); then
        public_uti_failed=$((public_uti_failed + 1))
        echo "  ❌ Failed to register $1: $err — VSCode may not open code files via fallback UTI"
      fi
    }

    ${lib.concatMapStringsSep "\n" (ext: ''set_handler ".${ext}"'') codeExtensions}

    register_public_uti public.plain-text
    register_public_uti public.source-code
    # NB: public.folder default는 macOS가 Apple-protected (Finder 고정) — duti가 error -50
    # 반환하여 등록 불가. 따라서 statusline.sh의 cwd Cmd+클릭은 Finder가 열리는 동작 수용.

    if [ "$skipped" -gt 0 ]; then
      echo "  ⚠️  Skipped $skipped of $total extensions rejected by duti (first: $first_failure → $first_failure_err)"
    fi
    # Catastrophic case: 모든 codeExtensions 실패 + 모든 public.* 실패 — bundle id 오류,
    # VSCode 미설치, duti 자체 고장 같은 설정 오류 신호. activation은 통과시키되 즉시 보임.
    if [ "$total" -gt 0 ] && [ "$skipped" -eq "$total" ] && [ "$public_uti_failed" -eq 2 ]; then
      echo "  🚨 Critical: all duti registrations failed — likely incorrect bundle id, VSCode not installed, or duti broken"
    fi
    if [ "$public_uti_failed" -gt 0 ]; then
      echo "VSCode default settings applied with warnings ($public_uti_failed public UTI registration failed)."
    else
      echo "VSCode default settings applied."
    fi
  '';

  # CIR 9 — macOS LaunchServices DB 가 nix store 의 VSCode .app bundle URL scheme handler
  # 정보를 stale 처리하면서 vscode:// 클릭이 fallback (Finder / Shortcuts / PushRelay 등) 로
  # dispatch 되던 결함을 자동 정정. Home Manager Apps trampoline 이 만들어진 다음
  # (writeBoundary 이후) lsregister -f 로 VSCode .app bundle 을 LS DB 에 강제 재등록한다.
  # duti (파일 UTI 매핑, setVSCodeAsDefaultEditor) 와 별개 영역 — lsregister 는 .app 의
  # Info.plist CFBundleURLTypes (URL scheme handler) 등록을 trigger 한다.
  home.activation.refreshVSCodeLaunchServices = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    echo "Refreshing VSCode LaunchServices registration..."

    vscode_app="$HOME/Applications/Home Manager Apps/Visual Studio Code.app"
    lsregister="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

    if [ ! -e "$vscode_app" ]; then
      echo "  ⚠️  Home Manager Apps trampoline 'Visual Studio Code.app' 부재 — vscode:// scheme handler 등록 skip"
    elif [ ! -x "$lsregister" ]; then
      echo "  ⚠️  lsregister binary 부재 ($lsregister) — vscode:// scheme handler 등록 skip"
    else
      # set -eu 활성 darwin-rebuild 환경에서 lsregister 비정상 종료가 전체 activation 을 exit 2 로
      # 끊지 않도록 || true 로 흡수. stderr 는 보존하여 실패 원인 가시.
      if "$lsregister" -f "$vscode_app" 2>&1; then
        echo "  ✓ vscode:// scheme handler 등록 완료"
      else
        echo "  ⚠️  lsregister -f 실패 — vscode:// 클릭이 fallback 핸들러로 dispatch 될 수 있음"
      fi
    fi
  '';
}
