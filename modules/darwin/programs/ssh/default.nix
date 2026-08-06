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
    settings = {
      "*" = {
        AddKeysToAgent = "yes";
        # 1Password SSH agent (group container socket — 공백 포함 경로라 quote 필요)
        IdentityAgent = "\"${onePasswordAgentSock}\"";
      };
    }
    // lib.optionalAttrs (hostType == "personal") {
      # MiniPC는 Tailscale IP 전용 — work Mac(Tailnet 미소속)에서는 접속 불가
      "minipc" = {
        HostName = constants.network.minipcTailscaleIP;
        User = "greenhead";
        # mac-ssh 공개키로 고정 + IdentitiesOnly — agent의 mac-ssh 키만 제시한다.
        # 구 id_rsa/id_ecdsa 등 무차별 키 시도(서버 로그 오염·MaxAuthTries lockout 위험)를 차단한다.
        IdentityFile = "${homeDir}/.ssh/mac-ssh.pub";
        IdentitiesOnly = "yes";
        ControlMaster = "auto";
        ControlPath = "~/.ssh/cm-%h-%p-%r";
        # ControlPersist 600 유지 — #710 analyzing-da-sessions의 ControlMaster 다중화(K=8 worker pool)가 의존.
        # 영구(yes)는 무인 파이프 호출에서 master가 stdout을 점유해 hang을 유발하므로, 600으로 master 자동 종료를 보장한다.
        ControlPersist = "600";
      };
      # 1Password 장애(데스크탑 quit/Touch ID 고장/계정 잠금) fallback (PRD #780 Phase 2a, FR-9)
      "minipc-emergency" = {
        HostName = constants.network.minipcTailscaleIP;
        User = "greenhead";
        IdentityFile = "${homeDir}/.ssh/emergency_ed25519";
        IdentityAgent = "none"; # 1Password agent 우회 — emergency key 직접 사용
        IdentitiesOnly = "yes"; # emergency_ed25519만 제시
      };
      # 무인/원격 세션 전용 (#1094 C안) — 1Password를 우회하는 headless key로 직접 접속.
      # 승인 팝업이 없어 원격/무인에서 hang하지 않는다. ssh() 무인 라우팅(shell/darwin.nix)이
      # 무인 컨텍스트에서 이 경로(IdentityAgent none + headless IdentityFile)를 사용한다.
      "minipc-headless" = {
        HostName = constants.network.minipcTailscaleIP;
        User = "greenhead";
        IdentityFile = "${homeDir}/${constants.onePassword.headlessKeyRelPath}";
        IdentityAgent = "none"; # 1Password agent 우회 — headless key 직접 사용
        IdentitiesOnly = "yes"; # headless key만 제시
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

  # minipc IdentityFile 고정용 mac-ssh 공개키 (개인키는 1Password agent 보관).
  # IdentitiesOnly=yes와 함께 agent의 mac-ssh 키만 제시하게 한다(무차별 키 시도 차단).
  home.file.".ssh/mac-ssh.pub".text = "${constants.sshDeviceKeys.macSsh}\n";

  # Launcher 전용 stable path. global package/session PATH에는 넣지 않아
  # interactive Ghostty와 일반 SSH가 계속 /usr/bin/ssh를 사용한다.
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
