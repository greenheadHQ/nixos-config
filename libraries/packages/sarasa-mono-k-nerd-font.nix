# Sarasa Mono K Nerd Font
# CJK 2:1 정확한 너비 비율 + Nerd Font 글리프 패치
# https://github.com/jonz94/Sarasa-Gothic-Nerd-Fonts
{
  lib,
  stdenvNoCC,
  fetchurl,
  unzip,
}:

let
  version = "1.0.35-0";
in
stdenvNoCC.mkDerivation {
  pname = "sarasa-mono-k-nerd-font";
  inherit version;

  src = fetchurl {
    url = "https://github.com/jonz94/Sarasa-Gothic-Nerd-Fonts/releases/download/v${version}/sarasa-mono-k-nerd-font.zip";
    hash = "sha256-q2b+tJUzQ9xM6qechw9eEDglKH6XxWmCTeSdq5J9u+o=";
  };

  nativeBuildInputs = [ unzip ];

  sourceRoot = ".";

  dontBuild = true;

  installPhase = ''
    mkdir -p $out/share/fonts/truetype
    cp *.ttf $out/share/fonts/truetype/
  '';

  meta = {
    description = "Sarasa Mono K with Nerd Font glyphs — CJK programming font";
    homepage = "https://github.com/jonz94/Sarasa-Gothic-Nerd-Fonts";
    license = lib.licenses.ofl;
    platforms = lib.platforms.all;
  };
}
