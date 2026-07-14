# tests/eval-tests.nix
# Pre-commit E2E eval 테스트 — NixOS 네트워크 노출 경계 + Darwin intent 검증
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
  nixpkgsLib = flake.inputs.nixpkgs.lib;
  constants = import ../libraries/constants.nix;

  # NixOS config (greenhead-minipc)
  nixosCfg = flake.nixosConfigurations.greenhead-minipc.config;

  # Darwin intent 검증은 여기서 직접 수행한다.
  # 범위: evaluation-safe value-level 설정만 검증.
  # 제외: postActivation, symbolic hotkeys, GUI 세션/WindowServer 의존 동작.
  darwinCfgs = flake.darwinConfigurations;
  expectedDarwinHosts = [
    "greenhead-MacBookPro"
    "work-MacBookPro"
  ];
  claudexTargetHosts = [
    "greenhead-MacBookPro"
    "work-MacBookPro"
  ];
  darwinHostNames = builtins.attrNames darwinCfgs;
  unexpectedDarwinHosts = builtins.filter (
    name: !(builtins.elem name expectedDarwinHosts)
  ) darwinHostNames;

  # Claudex Stage 1 static inputs. These are parsed directly so a pin/template-only change is
  # covered without ever executing the upstream CLIProxyAPI binary.
  claudexPin = builtins.fromJSON (
    builtins.readFile ../modules/shared/programs/claudex/cli-proxy-api-pin.json
  );
  claudexTemplate = builtins.fromJSON (
    builtins.readFile ../modules/shared/programs/claudex/files/config-template.json
  );
  claudexLayoutVerifier = builtins.readFile ../modules/shared/programs/claudex/files/verify-release-layout.sh;
  fakeClaudexPkgs =
    system:
    let
      fakeStorePath = name: "/nix/store/00000000000000000000000000000000-${name}";
    in
    {
      fetchurl = attrs: attrs;
      lib = {
        concatStringsSep = builtins.concatStringsSep;
        licenses.mit = "MIT";
        sourceTypes.binaryNativeCode = "binaryNativeCode";
      };
      stdenvNoCC = {
        hostPlatform = { inherit system; };
        mkDerivation = attrs: attrs;
      };
      gnutar = fakeStorePath "gnutar";
      findutils = fakeStorePath "findutils";
      coreutils = fakeStorePath "coreutils";
      bash = fakeStorePath "bash";
    };
  claudexPackage = import ../modules/shared/programs/claudex/package.nix {
    pkgs = fakeClaudexPkgs "aarch64-darwin";
  };
  claudexUnsupportedPackage = builtins.tryEval (
    (import ../modules/shared/programs/claudex/package.nix {
      pkgs = fakeClaudexPkgs "x86_64-linux";
    }).src.url
  );

  inherit (constants.network) minipcTailscaleIP;

  # Codex 피드백: constants.nix와 테스트가 같은 값을 공유하므로
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
  hostNetworkAllowlist = [
    "uptime-kuma"
  ];

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
      # or [] 없이 직접 접근: NixOS oci-containers 옵션이 항상 존재하므로, schema 변경 시 에러로 감지
      extraOptions = containers.${name}.extraOptions;
    in
    builtins.elem "--network=host" extraOptions
    || builtins.elem "--net=host" extraOptions
    || hasAdjacentPair "--network" "host" extraOptions
    || hasAdjacentPair "--net" "host" extraOptions;

  # 컨테이너의 ports 속성
  # or [] 없이 직접 접근: NixOS oci-containers 옵션이 항상 존재
  containerPorts = name: containers.${name}.ports;

  # Codex 피드백: extraOptions에 -p/--publish/-P로 포트를 우회 노출하는지 검사
  # 예: extraOptions = [ "--publish=0.0.0.0:8080:80" ] 또는 [ "-p" "0.0.0.0:8080:80" ]
  # Opus 피드백: -P/--publish-all도 감지 (모든 EXPOSE 포트를 호스트에 공개)
  hasPublishInExtraOptions =
    name:
    let
      extraOptions = containers.${name}.extraOptions;
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
  # Opus 피드백: Nix select-or 우선순위는 == 보다 높지만, 명시적 괄호로 의도 명확화
  uptimeKumaLocalhostOnly =
    (containers.uptime-kuma.environment.UPTIME_KUMA_HOST or "") == "127.0.0.1";

  # ═══════════════════════════════════════════════════════════════
  # Caddy 검증 헬퍼
  # ═══════════════════════════════════════════════════════════════
  caddyVhosts = nixosCfg.services.caddy.virtualHosts;
  vhostNames = builtins.attrNames caddyVhosts;

  # Codex 피드백: builtins.all on empty list = true (vacuous truth)
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

  # "default_bind 100\.79\.80\.95" 뒤에 공백 없이 줄이 끝나야 함
  # Opus 피드백: Caddy default_bind는 공백으로 다중 주소를 받으므로,
  # `default_bind 100.79.80.95 0.0.0.0`이면 기존 테스트를 통과하면서 0.0.0.0에도 바인딩.
  # [ \t]*\n 패턴으로 IP 뒤에 다른 주소가 없는지 검증.
  # Opus 피드백: 후행 \n 없을 시 매칭 실패 방지 — globalConfig에 "\n" 어펜드.
  hasDefaultBind =
    builtins.isString caddyGlobalConfig
    &&
      builtins.length (
        builtins.split ("default_bind[ \t]+" + escapedIP + "[ \t]*\n") (caddyGlobalConfig + "\n")
      ) > 1;

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

  # Opus 피드백: services.caddy.extraConfig로 site block을 직접 추가하면
  # listenAddresses/default_bind 제약을 모두 우회하여 0.0.0.0에 바인딩 가능
  caddyExtraConfig = nixosCfg.services.caddy.extraConfig;

  # Opus 피드백: vhost extraConfig 내부의 `bind` 디렉티브는 listenAddresses를 오버라이드.
  # 예: extraConfig = "bind 0.0.0.0\nreverse_proxy ..." 이면 Test 3b를 통과하면서도 공개 노출.
  # Opus 피드백: 들여쓰기된 `  bind 0.0.0.0`도 감지해야 함.
  # 정규화: "\n" 프리펜드로 첫 줄도 "\n[ \t]*bind " 패턴에 통일.
  noBindInVhosts = builtins.all (
    name:
    let
      ec = caddyVhosts.${name}.extraConfig;
      normalized = "\n" + ec;
    in
    builtins.length (builtins.split "\n[ \t]*bind[ \t]" normalized) == 1
  ) vhostNames;

  # ═══════════════════════════════════════════════════════════════
  # Caddy virtualHost 완전성 검증
  # ═══════════════════════════════════════════════════════════════
  allSubdomainsHaveVhosts = builtins.all (
    sub: builtins.elem "${constants.domain.subdomains.${sub}}.${constants.domain.base}" vhostNames
  ) (builtins.attrNames constants.domain.subdomains);

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
  # Opus 피드백: NixOS 옵션이 항상 존재하므로 or {} 불필요 (or [] 제거와 일관)
  fwInterfaces = fw.interfaces;
  fwInterfaceNames = builtins.attrNames fwInterfaces;
  # 안전한 인터페이스별 포트 예외 (인터페이스명 → 허용 UDP 포트)
  safeInterfaceUdpPorts = {
    podman0 = [ 53 ]; # DNS for container name resolution
  };
  # Opus 피드백: allowlist 정확성 — safeInterfaceUdpPorts의 모든 키가 실제 인터페이스에 존재해야 함
  # (hostNetworkAllowlist의 allAllowlistUsed 패턴과 동일)
  allSafeInterfaceKeysExist = builtins.all (ifName: builtins.elem ifName fwInterfaceNames) (
    builtins.attrNames safeInterfaceUdpPorts
  );
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

  # Codex 피드백: 수동 방화벽 규칙 인젝션 방지
  # extraInputRules, extraForwardRules가 비어야 함
  # Opus 피드백: NixOS 옵션이 항상 존재하므로 or "" 불필요 (or [] 제거와 일관)
  noRawFirewallRules = fw.extraInputRules == "" && fw.extraForwardRules == "";

  # extraCommands/extraStopCommands allowlist 검증
  # NixOS NAT 모듈이 cleanup 명령(-D/-F/-X)을 extraCommands에 자동 생성하므로 전체 매칭 불가
  # 보안 관련 규칙만 검증: nixos-fw-accept (NixOS 방화벽의 트래픽 허용 액션)
  # 현재 허용: karakeep webhook 브리지 (podman+ → webhookPort)
  # 규칙 문자열은 karakeep-notify.nix의 iptables 명령과 정확히 일치해야 함
  # 새 서비스가 extraCommands를 사용할 경우, 해당 규칙과 expectedFwAcceptCount를 업데이트
  karakeepNotifyCfg = nixosCfg.homeserver.karakeepNotify;
  karakeepNotifyActive = karakeepNotifyCfg.enable && nixosCfg.homeserver.karakeep.enable;

  # 허용된 karakeep iptables 규칙 문자열
  karakeepExtraCmd = "iptables -I nixos-fw 1 -i podman+ -p tcp --dport ${toString karakeepNotifyCfg.webhookPort} -j nixos-fw-accept";

  # extraCommands에서 nixos-fw-accept 출현 횟수 (= 트래픽 허용 규칙 수)
  # NAT cleanup 명령은 nixos-fw-accept를 사용하지 않으므로 카운트에서 자연 제외
  fwAcceptCount =
    let
      parts = builtins.split "nixos-fw-accept" fw.extraCommands;
    in
    builtins.length (builtins.filter builtins.isList parts);

  expectedFwAcceptCount = if karakeepNotifyActive then 1 else 0;

  # karakeep 규칙이 extraCommands에 정확히 포함되어야 함 (규칙 내용 변경 감지)
  # builtins.split는 regex를 사용하므로 podman+의 +를 이스케이프
  # 현재 규칙 문자열에 다른 regex 특수문자(. [ ( * ? { ^ $ |) 없음
  karakeepExtraCmdRegex = builtins.replaceStrings [ "+" ] [ "\\+" ] karakeepExtraCmd;
  karakeepRulePresent =
    if karakeepNotifyActive then
      builtins.length (builtins.split karakeepExtraCmdRegex fw.extraCommands) > 1
    else
      true;

  # extraStopCommands: NixOS 시스템 콘텐츠 없으므로 정확 매칭
  allowedExtraStopCommands =
    if karakeepNotifyActive then
      ''
        iptables -D nixos-fw -i podman+ -p tcp --dport ${toString karakeepNotifyCfg.webhookPort} -j nixos-fw-accept 2>/dev/null || true
      ''
    else
      "";

  # 비NixOS-관례 트래픽 허용 타겟 검사 (우회 방지)
  # NixOS 관례는 -j nixos-fw-accept (소문자) — 위 fwAcceptCount로 검증
  # NAT cleanup 명령은 체인명(-j nixos-nat-pre 등)을 사용하므로 false positive 없음
  noRawAcceptInExtraCommands =
    builtins.all
      (
        target:
        builtins.length (builtins.filter builtins.isList (builtins.split target fw.extraCommands)) == 0
      )
      [
        "-j ACCEPT"
        "-j DNAT"
        "-j REDIRECT"
      ];

  extraCommandsAllowed =
    fwAcceptCount == expectedFwAcceptCount
    && karakeepRulePresent
    && noRawAcceptInExtraCommands
    && fw.extraStopCommands == allowedExtraStopCommands;

  # tailscale 포트 (UDP)
  tailscalePort = nixosCfg.services.tailscale.port;

  # opnix 1Password SA token materialization
  opnixCfg = nixosCfg.services.onepassword-secrets;
  opnixGithubPat = opnixCfg.secrets.githubPat;
  opnixGithubPatPathMatch = builtins.match "/run/opnix/([^/]+)/github-pat" opnixGithubPat.path;
  opnixGithubPatExpectedOwner =
    if opnixGithubPatPathMatch == null then null else builtins.elemAt opnixGithubPatPathMatch 0;
  opnixTokenSecret = nixosCfg.age.secrets.opnix-service-account-token;
  opnixTmpfilesRules = nixosCfg.systemd.tmpfiles.rules;

  # Darwin sudo.extraConfig 정규화 헬퍼
  splitLines = text: builtins.filter builtins.isString (builtins.split "\n" text);

  isBlankLine = line: builtins.match "[[:space:]]*" line != null;
  isKnownDarwinSudoMetadataLine =
    line:
    builtins.elem line [
      "# Keep terminfo database for root and %admin."
      "Defaults:root,%admin env_keep+=TERMINFO_DIRS"
      "Defaults:root,%admin env_keep+=TERMINFO"
    ];

  expectedDarwinSudoRule =
    cfg: "${cfg.system.primaryUser} ALL=(root) NOPASSWD: /run/current-system/sw/bin/darwin-rebuild";

  normalizedDarwinSudoPolicyLines =
    cfg:
    builtins.filter (line: !(isBlankLine line || isKnownDarwinSudoMetadataLine line)) (
      splitLines cfg.security.sudo.extraConfig
    );

  darwinSudoRuleMatchesExactly =
    cfg:
    let
      policyLines = normalizedDarwinSudoPolicyLines cfg;
    in
    builtins.length policyLines == 1 && builtins.elemAt policyLines 0 == expectedDarwinSudoRule cfg;

  darwinIntentTests = builtins.concatLists (
    map (
      hostName:
      let
        hasHost = builtins.hasAttr hostName darwinCfgs;
        cfg = if hasHost then darwinCfgs.${hostName}.config else null;
        hm = if hasHost then cfg.home-manager.users.${cfg.system.primaryUser} else null;
        claudexDescriptorPath = ".config/claudex/runtime.json";
        hasClaudexDescriptor = hasHost && builtins.hasAttr claudexDescriptorPath hm.home.file;
        claudexDescriptor =
          if hasClaudexDescriptor then builtins.fromJSON hm.home.file.${claudexDescriptorPath}.text else null;
        claudexShouldEnable = builtins.elem hostName claudexTargetHosts;
        claudexPublicFiles = [
          ".local/bin/claudex"
          ".local/bin/claudex-login"
          ".local/bin/claudex-status"
          ".local/libexec/claudex/claudex-proxy-launcher"
        ];
        claudexAgentNames = if hasHost then builtins.attrNames hm.launchd.agents else [ ];
        claudexDarwinAgentNames =
          if hasHost then builtins.attrNames (cfg.launchd.user.agents or { }) else [ ];
        claudexAllActivationNames = if hasHost then builtins.attrNames (hm.home.activation or { }) else [ ];
        claudexActivationNames =
          if hasHost then
            builtins.filter (name: nixpkgsLib.hasInfix "claudex" name) (claudexAllActivationNames)
          else
            [ ];
        claudexActivationReferencesRuntime = builtins.any (
          name:
          let
            data = hm.home.activation.${name}.data or "";
          in
          nixpkgsLib.hasInfix "claudex" data
        ) claudexAllActivationNames;
        claudexRuntimeSource =
          if hasHost && builtins.hasAttr ".local/lib/claudex/runtime.sh" hm.home.file then
            hm.home.file.".local/lib/claudex/runtime.sh".source
          else
            null;
        claudexRuntimeContext =
          if claudexRuntimeSource != null then builtins.getContext (toString claudexRuntimeSource) else { };
        claudexRuntimeReferencesProxy = builtins.any (
          drvPath: nixpkgsLib.hasInfix "cli-proxy-api" (builtins.readFile drvPath)
        ) (builtins.attrNames claudexRuntimeContext);
      in
      [
        {
          name = "Test D0 ${hostName}: darwinConfigurations에 expected host가 존재해야 함";
          cond = hasHost;
        }
        {
          name = "Test D1 ${hostName}: Touch ID sudo가 활성화되어야 함";
          cond = hasHost && cfg.security.pam.services.sudo_local.touchIdAuth == true;
        }
        {
          name = "Test D2 ${hostName}: sudo.extraConfig 정규화 후 darwin-rebuild NOPASSWD 규칙 1줄만 남아야 함";
          cond = hasHost && darwinSudoRuleMatchesExactly cfg;
        }
        {
          name = "Test D3 ${hostName}: Dock autohide가 true여야 함";
          cond = hasHost && cfg.system.defaults.dock.autohide == true;
        }
        {
          name = "Test D4 ${hostName}: Dock show-recents가 false여야 함";
          cond = hasHost && cfg.system.defaults.dock."show-recents" == false;
        }
        {
          name = "Test D5 ${hostName}: Dock tilesize가 constants.macos.dock.tileSize와 일치해야 함";
          cond = hasHost && cfg.system.defaults.dock.tilesize == constants.macos.dock.tileSize;
        }
        {
          name = "Test D6 ${hostName}: InitialKeyRepeat가 constants.macos.keyboard.initialKeyRepeat와 일치해야 함";
          cond =
            hasHost
            && cfg.system.defaults.NSGlobalDomain.InitialKeyRepeat == constants.macos.keyboard.initialKeyRepeat;
        }
        {
          name = "Test D7 ${hostName}: KeyRepeat가 constants.macos.keyboard.keyRepeat와 일치해야 함";
          cond =
            hasHost && cfg.system.defaults.NSGlobalDomain.KeyRepeat == constants.macos.keyboard.keyRepeat;
        }
        {
          name = "Test D8 ${hostName}: 자연 스크롤이 비활성화되어야 함";
          cond = hasHost && cfg.system.defaults.NSGlobalDomain."com.apple.swipescrolldirection" == false;
        }
        # 셸 startup 최적화 회귀 lock — modules/darwin/configuration.nix.
        # 타이밍이 아닌 config-level 불변식만 검증(결정론적, 부하 무관).
        # D-넘버는 per-host 루프와 글로벌 리스트가 공유하는 단일 시퀀스다. 글로벌 불변식(D9
        # unexpected-host)은 메인 tests 리스트에 있으므로, per-host 루프는 D8 다음 D10부터 이어진다.
        {
          name = "Test D10 ${hostName}: 시스템 compinit 중복 제거 — enableGlobalCompInit이 false여야 함";
          cond = hasHost && cfg.programs.zsh.enableGlobalCompInit == false;
        }
        {
          name = "Test D11 ${hostName}: 사문 promptinit 제거 — promptInit이 빈 문자열이어야 함 (Starship이 프롬프트를 덮어씀)";
          cond = hasHost && cfg.programs.zsh.promptInit == "";
        }
        {
          # D10이 시스템 compinit을 제거하므로 사용자 compinit이 유일 정본이 되어야 한다.
          # 부정 불변식(D10)과 긍정 불변식(이 테스트)을 한 쌍으로 잠가 단일-정본 추상화를 보호한다.
          # 검증 대상 enableCompletion/completionInit은 이 repo가 명시 설정하지 않고 home-manager
          # 업스트림 기본값(enableCompletion=true, completionInit="autoload -U compinit && compinit")에
          # 의존한다 — repo를 grep해도 설정이 안 나오는 이유다. enableGlobalCompInit=false로 시스템
          # compinit을 제거했기에 이 기본값이 유일 compinit이 되며, 깨지면(enableCompletion=false /
          # oh-my-zsh·prezto 도입 / 업스트림 변경) darwin 전 셸 completion이 전면 사망한다 → 그 회귀를
          # 조기 감지하려고 framework 기본값을 의도적으로 잠근다.
          name = "Test D12 ${hostName}: 시스템 compinit 제거의 짝 — 사용자(home-manager) compinit이 단일 정본으로 존재해야 함";
          cond =
            hasHost
            && (
              let
                hmZsh = cfg.home-manager.users.${cfg.system.primaryUser}.programs.zsh;
              in
              # enableCompletion이 켜져 있고 completionInit에 compinit 호출이 있는지 함께 검증한다.
              # builtins.match는 전체-문자열 앵커(부분 매치 아님)라 .* 래핑이 필요하고, POSIX ERE의 `.`은
              # newline을 매치하지 않아 completionInit이 멀티라인이면 전체 매치가 실패하므로 newline을
              # 공백으로 평탄화한다(현 HM 기본값은 단일 라인이라 평탄화는 방어적 no-op).
              hmZsh.enableCompletion
              &&
                builtins.match ".*compinit.*" (builtins.replaceStrings [ "\n" ] [ " " ] hmZsh.completionInit)
                != null
            );
        }
        {
          name = "Test D13 ${hostName}: Computer Use 금지 대상 허용이 활성화되어야 함";
          cond =
            hasHost
            &&
              cfg.system.defaults.CustomUserPreferences.NSGlobalDomain.ComputerUseAllowForbiddenTargets == true;
        }
        {
          name = "Test D14 ${hostName}: claudex descriptor와 runtime library는 모든 Darwin host에 있어야 함";
          cond = hasClaudexDescriptor && builtins.hasAttr ".local/lib/claudex/runtime.sh" hm.home.file;
        }
        {
          name = "Test D15 ${hostName}: claudex descriptor의 loopback/model/schema 계약이 고정되어야 함";
          cond =
            hasClaudexDescriptor
            && claudexDescriptor.schema == 2
            && claudexDescriptor.hostName == hostName
            && claudexDescriptor.targetHosts == claudexTargetHosts
            && claudexDescriptor.label == "org.nix-community.home.claudex-proxy"
            && claudexDescriptor.bindHost == "127.0.0.1"
            && claudexDescriptor.port == 8317
            && claudexDescriptor.model == "gpt-5.6-sol"
            && claudexDescriptor.readiness.method == "GET"
            && claudexDescriptor.readiness.url == "http://127.0.0.1:8317/v1/models"
            && claudexDescriptor.readiness.catalogIsEntitlement == false
            && claudexDescriptor.launchAgentPlist == null;
        }
        {
          name = "Test D16 ${hostName}: claudex 실행 표면은 승인된 Darwin 호스트에만 노출되어야 함";
          cond =
            hasClaudexDescriptor
            && claudexDescriptor.enabled == claudexShouldEnable
            && builtins.all (path: builtins.hasAttr path hm.home.file == claudexShouldEnable) claudexPublicFiles
            && (
              if claudexShouldEnable then
                claudexDescriptor.proxyVersion == "7.2.73"
                && claudexDescriptor.command != null
                && builtins.length claudexDescriptor.command == 1
                && claudexDescriptor.proxyExecutable != null
                && claudexDescriptor.source != null
                && builtins.elemAt claudexDescriptor.command 0 == claudexDescriptor.proxyLauncher
                && nixpkgsLib.hasSuffix "/bin/cli-proxy-api" claudexDescriptor.proxyExecutable
                && toString hm.home.file.".local/bin/claudex".source == "${claudexDescriptor.source}/bin/claudex"
                &&
                  toString hm.home.file.".local/bin/claudex-login".source
                  == "${claudexDescriptor.source}/bin/claudex-login"
                &&
                  toString hm.home.file.".local/bin/claudex-status".source
                  == "${claudexDescriptor.source}/bin/claudex-status"
                &&
                  toString hm.home.file.".local/libexec/claudex/claudex-proxy-launcher".source
                  == claudexDescriptor.proxyLauncher
              else
                claudexDescriptor.proxyVersion == null
                && claudexDescriptor.command == null
                && claudexDescriptor.proxyExecutable == null
                && claudexDescriptor.proxyLauncher == null
                && claudexDescriptor.source == null
            )
            && !claudexRuntimeReferencesProxy;
        }
        {
          name = "Test D17 ${hostName}: Stage 1에는 claudex launchd agent가 없어야 함";
          cond =
            builtins.all (
              name:
              name != "claudex-proxy"
              && (hm.launchd.agents.${name}.config.Label or "") != "org.nix-community.home.claudex-proxy"
            ) claudexAgentNames
            && builtins.all (
              name:
              name != "claudex-proxy"
              &&
                (cfg.launchd.user.agents.${name}.serviceConfig.Label or "")
                != "org.nix-community.home.claudex-proxy"
            ) claudexDarwinAgentNames
            && claudexActivationNames == [ ]
            && !claudexActivationReferencesRuntime;
        }
      ]
    ) expectedDarwinHosts
  );

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
      # Opus 피드백: services.caddy.extraConfig로 site block을 직접 추가하면
      # listenAddresses/default_bind 제약을 모두 우회 가능
      name = "Test 3c: Caddy extraConfig가 비어야 함 (site block 직접 추가로 바인딩 우회 방지)";
      cond = caddyExtraConfig == "";
    }
    {
      # Opus 피드백: vhost extraConfig 내부의 `bind` 디렉티브는 listenAddresses를 오버라이드
      name = "Test 3d: Caddy vhost extraConfig에 bind 디렉티브가 없어야 함 (listenAddresses 우회 방지)";
      cond = noBindInVhosts;
    }
    {
      name = "Test 3e: 모든 subdomain에 대응하는 Caddy virtualHost가 존재해야 함";
      cond = allSubdomainsHaveVhosts;
    }
    {
      name = "Test 4a: Caddy globalConfig에 default_bind ${minipcTailscaleIP}가 포함되어야 함 (줄 끝까지 정확 매칭, 다중 주소 방지)";
      cond = hasDefaultBind;
    }
    {
      # Codex 피드백: default_bind가 중복되면 Caddy는 마지막 값을 사용하므로,
      # 다른 모듈이 default_bind 0.0.0.0을 추가해도 기존 테스트가 통과할 수 있음
      name = "Test 4b: Caddy globalConfig에 default_bind가 정확히 1번만 나타나야 함 (중복 시 마지막 값으로 바인딩 우회 가능)";
      cond = singleDefaultBind;
    }
    {
      # openssh는 LAN 노출 시 brute-force 표면이 되므로, 다른 openFirewall 서비스보다 중요
      # (mosh의 openFirewall은 Test 6b/6e가 이미 잡으므로 별도 테스트 불필요)
      name = "Test 5a: openssh.openFirewall이 false이어야 함 (true이면 LAN에서 SSH 접근 가능)";
      cond = nixosCfg.services.openssh.openFirewall == false;
    }
    # ── 1Password vault 이름 hard pin ────────────────
    # constants.nix 변경 시 GUI vault 이름과의 정합성 회귀 감지
    {
      name = "Test 5b: constants.onePassword.vaults.personal이 \"Personal\"이어야 함";
      cond = constants.onePassword.vaults.personal == "Personal";
    }
    {
      name = "Test 5b-2: constants.onePassword.vaults.automation이 \"Automation\"이어야 함";
      cond = constants.onePassword.vaults.automation == "Automation";
    }
    # op_get account resolution이 의존하는 account 문자열 drift 감지
    {
      name = "Test 5b-3: constants.onePassword.account가 \"my.1password.com\"이어야 함";
      cond = constants.onePassword.account == "my.1password.com";
    }
    # ── opnix SA token materialization 보안 회귀 핀 ──
    {
      name = "Test 5b-4: homeserver.opnix.enable 시 services.onepassword-secrets.enable이 true여야 함";
      cond = nixosCfg.homeserver.opnix.enable && opnixCfg.enable;
    }
    {
      name = "Test 5b-5: opnix githubPat이 tmpfs(/run/opnix/<user>/github-pat)에 matching-user-owned 0400으로 materialize되어야 함 (path: ${opnixGithubPat.path}, mode: ${opnixGithubPat.mode}, owner: ${opnixGithubPat.owner})";
      cond =
        opnixGithubPatPathMatch != null
        && opnixGithubPat.mode == "0400"
        && opnixGithubPat.owner != "root"
        && opnixGithubPat.owner == opnixGithubPatExpectedOwner;
    }
    {
      name = "Test 5b-6: opnix githubPat reference가 op://Automation/github-pat/token이어야 함";
      cond =
        opnixGithubPat.reference == "op://${constants.onePassword.vaults.automation}/github-pat/token";
    }
    {
      # opnix-secrets.service가 tokenFile을 0640 root:onepassword-secrets로 강제하므로 agenix도 동일 선언.
      name = "Test 5b-7: opnix SA tokenFile(agenix)이 0640 root:onepassword-secrets여야 함 (권한 경합 제거)";
      cond =
        opnixTokenSecret.mode == "0640"
        && opnixTokenSecret.owner == "root"
        && opnixTokenSecret.group == "onepassword-secrets";
    }
    {
      # users를 비워 onepassword-secrets group 멤버를 0으로 유지 → 실질 root-only.
      name = "Test 5b-8: opnix users 옵션이 비어야 함 (token group readable이 일반 user로 확산 방지)";
      cond = opnixCfg.users == [ ];
    }
    {
      # gh wrapper(shell/nixos.nix)가 정확한 파일명에 의존 + parent dir 0700 hardening 회귀 방지.
      name = "Test 5b-9: opnix per-user tmpfiles dir이 0700으로 pre-create되어야 함";
      cond = builtins.any (
        rule: builtins.match "d /run/opnix/[^ ]+ 0700 [^ ]+ users -" rule != null
      ) opnixTmpfilesRules;
    }
    {
      # Codex 피드백: SSH 경화 설정은 Tailscale 경계와 독립적인 보안 레이어
      name = "Test 5c: openssh PermitRootLogin이 'no'이어야 함";
      cond = nixosCfg.services.openssh.settings.PermitRootLogin == "no";
    }
    {
      name = "Test 5d: openssh PasswordAuthentication이 false이어야 함 (공개키만 허용)";
      cond = nixosCfg.services.openssh.settings.PasswordAuthentication == false;
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
            "lo" # loopback — 트래픽이 머신 외부로 나가지 않으므로 안전
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
      # Opus 피드백: safeInterfaceUdpPorts allowlist 정확성 (allAllowlistUsed 패턴과 동일)
      name = "Test 6g-2: safeInterfaceUdpPorts의 모든 키가 실제 방화벽 인터페이스에 존재해야 함";
      cond = allSafeInterfaceKeysExist;
    }
    {
      name = "Test 6h: 수동 방화벽 규칙 없음 (extraInputRules, extraForwardRules 비어야 함)";
      cond = noRawFirewallRules;
    }
    {
      name = "Test 6i: extraCommands/extraStopCommands allowlist 검증 (nixos-fw-accept 허용: ${toString expectedFwAcceptCount}건, 실제: ${toString fwAcceptCount}건, karakeep webhook port ${toString karakeepNotifyCfg.webhookPort})";
      cond = extraCommandsAllowed;
    }
    {
      # Opus 피드백: useRoutingFeatures = "both"이면 exit node 활성화 가능
      # "server"는 subnet router만 허용 (exit node 비활성화)
      name = "Test 7a: Tailscale useRoutingFeatures가 server이어야 함 (exit node 방지)";
      cond = nixosCfg.services.tailscale.useRoutingFeatures == "server";
    }
  ]
  ++ [
    {
      name = "Test D9: unexpected Darwin host가 없어야 함 (현재 unexpected: [${builtins.concatStringsSep ", " unexpectedDarwinHosts}])";
      cond = unexpectedDarwinHosts == [ ];
    }
    {
      name = "Test D18: CLIProxyAPI pin은 검증한 v7.2.73 darwin-arm64 자산과 해시여야 함";
      cond =
        claudexPin.version == "7.2.73"
        && claudexPin.tag == "v7.2.73"
        && builtins.attrNames claudexPin.platforms == [ "aarch64-darwin" ]
        && claudexPin.platforms.aarch64-darwin.asset == "CLIProxyAPI_7.2.73_darwin_aarch64.tar.gz"
        && claudexPin.platforms.aarch64-darwin.hash == "sha256-72ZsH3E+lEsk6OIFzoBhN+pxjnuFnlUz8BXo+KmNYqY="
        && claudexPackage.pname == "cli-proxy-api"
        && claudexPackage.version == "7.2.73"
        &&
          claudexPackage.src.url
          == "https://github.com/router-for-me/CLIProxyAPI/releases/download/v7.2.73/CLIProxyAPI_7.2.73_darwin_aarch64.tar.gz"
        && claudexPackage.src.hash == "sha256-72ZsH3E+lEsk6OIFzoBhN+pxjnuFnlUz8BXo+KmNYqY="
        && claudexPackage.meta.mainProgram == "cli-proxy-api"
        && claudexPackage.meta.platforms == [ "aarch64-darwin" ]
        && nixpkgsLib.hasInfix "verify-release-layout.sh" claudexPackage.installPhase
        && nixpkgsLib.hasInfix "install -Dm755 unpacked/cli-proxy-api" claudexPackage.installPhase
        && nixpkgsLib.hasInfix "shopt -s dotglob nullglob" claudexLayoutVerifier
        && nixpkgsLib.hasInfix ''#entries[@]}" -ne 5'' claudexLayoutVerifier
        && nixpkgsLib.hasInfix ''[ -L "$path" ] || [ ! -f "$path" ]'' claudexLayoutVerifier
        && builtins.all (entry: nixpkgsLib.hasInfix entry claudexLayoutVerifier) [
          "LICENSE"
          "README.md"
          "README_CN.md"
          "cli-proxy-api"
          "config.example.yaml"
        ]
        && claudexUnsupportedPackage.success == false;
    }
    {
      name = "Test D19: claudex config template은 관리/플러그인/로그/통계를 끄고 loopback만 허용해야 함";
      cond =
        claudexTemplate.host == "127.0.0.1"
        && claudexTemplate.port == 8317
        && claudexTemplate.tls.enable == false
        && claudexTemplate.remote-management.allow-remote == false
        && claudexTemplate.remote-management.secret-key == ""
        && claudexTemplate.remote-management.disable-control-panel == true
        && claudexTemplate.remote-management.disable-auto-update-panel == true
        && claudexTemplate.auth-dir == ""
        && claudexTemplate.api-keys == [ ]
        && claudexTemplate.debug == false
        && claudexTemplate.pprof.enable == false
        && claudexTemplate.plugins.enabled == false
        && claudexTemplate.commercial-mode == true
        && claudexTemplate.logging-to-file == false
        && claudexTemplate.usage-statistics-enabled == false
        && claudexTemplate.proxy-url == ""
        && claudexTemplate.max-retry-credentials == 1;
    }
  ]
  ++ darwinIntentTests;

  # 모든 테스트를 순차적으로 평가 (실패 시 해당 테스트 이름과 함께 throw)
  runTests = builtins.foldl' (acc: t: if acc then check t.name t.cond true else acc) true tests;

in
runTests
