# nixpkgs/Go 업데이트 없이 공식 정적 바이너리로 보안 수정을 반영한다.
# https://tailscale.com/security-bulletins (TS-2026-014~017)
{
  lib,
  stdenvNoCC,
  fetchurl,
  makeWrapper,
  installShellFiles,
  getent,
  iproute2,
  iptables,
  shadow,
  procps,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "tailscale";
  version = "1.104.4";

  src = fetchurl {
    url = "https://pkgs.tailscale.com/stable/tailscale_${finalAttrs.version}_amd64.tgz";
    hash = "sha256-Yk6gk9R9Ys9W8XuDMtdLjezaSh+qYQ68YKHeM0srPck=";
  };

  nativeBuildInputs = [
    makeWrapper
    installShellFiles
  ];
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  dontPatchELF = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 tailscale "$out/bin/tailscale"
    install -Dm755 tailscaled "$out/bin/tailscaled"
    # nixpkgs 패키지와 동일한 실행 도구를 제공한다.
    wrapProgram "$out/bin/tailscaled" \
      --prefix PATH : ${
        lib.makeBinPath [
          getent
          iproute2
          iptables
          shadow
        ]
      } \
      --suffix PATH : ${lib.makeBinPath [ procps ]}
    for unit in systemd/*.service systemd/*.target; do
      substituteInPlace "$unit" \
        --replace-quiet /usr/sbin "$out/bin" \
        --replace-quiet /usr/bin "$out/bin"
      sed -i '/^EnvironmentFile=/d' "$unit"
      install -Dm444 "$unit" "$out/lib/systemd/system/$(basename "$unit")"
    done
    installShellCompletion --cmd tailscale \
      --bash <("$out/bin/tailscale" completion bash) \
      --fish <("$out/bin/tailscale" completion fish) \
      --zsh <("$out/bin/tailscale" completion zsh)
    runHook postInstall
  '';

  meta = {
    description = "Tailscale node agent (official security release)";
    homepage = "https://tailscale.com";
    license = lib.licenses.bsd3;
    mainProgram = "tailscale";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
