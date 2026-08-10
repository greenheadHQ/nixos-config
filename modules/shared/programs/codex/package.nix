# Declarative Codex CLI 패키지 (#890)
# OpenAI 공식 GitHub 릴리스의 prebuilt 바이너리를 직접 핀한다. nixpkgs lag(수 주)·제3자 flake
# 신뢰 없이 최신 codex를 받기 위한 self-maintained overlay다. codex-rs는 정적 바이너리
# (linux=musl static, darwin=signed macho)라 fetch + install만 하면 된다 — 소스 컴파일이나
# patchelf가 필요 없어 substituter 의존도 없다.
#
# 0.147.0부터 도구(shell 등) 실행은 code-mode host 사이드카(codex-code-mode-host)를 경유하며
# (features.code_mode_host stable·기본 활성), codex는 자기 실행 경로와 같은 디렉토리에서 이
# 사이드카를 찾는다. 없으면 도구 실행이 fail-closed로 전부 죽으므로(--disable로도 우회 불가)
# 두 바이너리를 같은 $out/bin에 함께 설치한다.
#
# 버전/해시 SoT: ./codex-pin.json (update-codex 스크립트가 최신 stable 릴리스로 갱신).
# 손으로 편집하지 말고 `update-codex`로 bump한다.
#
# 채택 안 함(이슈 #890 참조): activation 스크립트가 ~/.local/bin/codex에 ELF를 까는 imperative
# 다운로더는 cleanupLegacyCodexCli가 자가 삭제한다. 본 파일은 /nix/store/...-codex-<ver>/bin/codex
# store-path 정식 derivation이라 그 cleanup 대상 밖이다(= nixpkgs가 하는 일을 lag 없이 in-repo로).
{ pkgs }:
let
  inherit (pkgs) lib stdenvNoCC fetchurl;
  pin = builtins.fromJSON (builtins.readFile ./codex-pin.json);
  system = stdenvNoCC.hostPlatform.system;
  plat =
    pin.platforms.${system}
      or (throw "codex: 지원하지 않는 시스템 '${system}' (지원: ${lib.concatStringsSep ", " (builtins.attrNames pin.platforms)})");
  codeModeHost =
    plat.codeModeHost
      or (throw "codex: ${system}에 codeModeHost 선언 필요 (codex-pin.json) — 없으면 도구 실행이 fail-closed");
in
stdenvNoCC.mkDerivation {
  pname = "codex";
  version = pin.version;

  src = fetchurl {
    url = "https://github.com/openai/codex/releases/download/${pin.tag}/${plat.asset}";
    hash = plat.hash;
  };

  codeModeHostSrc = fetchurl {
    url = "https://github.com/openai/codex/releases/download/${pin.tag}/${codeModeHost.asset}";
    hash = codeModeHost.hash;
  };

  # tarball은 단일 파일(바이너리)만 담으므로 stdenv unpackPhase의 single-file 처리를 우회하고
  # installPhase에서 직접 추출한다.
  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    # 현행 codex 릴리스의 CLI·code-mode host tarball은 각각 단일 바이너리(<이름>-<triple>;
    # flat 또는 subdir)만 담는다. 추출 정규파일이 정확히 1개임을 단언해, upstream이 다파일
    # 레이아웃(예: 바이너리+README)으로 바꾸면 silent misinstall 대신 loud fail 하도록
    # 한다(그때 maintainer가 선택 로직을 갱신).
    install_single_bin() {
      local archive="$1" name="$2" workdir extracted
      workdir="$(mktemp -d ./unpack.XXXXXX)"
      ${pkgs.gnutar}/bin/tar -xzf "$archive" -C "$workdir"
      extracted="$(find "$workdir" -type f)"
      if [ "$(printf '%s\n' "$extracted" | grep -c .)" -ne 1 ]; then
        echo "codex: $name tarball 추출 정규파일이 1개가 아님 — 릴리스 레이아웃 변경. package.nix install 로직 갱신 필요:" >&2
        printf '%s\n' "$extracted" >&2
        exit 1
      fi
      install -Dm755 "$extracted" "$out/bin/$name"
    }
    install_single_bin "$src" codex
    install_single_bin "$codeModeHostSrc" codex-code-mode-host
    runHook postInstall
  '';

  # prebuilt 바이너리라 추가 처리를 끈다. linux asset은 musl 정적이라 patchelf 불필요(#890).
  # upstream이 glibc-dynamic linux 바이너리로 바꾸면 NixOS용 autoPatchelfHook이 필요해진다.
  dontStrip = true;
  dontPatchELF = true;

  meta = {
    description = "OpenAI Codex CLI (declarative — OpenAI 공식 릴리스 직핀, #890)";
    homepage = "https://github.com/openai/codex";
    mainProgram = "codex";
    license = lib.licenses.asl20;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = builtins.attrNames pin.platforms;
  };
}
