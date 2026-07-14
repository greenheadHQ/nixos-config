{
  flake,
  hostname,
  pkgs ? flake.inputs.nixpkgs.legacyPackages.${builtins.currentSystem},
  username ? "claudex-fixture",
}:

let
  fakeCliProxyApi =
    pkgs.runCommand "cli-proxy-api-fixture-7.2.73" { } ''
      install -Dm755 ${pkgs.writeShellScript "cli-proxy-api-fixture" "exit 99"} "$out/bin/cli-proxy-api"
    ''
    // {
      version = "7.2.73";
    };
  home = flake.inputs.home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    extraSpecialArgs = {
      inherit hostname;
      claudexCliProxyApi = fakeCliProxyApi;
    };
    modules = [
      ../../modules/shared/programs/claudex
      {
        home = {
          inherit username;
          homeDirectory = "/Users/${username}";
          stateVersion = "25.05";
        };
      }
    ];
  };
in
{
  inherit hostname;
  config = home.config;
  activationPackage = home.activationPackage;
}
