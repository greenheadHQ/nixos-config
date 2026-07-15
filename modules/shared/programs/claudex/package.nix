# CLIProxyAPI prebuilt binary pin for the claudex PoC.
#
# Stage 1 Nix builds may fetch and unpack this derivation, but must not execute the binary.
# Runtime execution is held behind the manual Gate B flow documented in the handoff because
# upstream starts background network workers and mutates OAuth credentials at runtime.
{ pkgs }:
let
  inherit (pkgs)
    fetchurl
    lib
    stdenvNoCC
    ;
  pin = builtins.fromJSON (builtins.readFile ./cli-proxy-api-pin.json);
  system = stdenvNoCC.hostPlatform.system;
  platform =
    pin.platforms.${system}
      or (throw "cli-proxy-api: unsupported system '${system}' (supported: ${lib.concatStringsSep ", " (builtins.attrNames pin.platforms)})");
in
stdenvNoCC.mkDerivation {
  pname = "cli-proxy-api";
  version = pin.version;

  src = fetchurl {
    url = "https://github.com/router-for-me/CLIProxyAPI/releases/download/${pin.tag}/${platform.asset}";
    hash = platform.hash;
  };

  dontUnpack = true;

  installPhase = ''
    runHook preInstall

    mkdir -p unpacked
    ${pkgs.gnutar}/bin/tar -xzf "$src" -C unpacked

    # Fail loudly if upstream changes the release layout. In particular, never select the
    # first executable from an unreviewed archive. The same verifier is exercised by fake tests.
    ${pkgs.bash}/bin/bash ${./files/verify-release-layout.sh} unpacked
    if [ -L unpacked/cli-proxy-api ] || [ ! -f unpacked/cli-proxy-api ]; then
      echo "cli-proxy-api: expected a regular cli-proxy-api binary" >&2
      exit 1
    fi

    install -Dm755 unpacked/cli-proxy-api "$out/bin/cli-proxy-api"
    runHook postInstall
  '';

  dontStrip = true;
  dontPatchELF = true;

  meta = {
    description = "CLIProxyAPI pinned binary for the declarative claudex PoC";
    homepage = "https://github.com/router-for-me/CLIProxyAPI";
    mainProgram = "cli-proxy-api";
    license = lib.licenses.mit;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = builtins.attrNames pin.platforms;
  };
}
