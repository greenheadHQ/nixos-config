# gh-difftool — PR diff를 로컬 difftool로 여는 gh 확장. upstream prebuilt 핀
# D8: Home Manager linkFarm이 extensions 디렉터리 전체를 소유하므로 함께 선언해야 탈락하지 않는다.
# nixpkgs 부재 실측(2026-07-15), 제어권 불필요 도구라 fork 없이 upstream을 핀한다.
# 업데이트 시: version 변경 → 각 darwin asset hash를 lib.fakeHash로 두고 빌드 에러의 got 값으로 갱신 → nrs
{ pkgs }:
let
  inherit (pkgs) lib stdenvNoCC fetchurl;
  version = "1.2.3";
  platforms = {
    "aarch64-darwin" = {
      asset = "darwin-arm64";
      hash = "sha256-VxpwMJwvG8xQAXCn2Ax2rYiWpTKi5U1clSvXqJ7B8QQ=";
    };
    "x86_64-darwin" = {
      asset = "darwin-amd64";
      hash = "sha256-zCFkKigu8CAoagJHNythJyb99th7Cyz6AiCHZMM9Qe8=";
    };
  };
  platform =
    platforms.${stdenvNoCC.hostPlatform.system}
      or (throw "gh-difftool: unsupported system ${stdenvNoCC.hostPlatform.system}");
in
stdenvNoCC.mkDerivation {
  pname = "gh-difftool";
  inherit version;

  src = fetchurl {
    url = "https://github.com/speedyleion/gh-difftool/releases/download/v${version}/gh-difftool_v${version}_${platform.asset}";
    hash = platform.hash;
  };

  dontUnpack = true;
  # prebuilt Mach-O 선례(codex/claudex package.nix)와 동일하게 Nix fixup이 서명·심볼을 건드리지 않게 차단한다.
  dontStrip = true;
  dontPatchELF = true;

  installPhase = ''
    install -Dm755 "$src" "$out/bin/gh-difftool"
  '';

  meta = {
    description = "gh extension to diff pull requests with a local difftool";
    homepage = "https://github.com/speedyleion/gh-difftool";
    license = lib.licenses.boost;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = builtins.attrNames platforms;
    mainProgram = "gh-difftool";
  };
}
