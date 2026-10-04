# Claude RC만 수정된 Bash로 실행한다. 전역 overlay는 다른 서비스와 stdenv까지
# 재빌드하므로 피한다. nixpkgs가 patch 16 이상으로 갱신되면 이 backport는 빠진다.
{ pkgs }:
let
  baseBash = pkgs.bashNonInteractive;
  needsDarwinPipeFix = pkgs.stdenv.hostPlatform.isDarwin && baseBash.version == "5.3p15";
  bash =
    if needsDarwinPipeFix then
      baseBash.overrideAttrs (old: {
        __intentionallyOverridingVersion = true;
        version = "5.3p16";
        patch_suffix = "p16";
        patches = old.patches ++ [
          (pkgs.fetchurl {
            url = "https://ftp.gnu.org/gnu/bash/bash-5.3-patches/bash53-016";
            hash = "sha256-nqKbJmt9JMs00P8/HEYx5NUnv+LR7xXRfNuSS/Me92c=";
          })
        ];
      })
    else
      baseBash;
  builders = pkgs.callPackage (pkgs.path + "/pkgs/build-support/trivial-builders") {
    runtimeShell = "${bash}/bin/bash";
  };
in
{
  inherit bash;
  inherit (builders) writeShellApplication;
}
