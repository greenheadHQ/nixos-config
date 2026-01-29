# SSH 클라이언트 설정 (NixOS)
{ config, constants, ... }:
let
  homeDir = config.home.homeDirectory;
  sshKeyPath = "${homeDir}/.ssh/id_ed25519";
in
{
  programs.ssh = {
    enable = true;
    matchBlocks = {
      "*" = {
        identityFile = sshKeyPath;
        extraOptions = {
          AddKeysToAgent = "yes";
        };
      };
      "mac" = {
        hostname = constants.network.macbookTailscaleIP;
        user = "green";
        identityFile = sshKeyPath;
      };
    };
  };
}
