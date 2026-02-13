# Codex CLI (OpenAI) - pre-built 바이너리 패키지
# https://github.com/openai/codex
# 업데이트: scripts/update-codex-cli.sh
{
  lib,
  stdenv,
  fetchurl,
}:

let
  version = "0.101.0";

  sources = {
    aarch64-darwin = {
      url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-aarch64-apple-darwin.tar.gz";
      hash = "sha256-/Ah+kAK+DhcL/qonZZ43eCHhWrl4tKSQde+V21+CB/g=";
      binary = "codex-aarch64-apple-darwin";
    };
    x86_64-linux = {
      url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-x86_64-unknown-linux-musl.tar.gz";
      hash = "sha256-/zY/hZfb8Dg8F2WefJJzW6qZG+irmflnxcw8aLMpJ3w=";
      binary = "codex-x86_64-unknown-linux-musl";
    };
  };

  src =
    sources.${stdenv.hostPlatform.system}
      or (throw "codex-cli: unsupported system ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation {
  pname = "codex-cli";
  inherit version;

  src = fetchurl {
    inherit (src) url hash;
  };

  sourceRoot = ".";

  unpackPhase = ''
    tar xzf $src
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp ${src.binary} $out/bin/codex
    chmod +x $out/bin/codex
  '';

  meta = {
    description = "OpenAI Codex CLI - AI coding agent";
    homepage = "https://github.com/openai/codex";
    license = lib.licenses.asl20;
    platforms = builtins.attrNames sources;
    mainProgram = "codex";
  };
}
