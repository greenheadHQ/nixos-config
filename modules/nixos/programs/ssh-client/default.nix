# SSH 클라이언트 설정 (NixOS)
{ config, constants, ... }:
let
  homeDir = config.home.homeDirectory;
  sshKeyPath = "${homeDir}/.ssh/id_ed25519";
in
{
  programs.ssh = {
    enable = true;
    # home-manager의 기본 SSH 설정 비활성화
    enableDefaultConfig = false;
    settings = {
      "*" = {
        IdentityFile = sshKeyPath;
        AddKeysToAgent = "yes";
      };
      "mac" = {
        HostName = constants.network.macbookTailscaleIP;
        User = "greenhead";
        IdentityFile = sshKeyPath;
        ControlMaster = "auto";
        ControlPath = "~/.ssh/cm-%h-%p-%r";
        ControlPersist = "600";
      };
    };
  };
}
