# CLIProxyAPI prebuilt binary pin for the claudex PoC.
#
# Nix builds only fetch, verify, patch, and install this derivation. Runtime execution stays
# behind the on-demand Claudex gate; OAuth, refresh observation, and host/service mutation
# remain explicit action-time operations documented in the handoff.
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
  inherit (stdenvNoCC.hostPlatform) isLinux;
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

  # The linux release binary is dynamically linked against glibc and carries the FHS
  # interpreter /lib64/ld-linux-x86-64.so.2, which does not exist on NixOS, so it must be
  # patched to run at all (measured on v7.2.73 linux_amd64). autoPatchelfHook rewrites the
  # interpreter and RPATH from buildInputs. Darwin keeps dontPatchELF so the Mach-O signature
  # on the prebuilt binary is preserved untouched.
  nativeBuildInputs = lib.optionals isLinux [ pkgs.autoPatchelfHook ];
  buildInputs = lib.optionals isLinux [ pkgs.stdenv.cc.cc.lib ];

  dontStrip = true;
  dontPatchELF = !isLinux;

  meta = {
    description = "CLIProxyAPI pinned binary for the declarative claudex PoC";
    homepage = "https://github.com/router-for-me/CLIProxyAPI";
    mainProgram = "cli-proxy-api";
    license = lib.licenses.mit;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = builtins.attrNames pin.platforms;
  };
}
