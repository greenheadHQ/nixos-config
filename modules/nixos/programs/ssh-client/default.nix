# SSH 클라이언트 설정 (NixOS)
{ config, ... }:
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
        hostname = "100.65.50.98";
        user = "green";
        identityFile = sshKeyPath;
      };
    };
  };
}
