# tests/eval-tests.nix
# Pre-commit E2E eval 테스트 — 네트워크 노출 경계 중심
#
# 실행: nix eval --impure --file tests/eval-tests.nix
# --impure 필요: builtins.getFlake가 로컬 unlocked flake 참조
#
# 원리: Nix lazy evaluation으로 최종 config 속성만 선택적으로 평가.
# nixosTest(VM)과 달리 ~1-2초에 완료되어 pre-commit에 적합.
#
# 반환값: 모든 테스트 통과 시 true, 실패 시 assertion error (빌드 실패)
let
  flake = builtins.getFlake (toString ./..);
  constants = import ../libraries/constants.nix;

  # NixOS config (greenhead-minipc)
  nixosCfg = flake.nixosConfigurations.greenhead-minipc.config;

  # Darwin config 평가 테스트는 pre-push의 `nix flake check --all-systems`와
  # 100% 중복이므로 제거 (Opus 피드백). eval-tests는 네트워크 노출 경계에 집중.

  inherit (constants.network) minipcTailscaleIP;

  # Codex 피드백 #1: constants.nix와 테스트가 같은 값을 공유하므로
  # minipcTailscaleIP 자체가 Tailscale CGNAT 범위(100.64.0.0/10)인지 독립 검증
  isTailscaleCGNAT =
    let
      parts = builtins.match "([0-9]+)\\.([0-9]+)\\.([0-9]+)\\.([0-9]+)" minipcTailscaleIP;
      octet1 = builtins.fromJSON (builtins.elemAt parts 0);
      octet2 = builtins.fromJSON (builtins.elemAt parts 1);
    in
    parts != null && octet1 == 100 && octet2 >= 64 && octet2 <= 127;

  # ═══════════════════════════════════════════════════════════════
  # 헬퍼 함수
  # ═══════════════════════════════════════════════════════════════

  # 모든 homeserver 서비스의 포트 수집 (port 옵션이 있는 서비스만)
  homeserverPorts =
    let
      services = nixosCfg.homeserver;
      portServices = builtins.filter (name: services.${name} ? port) (builtins.attrNames services);
    in
    map (name: {
      inherit name;
      port = services.${name}.port;
    }) portServices;

  # 포트 값만 추출
  allPorts = map (s: s.port) homeserverPorts;

  # 중복 포트 확인: 포트 수 == 고유 포트 수
  uniquePorts = builtins.length (
    builtins.attrNames (
      builtins.listToAttrs (
        map (s: {
          name = toString s.port;
          value = s.name;
        }) homeserverPorts
      )
    )
  );

  # OCI 컨테이너 설정
  containers = nixosCfg.virtualisation.oci-containers.containers;
  containerNames = builtins.attrNames containers;

  # host network allowlist — 이 목록에 없는 컨테이너가 --network=host를 사용하면 실패
  hostNetworkAllowlist = [ "uptime-kuma" ];

  # 컨테이너가 --network=host를 사용하는지 확인
  # --network=host, --net=host (결합형) + --network host, --net host (공백 분리형) 모두 감지
  # Codex 피드백: 공백 분리형 [ "--network" "host" ] 도 podman이 수용하므로 감지 필요
  hasAdjacentPair =
    flag: value: list:
    let
      len = builtins.length list;
      indices = builtins.genList (i: i) (if len > 0 then len - 1 else 0);
    in
    builtins.any (i: builtins.elemAt list i == flag && builtins.elemAt list (i + 1) == value) indices;

  hasHostNetwork =
    name:
    let
      extraOptions = containers.${name}.extraOptions or [ ];
    in
    builtins.elem "--network=host" extraOptions
    || builtins.elem "--net=host" extraOptions
    || hasAdjacentPair "--network" "host" extraOptions
    || hasAdjacentPair "--net" "host" extraOptions;

  # 컨테이너의 ports 속성
  containerPorts = name: containers.${name}.ports or [ ];

  # Codex 피드백: extraOptions에 -p/--publish/-P로 포트를 우회 노출하는지 검사
  # 예: extraOptions = [ "--publish=0.0.0.0:8080:80" ] 또는 [ "-p" "0.0.0.0:8080:80" ]
  # Opus 피드백: -P/--publish-all도 감지 (모든 EXPOSE 포트를 호스트에 공개)
  hasPublishInExtraOptions =
    name:
    let
      extraOptions = containers.${name}.extraOptions or [ ];
    in
    builtins.any (
      opt:
      builtins.match "--publish(=.+)?" opt != null
      || builtins.match "-p(=.+)?" opt != null
      || opt == "-P"
      || opt == "--publish-all"
    ) extraOptions;

  noExtraPublish = builtins.all (name: !hasPublishInExtraOptions name) containerNames;

  # 모든 컨테이너 포트가 127.0.0.1: 접두사인지 확인
  allPortsLocalhost = builtins.all (
    name:
    let
      ports = containerPorts name;
    in
    if hasHostNetwork name then
      ports == [ ] # host network 컨테이너는 ports가 비어야 함
    else
      builtins.all (p: builtins.substring 0 10 p == "127.0.0.1:") ports
  ) containerNames;

  # host network 컨테이너가 allowlist에 포함되어 있는지
  hostNetworkContainers = builtins.filter hasHostNetwork containerNames;
  allHostNetworkAllowed = builtins.all (
    name: builtins.elem name hostNetworkAllowlist
  ) hostNetworkContainers;

  # allowlist에 있지만 실제로 host network를 사용하지 않는 항목이 없는지 (allowlist 정확성)
  allAllowlistUsed = builtins.all (
    name: builtins.elem name containerNames && hasHostNetwork name
  ) hostNetworkAllowlist;

  # host network 컨테이너의 listen address 검증
  uptimeKumaLocalhostOnly = containers.uptime-kuma.environment.UPTIME_KUMA_HOST or "" == "127.0.0.1";

  # ═══════════════════════════════════════════════════════════════
  # Caddy 검증 헬퍼
  # ═══════════════════════════════════════════════════════════════
  caddyVhosts = nixosCfg.services.caddy.virtualHosts;
  vhostNames = builtins.attrNames caddyVhosts;

  # Codex 피드백 #8: builtins.all on empty list = true (vacuous truth)
  # Caddy가 활성화되어 있으면 vhosts가 비어있으면 안 됨
  hasVhosts = vhostNames != [ ];

  allVhostsTailscaleOnly = builtins.all (
    name: caddyVhosts.${name}.listenAddresses == [ minipcTailscaleIP ]
  ) vhostNames;

  caddyGlobalConfig = nixosCfg.services.caddy.globalConfig;
  # Codex 피드백: IP의 .을 리터럴로 이스케이프, 줄 시작 기준 매칭
  # NixOS caddy 모듈은 globalConfig를 프로그래밍적으로 생성하므로 주석 우회 위험은 낮지만,
  # 방어적으로 비주석 줄만 매칭
  # default_bind 검증: builtins.split 기반
  # 이유: builtins.match의 `.`는 newline을 매칭하지 않으므로 (POSIX ERE),
  # globalConfig가 3줄 이상이면 `.*`가 첫 줄까지만 매칭하여 regex가 실패.
  # builtins.split은 문자열 전체를 대상으로 검색하므로 newline 문제 없음.
  escapedIP = builtins.replaceStrings [ "." ] [ "\\." ] minipcTailscaleIP;

  # "default_bind 100\.79\.80\.95"가 globalConfig에 포함되어 있는지 확인
  # builtins.split 결과가 2개 이상 = 매칭 존재
  hasDefaultBind =
    builtins.isString caddyGlobalConfig
    && builtins.length (builtins.split ("default_bind " + escapedIP) caddyGlobalConfig) > 1;

  # Codex 피드백: default_bind가 2번 이상 나타나면, Caddy는 마지막 값을 사용.
  # 두 번째 default_bind 0.0.0.0이 추가되면 첫 번째 테스트가 통과하지만 실제로는 공개 바인딩.
  # builtins.split으로 occurrences 카운트: split 결과 = [비매칭, [매칭], 비매칭, ...]
  # 매칭 횟수 = (length - 1) / 2
  defaultBindCount =
    let
      parts = builtins.split "default_bind" caddyGlobalConfig;
    in
    (builtins.length parts - 1) / 2;
  singleDefaultBind = defaultBindCount == 1;

  # ═══════════════════════════════════════════════════════════════
  # 방화벽 검증 헬퍼
  # ═══════════════════════════════════════════════════════════════
  fw = nixosCfg.networking.firewall;

  # Codex 피드백: allowedTCPPorts == [] 로 엄격화 (서비스 포트만이 아닌 전체 차단)
  # 모든 TCP 접근은 trustedInterfaces(tailscale0)를 통해서만 허용
  noTcpPortsOpen = fw.allowedTCPPorts == [ ];

  # Codex 피드백: 인터페이스별 포트 허용 체크
  # networking.firewall.interfaces.*.allowed{TCP,UDP}Ports 가 비어야 함
  # 예외: podman0 (컨테이너 브릿지) — DNS(53/udp)는 컨테이너 이름 해석에 필요
  fwInterfaces = fw.interfaces or { };
  fwInterfaceNames = builtins.attrNames fwInterfaces;
  # 안전한 인터페이스별 포트 예외 (인터페이스명 → 허용 UDP 포트)
  safeInterfaceUdpPorts = {
    podman0 = [ 53 ]; # DNS for container name resolution
  };
  noInterfacePortsOpen = builtins.all (
    ifName:
    let
      iface = fwInterfaces.${ifName};
      allowedUdp = safeInterfaceUdpPorts.${ifName} or [ ];
    in
    (iface.allowedTCPPorts or [ ]) == [ ]
    && (iface.allowedTCPPortRanges or [ ]) == [ ]
    && (iface.allowedUDPPorts or [ ]) == allowedUdp
    && (iface.allowedUDPPortRanges or [ ]) == [ ]
  ) fwInterfaceNames;

  # Codex 피드백 #4: 수동 nftables 규칙 인젝션 방지
  # extraInputRules, extraForwardRules가 비어야 함
  # 참고: extraCommands/extraStopCommands는 NixOS NAT 모듈이 자동 생성하므로 체크 제외
  noRawFirewallRules = (fw.extraInputRules or "") == "" && (fw.extraForwardRules or "") == "";

  # tailscale 포트 (UDP)
  tailscalePort = nixosCfg.services.tailscale.port;

  # ═══════════════════════════════════════════════════════════════
  # 테스트 실행
  # ═══════════════════════════════════════════════════════════════

  # assert 헬퍼: 메시지와 함께 assertion
  check =
    msg: cond: rest:
    if cond then rest else builtins.throw "EVAL TEST FAILED: ${msg}";

  # 테스트 리스트: { name, cond } 형태 — 순서대로 평가
  tests = [
    {
      name = "Test 0: minipcTailscaleIP(${minipcTailscaleIP})가 Tailscale CGNAT 범위(100.64-127.x.x.x)이어야 함";
      cond = isTailscaleCGNAT;
    }
    {
      name = "Test 1: 포트 충돌 없음 — homeserver 서비스 포트가 모두 고유해야 함 (${toString (builtins.length allPorts)}개 포트, ${toString uniquePorts}개 고유)";
      cond = builtins.length allPorts == uniquePorts;
    }
    {
      name = "Test 2a: 컨테이너 포트가 모두 127.0.0.1에 바인딩 + host network 컨테이너의 ports는 비어야 함";
      cond = allPortsLocalhost;
    }
    {
      name = "Test 2b: extraOptions에 -p/--publish로 포트 우회 노출 금지";
      cond = noExtraPublish;
    }
    {
      name = "Test 2c: --network=host는 allowlist(${builtins.concatStringsSep ", " hostNetworkAllowlist})만 허용 — 현재 host network: [${builtins.concatStringsSep ", " hostNetworkContainers}]";
      cond = allHostNetworkAllowed;
    }
    {
      name = "Test 2d: host network allowlist의 모든 항목이 실제로 host network를 사용해야 함";
      cond = allAllowlistUsed;
    }
    {
      name = "Test 2e: uptime-kuma(host network)의 UPTIME_KUMA_HOST가 127.0.0.1이어야 함 (0.0.0.0이면 LAN 노출)";
      cond = uptimeKumaLocalhostOnly;
    }
    {
      name = "Test 3a: Caddy virtualHosts가 비어있지 않아야 함 (vacuous truth 방지)";
      cond = hasVhosts;
    }
    {
      name = "Test 3b: 모든 Caddy virtualHost의 listenAddresses가 [${minipcTailscaleIP}]이어야 함";
      cond = allVhostsTailscaleOnly;
    }
    {
      name = "Test 4a: Caddy globalConfig에 default_bind ${minipcTailscaleIP}가 포함되어야 함";
      cond = hasDefaultBind;
    }
    {
      # Codex 피드백: default_bind가 중복되면 Caddy는 마지막 값을 사용하므로,
      # 다른 모듈이 default_bind 0.0.0.0을 추가해도 기존 테스트가 통과할 수 있음
      name = "Test 4b: Caddy globalConfig에 default_bind가 정확히 1번만 나타나야 함 (중복 시 마지막 값으로 바인딩 우회 가능)";
      cond = singleDefaultBind;
    }
    {
      name = "Test 5a: anki-sync-server의 address가 ${minipcTailscaleIP}이어야 함 (현재: ${nixosCfg.services.anki-sync-server.address})";
      cond = nixosCfg.services.anki-sync-server.address == minipcTailscaleIP;
    }
    {
      name = "Test 5b: anki-sync-server의 openFirewall이 false이어야 함";
      cond = nixosCfg.services.anki-sync-server.openFirewall == false;
    }
    {
      name = "Test 5c: openssh.openFirewall이 false이어야 함 (true이면 LAN에서 SSH 접근 가능)";
      cond = nixosCfg.services.openssh.openFirewall == false;
    }
    {
      name = "Test 5d: mosh.openFirewall이 false이어야 함 (true이면 LAN에서 mosh UDP 포트 노출)";
      cond = nixosCfg.programs.mosh.openFirewall == false;
    }
    {
      # Codex 피드백: SSH 경화 설정은 Tailscale 경계와 독립적인 보안 레이어
      name = "Test 5e: openssh PermitRootLogin이 'no'이어야 함";
      cond = nixosCfg.services.openssh.settings.PermitRootLogin == "no";
    }
    {
      name = "Test 5f: openssh PasswordAuthentication이 false이어야 함 (공개키만 허용)";
      cond = nixosCfg.services.openssh.settings.PasswordAuthentication == false;
    }
    {
      # Codex 피드백: vaultwarden 계정 생성 허용은 앱 레벨 보안 — Tailscale 경계와 독립
      name = "Test 5g: vaultwarden SIGNUPS_ALLOWED가 'false'이어야 함 (계정 무단 생성 방지)";
      cond = containers.vaultwarden.environment.SIGNUPS_ALLOWED or "" == "false";
    }
    {
      name = "Test 6a: networking.firewall.enable이 true이어야 함";
      cond = fw.enable;
    }
    {
      name = "Test 6b: allowedTCPPorts가 비어야 함 (모든 TCP는 trustedInterfaces로만 허용)";
      cond = noTcpPortsOpen;
    }
    {
      name = "Test 6c: allowedTCPPortRanges가 비어야 함";
      cond = fw.allowedTCPPortRanges == [ ];
    }
    {
      # Codex 피드백: tailscale0 존재도 강제 (빈 리스트나 lo만 있으면 VPN 접근 불가)
      name = "Test 6d: trustedInterfaces에 tailscale0 필수 + 안전한 인터페이스만 허용 (현재: [${builtins.concatStringsSep ", " fw.trustedInterfaces}])";
      cond =
        builtins.elem "tailscale0" fw.trustedInterfaces
        && builtins.all (
          iface:
          builtins.elem iface [
            "tailscale0"
            "lo"
          ]
        ) fw.trustedInterfaces;
    }
    {
      name = "Test 6e: allowedUDPPorts에 Tailscale 포트(${toString tailscalePort})만 허용";
      cond = fw.allowedUDPPorts == [ tailscalePort ];
    }
    {
      name = "Test 6f: allowedUDPPortRanges가 비어야 함";
      cond = fw.allowedUDPPortRanges == [ ];
    }
    {
      name = "Test 6g: 인터페이스별 포트 허용 없음 (networking.firewall.interfaces.*.allowed* 모두 비어야 함)";
      cond = noInterfacePortsOpen;
    }
    {
      name = "Test 6h: 수동 방화벽 규칙 없음 (extraInputRules, extraForwardRules 비어야 함)";
      cond = noRawFirewallRules;
    }
    {
      # Codex 피드백: NAT가 활성화되면 masquerading으로 내부 서비스가 공개될 수 있음
      name = "Test 6i: networking.nat.enable이 false이어야 함 (NAT masquerading 방지)";
      cond = nixosCfg.networking.nat.enable == false;
    }
    {
      # Codex 피드백: NAT 포트 포워딩으로 방화벽 우회 가능 (공개 인터페이스 → 내부 서비스)
      # or [] 없이 직접 접근: NixOS 옵션이 항상 존재하므로, schema 변경 시 에러로 감지
      name = "Test 6j: networking.nat.forwardPorts가 비어야 함 (NAT 포트 포워딩으로 방화벽 우회 방지)";
      cond = nixosCfg.networking.nat.forwardPorts == [ ];
    }
    # Test 7a/7b (Darwin config 평가 성공) 삭제 — pre-push의
    # `nix flake check --no-build --all-systems`와 100% 중복 (Opus 피드백)
  ];

  # 모든 테스트를 순차적으로 평가 (실패 시 해당 테스트 이름과 함께 throw)
  runTests = builtins.foldl' (acc: t: if acc then check t.name t.cond true else acc) true tests;

in
runTests
