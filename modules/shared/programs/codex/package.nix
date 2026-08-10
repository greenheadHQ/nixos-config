# Declarative Codex CLI 패키지 (#890, #1219)
# OpenAI 공식 GitHub 릴리스의 prebuilt 바이너리를 직접 핀한다. nixpkgs lag(수 주)·제3자 flake
# 신뢰 없이 최신 codex를 받기 위한 self-maintained overlay다.
#
# 설치 소스는 upstream이 조립·검증해 발행하는 codex-package 통합 tarball 하나다 (#1219).
# 과거에는 실행 구성 요소(codex + codex-code-mode-host)를 asset별로 열거해 설치했는데, upstream이
# 0.147.0에서 도구 실행을 사이드카로 분리하자 열거 누락으로 "빌드 성공·--version 정상·도구 실행
# 전부 fail-closed" 장애가 났다(#1220). 통합 tarball은 구성 요소 목록(사이드카·번들 rg/zsh 등)의
# 관리 주체를 upstream에 두므로 이 클래스가 구조적으로 재발하지 않는다.
#
# 레이아웃: tarball 전체를 $out/libexec/codex/에 풀고 $out/bin/codex symlink만 노출한다.
# - codex는 자기 실행 파일의 canonical 경로(symlink 완전 해석) 옆 codex-package.json으로 package
#   layout을 인식하므로(upstream codex-rs/install-context, symlink 시나리오 테스트 존재) bin/
#   symlink 경유 실행에서도 사이드카·번들 도구를 libexec 실경로에서 찾는다.
# - tarball 최상위(codex-package.json, codex-path/, codex-resources/)를 $out에 그대로 풀면
#   home-manager buildEnv 프로필 루트에 병합되므로 libexec 중간 디렉토리로 격리한다.
# - 사이드카는 codex가 내부적으로 찾는 구현 세부라 bin/에 노출하지 않는다.
#
# 버전/해시 SoT: ./codex-pin.json (update-codex 스크립트가 최신 stable 릴리스로 갱신).
# 손으로 편집하지 말고 `update-codex`로 bump한다.
#
# 채택 안 함(이슈 #890 참조): activation 스크립트가 ~/.local/bin/codex에 ELF를 까는 imperative
# 다운로더는 cleanupLegacyCodexCli가 자가 삭제한다. 본 파일은 store-path 정식 derivation이라
# 그 cleanup 대상 밖이다(= nixpkgs가 하는 일을 lag 없이 in-repo로).
{ pkgs }:
let
  inherit (pkgs) lib stdenvNoCC fetchurl;
  pin = builtins.fromJSON (builtins.readFile ./codex-pin.json);
  system = stdenvNoCC.hostPlatform.system;
  plat =
    pin.platforms.${system}
      or (throw "codex: 지원하지 않는 시스템 '${system}' (지원: ${lib.concatStringsSep ", " (builtins.attrNames pin.platforms)})");
in
stdenvNoCC.mkDerivation {
  pname = "codex";
  version = pin.version;

  src = fetchurl {
    url = "https://github.com/openai/codex/releases/download/${pin.tag}/${plat.asset}";
    hash = plat.hash;
  };

  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/libexec/codex"
    ${pkgs.gnutar}/bin/tar -xzf "$src" -C "$out/libexec/codex"

    # 빌드타임 단언: 구성 요소를 열거하는 대신, tarball이 스스로 선언하는 계약
    # (codex-package.json의 entrypoint)만 검증한다. upstream이 레이아웃을 바꾸면
    # (metadata 부재/entrypoint 이동) 사용자 런타임이 아니라 여기서 loud fail 한다.
    meta_json="$out/libexec/codex/codex-package.json"
    if [ ! -f "$meta_json" ]; then
      echo "codex: tarball에 codex-package.json 없음 — upstream package 레이아웃 변경. package.nix 갱신 필요:" >&2
      find "$out/libexec/codex" -maxdepth 2 >&2
      exit 1
    fi
    entrypoint="$(${pkgs.jq}/bin/jq -r '.entrypoint // empty' "$meta_json")"
    if [ -z "$entrypoint" ] || [ ! -x "$out/libexec/codex/$entrypoint" ]; then
      echo "codex: codex-package.json entrypoint('$entrypoint')가 실행 파일이 아님 — upstream 계약 변경. package.nix 갱신 필요" >&2
      exit 1
    fi
    mkdir -p "$out/bin"
    ln -s "../libexec/codex/$entrypoint" "$out/bin/codex"
    runHook postInstall
  '';

  # prebuilt 바이너리라 추가 처리를 끈다. linux asset은 musl 정적이라 patchelf 불필요(#890),
  # darwin asset은 signed macho라 strip이 서명을 깨뜨린다.
  # upstream이 glibc-dynamic linux 바이너리로 바꾸면 NixOS용 autoPatchelfHook이 필요해진다.
  dontStrip = true;
  dontPatchELF = true;

  meta = {
    description = "OpenAI Codex CLI (declarative — OpenAI 공식 codex-package tarball 직핀, #890/#1219)";
    homepage = "https://github.com/openai/codex";
    mainProgram = "codex";
    license = lib.licenses.asl20;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = builtins.attrNames pin.platforms;
  };
}
