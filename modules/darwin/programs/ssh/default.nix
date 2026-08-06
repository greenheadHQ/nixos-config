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
  # 1Password macOS SSH agent socket (단일 소스: constants.onePassword.agentSocketRelPath)
  onePasswordAgentSock = "${homeDir}/${constants.onePassword.agentSocketRelPath}";
  sshSettings = {
    "*" = {
      AddKeysToAgent = "yes";
      IdentityAgent = "\"${onePasswordAgentSock}\"";
    };
  }
  // lib.optionalAttrs (hostType == "personal") {
    "minipc" = {
      HostName = constants.network.minipcTailscaleIP;
      User = "greenhead";
      IdentityFile = "${homeDir}/.ssh/mac-ssh.pub";
      IdentitiesOnly = "yes";
      ControlMaster = "auto";
      ControlPath = "~/.ssh/cm-%h-%p-%r";
      ControlPersist = "600";
    };
    "minipc-emergency" = {
      HostName = constants.network.minipcTailscaleIP;
      User = "greenhead";
      IdentityFile = "${homeDir}/.ssh/emergency_ed25519";
      IdentityAgent = "none";
      IdentitiesOnly = "yes";
    };
    "minipc-headless" = {
      HostName = constants.network.minipcTailscaleIP;
      User = "greenhead";
      IdentityFile = "${homeDir}/${constants.onePassword.headlessKeyRelPath}";
      IdentityAgent = "none";
      IdentitiesOnly = "yes";
    };
  };
  headlessDispatcher = import ./headless-dispatcher.nix {
    inherit
      config
      pkgs
      lib
      constants
      hostType
      ;
  };
in
{
  # Mac SSH는 1Password SSH agent로 인증 (PRD #780 Phase 2a).
  # 구 id_ed25519는 1Password mac-ssh로 대체되어 archive됨 (FR-8) → identityFile/ssh-add launchd 제거.
  programs.ssh = {
    enable = true;
    # home-manager의 기본 SSH 설정 비활성화
    enableDefaultConfig = false;
    # Launcher dispatcher scope is intentionally limited to the two declared
    # MiniPC aliases and the exact Tailscale host; other SSH destinations stay raw.
    settings = sshSettings;
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

  # minipc IdentityFile 고정용 mac-ssh 공개키 (개인키는 1Password agent 보관).
  # IdentitiesOnly=yes와 함께 agent의 mac-ssh 키만 제시하게 한다(무차별 키 시도 차단).
  home.file.".ssh/mac-ssh.pub".text = "${constants.sshDeviceKeys.macSsh}\n";

  # Stable inspection path only; package/bin is intentionally absent from
  # home.packages/sessionPath so interactive Ghostty keeps /usr/bin/ssh.
  home.file.".local/share/nixos-config/headless-ssh" = lib.mkIf headlessDispatcher.enabled {
    source = headlessDispatcher.package;
  };

  # 1Password 로그인 자동 기동 (minipc SSH 회귀 예방, PRD #780 Phase 2a 후속)
  # 근본 원인: Mac SSH 인증을 1Password agent(mac-ssh)로 이관(FR-8)한 뒤, 1Password 데스크탑이
  # 미실행/quit이면 agent socket이 죽어 mac-ssh 키를 제공하지 못한다. 그러면 ssh가 구 로컬 키로
  # 폴백 → 서버에서 퇴출된 키라 "Permission denied (publickey)"로 전면 차단된다.
  # 로그인 시 1Password를 백그라운드(-g 포커스 유지, -j hidden, --silent 메인창 억제)로 기동해
  # agent socket 생존을 보장한다(잠금은 ssh 시 Touch ID 프롬프트로 해제). open은 멱등이라 이미
  # 실행 중이면 무해. 미설치/실패는 non-fatal(로그만). 수동 quit 등 잔여 케이스는 shell의 ssh
  # preflight 래퍼(modules/shared/programs/shell/darwin.nix)가 안전망으로 처리한다.
  launchd.agents.onepassword-autostart = lib.mkIf (hostType == "personal") {
    enable = true;
    config = {
      # 절대경로 open + 공유 기동 인자 (단일 소스: constants.onePassword.openArgs)
      ProgramArguments = [ "/usr/bin/open" ] ++ constants.onePassword.openArgs;
      RunAtLoad = true; # 로그인(agent 로드) 시 1회 — KeepAlive 불필요(open은 즉시 종료)
      StandardOutPath = "${homeDir}/Library/Logs/onepassword-autostart.log";
      StandardErrorPath = "${homeDir}/Library/Logs/onepassword-autostart.log";
    };
  };
}
