{
  config,
  pkgs,
  lib,
  constants,
  hostType,
  ...
}:
let
  homeDir = config.home.homeDirectory;

  # 단일 소스: 키 이름만 정의하면 모든 곳에서 참조
  sshKeyName = "id_ed25519";
  sshKeyPath = "${homeDir}/.ssh/${sshKeyName}";

  sshAddScript = pkgs.writeShellScript "ssh-add-keys" ''
    if /usr/bin/ssh-add -l 2>/dev/null | grep -q "${sshKeyName}"; then
      echo "SSH key already loaded"
      exit 0
    fi
    /usr/bin/ssh-add "${sshKeyPath}" 2>&1
  '';
in
{
  programs.ssh = {
    enable = true;
    # home-manager의 기본 SSH 설정 비활성화 (deprecated 경고 방지)
    enableDefaultConfig = false;
    matchBlocks = {
      "*" = {
        identityFile = sshKeyPath;
        extraOptions = {
          AddKeysToAgent = "yes";
        };
      };
    }
    // lib.optionalAttrs (hostType == "personal") {
      # MiniPC는 Tailscale IP 전용 — work Mac(Tailnet 미소속)에서는 접속 불가
      "minipc" = {
        hostname = constants.network.minipcTailscaleIP;
        user = "greenhead";
        identityFile = sshKeyPath;
      };
    };
  };

  launchd.agents.ssh-add-keys = {
    enable = true;
    config = {
      Label = "com.green.ssh-add-keys";
      ProgramArguments = [ "${sshAddScript}" ];
      RunAtLoad = true;
      EnvironmentVariables = {
        HOME = homeDir;
      };
      StandardOutPath = "${homeDir}/Library/Logs/ssh-add-keys.log";
      StandardErrorPath = "${homeDir}/Library/Logs/ssh-add-keys.error.log";
    };
  };
}
