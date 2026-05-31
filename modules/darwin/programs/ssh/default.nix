{
  config,
  lib,
  constants,
  hostType,
  ...
}:
let
  homeDir = config.home.homeDirectory;
  # 1Password macOS SSH agent socket (group container 경로 — ~/.1password/agent.sock symlink는 자동생성 안 됨)
  onePasswordAgentSock = "${homeDir}/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock";
in
{
  # Mac SSH는 1Password SSH agent로 인증 (PRD #780 Phase 2a).
  # 구 id_ed25519는 1Password mac-ssh로 대체되어 archive됨 (FR-8) → identityFile/ssh-add launchd 제거.
  programs.ssh = {
    enable = true;
    # home-manager의 기본 SSH 설정 비활성화 (deprecated 경고 방지)
    enableDefaultConfig = false;
    matchBlocks = {
      "*" = {
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
        extraOptions = {
          ControlMaster = "auto";
          ControlPath = "~/.ssh/cm-%h-%p-%r";
          # ControlPersist 600 유지 — #710 analyzing-da-sessions의 ControlMaster 다중화(K=8 worker pool)가 의존.
          # 영구(yes)는 무인 파이프 호출에서 master가 stdout을 점유해 hang을 유발하므로, 600으로 master 자동 종료를 보장한다.
          ControlPersist = "600";
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

  # 1Password SSH agent 키 노출 설정 (PRD #780 Phase 2a, #872 후속 P4: SSH 키 vault 분리)
  # 1Password는 SSH 키를 agent에 자동 노출하지 않으므로, 노출할 vault를 agent.toml에 명시해야 한다.
  # SSH 키(mac-ssh/emergency-ssh)는 ssh 전용 vault에 격리되어 있다 — SA token(Automation read-only)은
  # 이 vault에 접근할 수 없어 SA blast radius가 github-pat 한정으로 축소된다(P4 검증: SA op read 차단).
  # emergency_ed25519(파일, IdentityAgent=none 우회)는 본 설정과 무관한 독립 fallback이다.
  home.file.".config/1Password/ssh/agent.toml".text = ''
    [[ssh-keys]]
    vault = "${constants.onePassword.vaults.ssh}"
  '';
}
