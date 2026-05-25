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

  # PRD #780 Phase 2a: Mac SSH를 1Password SSH agent로 인증. true이면 ssh-add launchd agent 비활성.
  # (옵션 대신 let 상수 — 토글 수요 없어 YAGNI. 필요 시 options로 승격)
  useOpAgent = true;
  # 1Password macOS SSH agent socket (group container 경로 — ~/.1password/agent.sock symlink는 자동생성 안 됨)
  onePasswordAgentSock = "${homeDir}/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock";
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
          # 1Password SSH agent (group container socket — 공백 포함 경로라 quote 필요)
          IdentityAgent = "\"${onePasswordAgentSock}\"";
        };
      };
    }
    // lib.optionalAttrs (hostType == "personal") {
      # MiniPC는 Tailscale IP 전용 — work Mac(Tailnet 미소속)에서는 접속 불가
      "minipc" = {
        hostname = constants.network.minipcTailscaleIP;
        user = "greenhead";
        identityFile = sshKeyPath;
        extraOptions = {
          ControlMaster = "auto";
          ControlPath = "~/.ssh/cm-%h-%p-%r";
          # Phase 2a Decision: 600 → 영구. ssh minipc 빈번 워크플로에서 Touch ID 빈도·무인 hang 최소화
          ControlPersist = "yes";
        };
      };
      # 1Password 장애(데스크탑 quit/Touch ID 고장/계정 잠금) fallback (PRD #780 Phase 2a, FR-9)
      "minipc-emergency" = {
        hostname = constants.network.minipcTailscaleIP;
        user = "greenhead";
        identityFile = "${homeDir}/.ssh/emergency_ed25519";
        extraOptions = {
          IdentityAgent = "none"; # 1Password agent 우회 — emergency key 직접 사용
        };
      };
    };
  };

  # useOpAgent=true이면 ssh-add launchd agent 정의 자체가 빠짐 (1Password agent가 키 관리)
  launchd.agents.ssh-add-keys = lib.mkIf (!useOpAgent) {
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
