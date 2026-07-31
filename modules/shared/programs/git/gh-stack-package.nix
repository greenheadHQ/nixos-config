# gh-stack — stacked branch/PR 관리 gh 확장 (github 공식 org). upstream prebuilt 핀
# Home Manager linkFarm이 extensions 디렉터리 전체를 소유하므로 함께 선언해야 탈락하지 않는다.
# nixpkgs는 0.0.4로 뒤처짐 실측(2026-07-31, 재검증: nix eval nixpkgs#gh-stack.version) —
# 릴리스 주기가 약 2주로 빨라 upstream 최신을 직접 핀한다.
# AI agent skill 부분은 선언 관리 스코프 제외 — 스킬은 vercel skills(symlink) 경로로 별도 관리.
# 업데이트 시: version 변경 → 각 platform hash를
#   `nix store prefetch-file https://github.com/github/gh-stack/releases/download/v<ver>/<asset>`
#   실측값으로 갱신 → nrs
{ pkgs }:
let
  inherit (pkgs) lib stdenvNoCC fetchurl;
  version = "0.1.0";
  platforms = {
    "aarch64-darwin" = {
      asset = "darwin-arm64";
      hash = "sha256-XKmCQaJl1t4BgJXNrl88QNpcp4JFDuwOqRqo4+sYMQM=";
    };
    "x86_64-darwin" = {
      asset = "darwin-amd64";
      hash = "sha256-cSJmk5v0A0nc5siJMDe4jgRTM00w0GdQthzhpshkC7k=";
    };
    "x86_64-linux" = {
      asset = "linux-amd64";
      hash = "sha256-NYVS3X3OCkbOFT/hlicM7EgrhPCAlHiQqtQGGo1EvAs=";
    };
  };
  platform =
    platforms.${stdenvNoCC.hostPlatform.system}
      or (throw "gh-stack: unsupported system ${stdenvNoCC.hostPlatform.system}");
in
stdenvNoCC.mkDerivation {
  pname = "gh-stack";
  inherit version;

  src = fetchurl {
    url = "https://github.com/github/gh-stack/releases/download/v${version}/${platform.asset}";
    hash = platform.hash;
  };

  dontUnpack = true;
  # prebuilt 바이너리 선례(gh-difftool-package.nix)와 동일하게 Nix fixup이 서명·심볼을 건드리지 않게 차단한다.
  # linux asset은 static Go 바이너리라 patchelf 불필요.
  dontStrip = true;
  dontPatchELF = true;

  installPhase = ''
    install -Dm755 "$src" "$out/bin/gh-stack"
  '';

  meta = {
    description = "GitHub CLI extension for managing stacked branches and pull requests";
    homepage = "https://github.com/github/gh-stack";
    license = lib.licenses.mit;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = builtins.attrNames platforms;
    mainProgram = "gh-stack";
  };
}
