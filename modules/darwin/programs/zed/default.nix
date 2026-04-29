# Zed 에디터 설정 관리 (앱 바이너리는 homebrew.nix에서 Homebrew cask로 설치)
# 이 모듈의 책임: settings/keymap 심링크, LSP/formatter 패키지, 기본 에디터 등록
#
# === Change Intent Record ===
# VSCode → Zed 마이그레이션 (Issue #329)
#
# 1) 전환 동기: Claude Code CLI 중심 워크플로 확립으로 IDE의 역할이 코드 확인/소규모 편집으로
#    축소됨. VSCode보다 가벼운 에디터가 필요하여 Zed로 전환. (Cursor → VSCode: #171)
# 2) 설정 관리: mkOutOfStoreSymlink으로 양방향 편집 보장 (VSCode 패턴 계승).
#    Zed 앱은 Homebrew cask가 설치하지만, settings.json/keymap.json은 이 모듈이 관리.
# 3) 확장 관리: settings.json의 auto_install_extensions에 직접 기입.
#    trade-off: VSCode의 Nix 결정론적 관리(nix-vscode-extensions)와 달리 Zed 확장은
#    런타임 네트워크 다운로드. 버전 고정/오프라인 빌드 불가. Zed 에코시스템 한계로 수용.
# 4) 포기 기능 (trade-off): GitHub PR in-editor review, Scratchpads 전용 패널,
#    Gutter Preview, Import Cost. 사용자 확인 후 수용.
# 5) Claude Code 연동: VSCode는 WebSocket MCP 서버 기반 확장, Zed는 ACP(Agent Client
#    Protocol) 기반 네이티브 통합. getDiagnostics는 Zed LSP 연동으로 대체.
# 6) 보안: settings.json이 git-tracked public repo에 노출되므로 API 키/토큰 절대 금지.
#    Zed 인증은 ~/.config/zed/credentials.json (git 미추적) 또는 환경변수로 분리.
# 7) 설치 방식: nixpkgs(HM programs.zed-editor) → Homebrew cask 전환.
#    Nix store는 읽기 전용이라 Zed 자체 업데이터가 바이너리를 교체할 수 없어
#    자동 업데이트가 불가능했음. Homebrew cask는 /Applications/Zed.app에 설치되어
#    자체 업데이터가 정상 작동. CLI(zed)도 cask가 직접 제공.
{
  config,
  pkgs,
  lib,
  nixosConfigPath,
  ...
}:

let
  zedFilesPath = "${nixosConfigPath}/modules/darwin/programs/zed/files";

  # Zed bundle identifier (macOS 앱 식별자)
  zedBundleId = "dev.zed.Zed";

  # Zed로 열 파일 확장자 목록 (VSCode에서 이관)
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
in
{
  home.packages = [
    pkgs.duti # macOS 파일 연결 CLI 도구
    pkgs.nixd # Nix LSP (Zed nix 확장 의존성)
    pkgs.nixfmt # Nix 포매터 (nixd formatting 의존성)
    pkgs.prettier # JS/TS/JSON 포매터 (Zed formatter 의존성)
  ];

  # settings.json / keymap.json — 양방향 수정 가능
  home.file = {
    ".config/zed/settings.json".source =
      config.lib.file.mkOutOfStoreSymlink "${zedFilesPath}/settings.json";
    ".config/zed/keymap.json".source =
      config.lib.file.mkOutOfStoreSymlink "${zedFilesPath}/keymap.json";
  };

  # Zed를 기본 에디터로 설정 (duti)
  # macOS LaunchServices에 정적 UTI가 없는 확장자(.mdx, .nix, .toml 등)는 동적 UTI(dyn.*)로
  # 매핑되어 duti가 -50을 반환한다. activate 스크립트는 set -eu로 실행되므로 첫 실패 시
  # darwin-rebuild가 exit 2로 종료되므로 helper로 감싸 실패를 카운터로 집계한다.
  home.activation.setZedAsDefaultEditor = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    echo "Setting Zed as default editor for code files..."

    skipped=0
    total=0
    first_failure=""
    first_failure_err=""
    public_uti_failed=0
    set_handler() {
      total=$((total + 1))
      local err
      if ! err=$(${pkgs.duti}/bin/duti -s ${zedBundleId} "$1" all 2>&1); then
        skipped=$((skipped + 1))
        if [ -z "$first_failure" ]; then
          first_failure="$1"
          first_failure_err="$err"
        fi
      fi
    }

    # public.plain-text / public.source-code는 정적 UTI라 정상 등록되어야 한다.
    # 실패는 카운트로 흡수하지 않고 즉시 출력 + 별도 카운터 — 정적 UTI fallback이 깨지면
    # codeExtensions 매핑에 없는 파일이 Zed로 열리지 않을 수 있다.
    register_public_uti() {
      local err
      if ! err=$(${pkgs.duti}/bin/duti -s ${zedBundleId} "$1" all 2>&1); then
        public_uti_failed=$((public_uti_failed + 1))
        echo "  ❌ Failed to register $1: $err — Zed may not open code files via fallback UTI"
      fi
    }

    ${lib.concatMapStringsSep "\n" (ext: ''set_handler ".${ext}"'') codeExtensions}

    register_public_uti public.plain-text
    register_public_uti public.source-code

    if [ "$skipped" -gt 0 ]; then
      echo "  ⚠️  Skipped $skipped of $total extensions rejected by duti (first: $first_failure → $first_failure_err)"
    fi
    # Catastrophic case: 모든 codeExtensions 실패 + 모든 public.* 실패 — bundle id 오류,
    # Zed 미설치, duti 자체 고장 같은 설정 오류 신호. activation은 통과시키되 즉시 보임.
    if [ "$total" -gt 0 ] && [ "$skipped" -eq "$total" ] && [ "$public_uti_failed" -eq 2 ]; then
      echo "  🚨 Critical: all duti registrations failed — likely incorrect bundle id, Zed not installed, or duti broken"
    fi
    if [ "$public_uti_failed" -gt 0 ]; then
      echo "Zed default settings applied with warnings ($public_uti_failed public UTI registration failed)."
    else
      echo "Zed default settings applied."
    fi
  '';
}
