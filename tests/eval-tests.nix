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
  personalDarwinHosts = [
    "greenhead-MacBookPro"
  ];
  expectedDarwinHosts = personalDarwinHosts ++ [
    "work-MacBookPro"
  ];
  claudexTargetHosts = [
    "greenhead-MacBookPro"
    "work-MacBookPro"
    "greenhead-minipc"
  ];
  darwinHostNames = builtins.attrNames darwinCfgs;
  unexpectedDarwinHosts = builtins.filter (
    name: !(builtins.elem name expectedDarwinHosts)
  ) darwinHostNames;

  # Claudex static inputs. These are parsed directly so a pin/template-only change is
  # covered without ever executing the upstream CLIProxyAPI binary.
  claudexPin = builtins.fromJSON (
    builtins.readFile ../modules/shared/programs/claudex/cli-proxy-api-pin.json
  );
  claudexTemplate = builtins.fromJSON (
    builtins.readFile ../modules/shared/programs/claudex/files/config-template.json
  );
  claudexDisabledFixture = import ./fixtures/claudex-home.nix {
    inherit flake;
    hostname = "claudex-disabled-fixture";
  };
  claudexEnabledFixture = import ./fixtures/claudex-home.nix {
    inherit flake;
    hostname = "greenhead-MacBookPro";
  };
  claudexAlternateProxyFixture = import ./fixtures/claudex-home.nix {
    inherit flake;
    hostname = "greenhead-MacBookPro";
    proxyFixtureTag = "alternate";
  };
  claudexDisabledHm = claudexDisabledFixture.config;
  claudexEnabledHm = claudexEnabledFixture.config;
  claudexDisabledDescriptor = builtins.fromJSON (
    claudexDisabledHm.home.file.".config/claudex/runtime.json".text
  );
  claudexEnabledDescriptor = builtins.fromJSON (
    claudexEnabledHm.home.file.".config/claudex/runtime.json".text
  );
  claudexAlternateProxyDescriptor = builtins.fromJSON (
    claudexAlternateProxyFixture.config.home.file.".config/claudex/runtime.json".text
  );
  claudexDisabledPublicFiles = [
    ".local/bin/claudex"
    ".local/libexec/claudex/claudex-proxy-launcher"
  ];
  claudexDisabledRuntimeSource = claudexDisabledHm.home.file.".local/lib/claudex/runtime.sh".source;
  # getContext exposes .drv path names but does not guarantee that those store files exist in a
  # clean eval store. Inspect replaceVars' evaluator-owned phase instead of reading the store.
  claudexDisabledRuntimeBuildPhase = claudexDisabledRuntimeSource.buildPhase;
  claudexDisabledRuntimeReferencesProxy = nixpkgsLib.hasInfix "cli-proxy-api" claudexDisabledRuntimeBuildPhase;
  claudexEnabledRuntimeSource = claudexEnabledHm.home.file.".local/lib/claudex/runtime.sh".source;
  claudexEnabledRuntimeBuildPhase = claudexEnabledRuntimeSource.buildPhase;
  claudexEnabledRuntimeBuildPhaseMatchesDescriptor =
    nixpkgsLib.hasInfix "--replace-fail @bindHost@ ${claudexEnabledDescriptor.bindHost}" claudexEnabledRuntimeBuildPhase
    && nixpkgsLib.hasInfix "--replace-fail @port@ ${toString claudexEnabledDescriptor.port}" claudexEnabledRuntimeBuildPhase
    # Descriptor `.model` is the defaultMainModel alias; the role-split subagent/mixed
    # substitutions exist without a descriptor field (wrapper-internal contract).
    && nixpkgsLib.hasInfix "--replace-fail @defaultMainModel@ ${claudexEnabledDescriptor.model}" claudexEnabledRuntimeBuildPhase
    && nixpkgsLib.hasInfix "--replace-fail @subagentModel@ gpt-5.6-sol" claudexEnabledRuntimeBuildPhase
    && nixpkgsLib.hasInfix "--replace-fail @mixedMainModel@ claude-opus-4-8" claudexEnabledRuntimeBuildPhase
    && nixpkgsLib.hasInfix "--replace-fail @label@ ${claudexEnabledDescriptor.label}" claudexEnabledRuntimeBuildPhase
    && nixpkgsLib.hasInfix "--replace-fail @stateDir@ " claudexEnabledRuntimeBuildPhase
    && nixpkgsLib.hasInfix claudexEnabledDescriptor.stateDir claudexEnabledRuntimeBuildPhase
    && nixpkgsLib.hasInfix "--replace-fail @authDir@ " claudexEnabledRuntimeBuildPhase
    && nixpkgsLib.hasInfix claudexEnabledDescriptor.authDir claudexEnabledRuntimeBuildPhase
    && nixpkgsLib.hasInfix "--replace-fail @configFile@ " claudexEnabledRuntimeBuildPhase
    && nixpkgsLib.hasInfix claudexEnabledDescriptor.configFile claudexEnabledRuntimeBuildPhase;
  fakeClaudexPkgs =
    system:
    let
      fakeStorePath = name: "/nix/store/00000000000000000000000000000000-${name}";
      # package.nix branches on the host platform to patch the linux ELF interpreter, so the
      # fake platform has to answer isLinux/isDarwin the way a real nixpkgs platform would.
      isLinux = nixpkgsLib.hasSuffix "-linux" system;
    in
    {
      fetchurl = attrs: attrs;
      lib = {
        concatStringsSep = builtins.concatStringsSep;
        licenses.mit = "MIT";
        sourceTypes.binaryNativeCode = "binaryNativeCode";
        optionals = nixpkgsLib.optionals;
      };
      stdenvNoCC = {
        hostPlatform = {
          inherit system isLinux;
          isDarwin = !isLinux;
        };
        mkDerivation = attrs: attrs;
      };
      autoPatchelfHook = fakeStorePath "auto-patchelf-hook";
      stdenv.cc.cc.lib = fakeStorePath "gcc-lib";
      gnutar = fakeStorePath "gnutar";
      findutils = fakeStorePath "findutils";
      coreutils = fakeStorePath "coreutils";
      bash = fakeStorePath "bash";
    };
  claudexPackage = import ../modules/shared/programs/claudex/package.nix {
    pkgs = fakeClaudexPkgs "aarch64-darwin";
  };
  claudexLinuxPackage = import ../modules/shared/programs/claudex/package.nix {
    pkgs = fakeClaudexPkgs "x86_64-linux";
  };
  # aarch64-linux keeps probing the unsupported-system throw: upstream does publish an asset
  # for it, but no host needs it, so it stays unpinned and must still fail loudly.
  claudexUnsupportedPackage = builtins.tryEval (
    (import ../modules/shared/programs/claudex/package.nix {
      pkgs = fakeClaudexPkgs "aarch64-linux";
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

  expectedDarwinSudoRule = cfg: "${cfg.system.primaryUser} ALL=(ALL) NOPASSWD: ALL";

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

  # Remote TCC 정책 자체는 host runtime state라 eval 대상이 아니다. 대신 선택한 C/D 정책이
  # 의존하는 선언 surface(앱 설치, launcher 복구, Claude internal allowlist)만 잠근다.
  claudeSettings = builtins.fromJSON (
    builtins.readFile ../modules/shared/programs/claude/files/settings.json
  );
  claudeRcFlockSelector = import ../libraries/claude-rc-flock.nix;
  fakeFlockPkgs = isLinux: {
    stdenv = { inherit isLinux; };
    util-linux = "util-linux";
    flock = "discoteq-flock";
  };
  claudeRcLinuxFlock = claudeRcFlockSelector { pkgs = fakeFlockPkgs true; };
  claudeRcDarwinFlock = claudeRcFlockSelector { pkgs = fakeFlockPkgs false; };
  expectedClaudeAdditionalDirectories = [ "~/Workspace" ];

  normalizedCaskName = cask: if builtins.isAttrs cask then cask.name else cask;
  ghosttyCaskCount =
    cfg:
    builtins.length (builtins.filter (cask: normalizedCaskName cask == "ghostty") cfg.homebrew.casks);
  # Ghostty AppSupport 스텁 (#1232): macOS에서 XDG보다 나중에 로드되어 이기는 슬롯.
  # 스텁에 설정 지시어가 들어가는 순간 Nix 선언을 덮는 override 레이어가 부활한다.
  ghosttyAppSupportPath = "Library/Application Support/com.mitchellh.ghostty/config";
  # Ghostty 지시어는 전부 key = value 형태다. 주석·빈 줄만 남았는지로 불활성을 판정한다.
  ghosttyStubIsInert =
    text:
    text != ""
    && builtins.all (line: builtins.match "[[:space:]]*(#.*)?" line != null) (
      nixpkgsLib.splitString "\n" text
    );

  claudeRcAgent =
    cfg: cfg.home-manager.users.${cfg.system.primaryUser}.launchd.agents.claude-rc-ensure;
  claudeRcDeclaredInstances =
    cfg: builtins.fromJSON (claudeRcAgent cfg).config.EnvironmentVariables.CLAUDE_RC_DECLARED_INSTANCES;
  shottrActivation = cfg: cfg.home-manager.users.${cfg.system.primaryUser}.home.activation;
  shottrActivationEntryNames = [
    "checkShottrFolderAndWarn"
    "applyShottrCoreSettings"
    "applyShottrLicenseFromSecret"
  ];
  hasShottrActivationEntries =
    activation:
    builtins.all (
      name:
      builtins.hasAttr name activation
      && builtins.isAttrs activation.${name}
      && activation.${name} ? data
      && builtins.isString activation.${name}.data
    ) shottrActivationEntryNames;

  darwinIntentTests = builtins.concatLists (
    map (
      hostName:
      let
        hasHost = builtins.hasAttr hostName darwinCfgs;
        cfg = if hasHost then darwinCfgs.${hostName}.config else null;
        hm = if hasHost then cfg.home-manager.users.${cfg.system.primaryUser} else null;
        # personal 호스트 판정: minipc matchBlock은 hostType==personal에서만 정의되므로(ssh 모듈),
        # 이 존재 여부가 hostType의 견고한 프록시다. ssh() wrapper(shell 모듈) 삭제와 독립이라,
        # wrapper가 사라져도 personal 판정이 유지돼 D19/D20 마커 검증이 회귀를 잡는다.
        isPersonalHost = hasHost && (hm.programs.ssh.settings ? "minipc");
        claudexDescriptorPath = ".config/claudex/runtime.json";
        hasClaudexDescriptor = hasHost && builtins.hasAttr claudexDescriptorPath hm.home.file;
        claudexDescriptor =
          if hasClaudexDescriptor then builtins.fromJSON hm.home.file.${claudexDescriptorPath}.text else null;
        claudexShouldEnable = builtins.elem hostName claudexTargetHosts;
        claudexPublicFiles = [
          ".local/bin/claudex"
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
        claudexRuntimeBuildPhase =
          if claudexRuntimeSource != null then claudexRuntimeSource.buildPhase else "";
        claudexRuntimeReferencesProxy = nixpkgsLib.hasInfix "cli-proxy-api" claudexRuntimeBuildPhase;
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
          name = "Test D2 ${hostName}: sudo.extraConfig 정규화 후 전면 NOPASSWD 규칙 1줄만 남아야 함";
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
            && claudexDescriptor.schema == 3
            && claudexDescriptor.hostName == hostName
            && claudexDescriptor.targetHosts == claudexTargetHosts
            && claudexDescriptor.label == "org.nix-community.home.claudex-proxy"
            && claudexDescriptor.bindHost == "127.0.0.1"
            && claudexDescriptor.port == 8317
            && claudexDescriptor.model == "gpt-5.6-sol"
            && claudexDescriptor.readiness.method == "GET"
            && claudexDescriptor.readiness.url == "http://127.0.0.1:8317/v1/models"
            && claudexDescriptor.readiness.catalogIsEntitlement == false
            && claudexDescriptor.lifecycle.autoStart == "first-session"
            && claudexDescriptor.lifecycle.platform == "launchd"
            && claudexDescriptor.lifecycle.restart == "on-failure"
            && claudexDescriptor.lifecycle.gracefulDrainSeconds == 30
            && !(claudexDescriptor ? launchAgentPlist);
        }
        {
          name = "Test D16 ${hostName}: claudex 실행 표면은 승인된 Darwin 호스트에만 노출되어야 함";
          cond =
            hasClaudexDescriptor
            && claudexDescriptor.enabled == claudexShouldEnable
            && builtins.all (path: builtins.hasAttr path hm.home.file == claudexShouldEnable) claudexPublicFiles
            && (
              if claudexShouldEnable then
                claudexDescriptor.proxyVersion == "7.2.111"
                && claudexDescriptor.command != null
                && builtins.length claudexDescriptor.command == 2
                && claudexDescriptor.proxyExecutable != null
                && claudexDescriptor.gateExecutable != null
                && claudexDescriptor.generation != null
                && claudexDescriptor.source != null
                && builtins.elemAt claudexDescriptor.command 0 == claudexDescriptor.proxyLauncher
                && builtins.elemAt claudexDescriptor.command 1 == "--managed"
                && nixpkgsLib.hasSuffix "/bin/cli-proxy-api" claudexDescriptor.proxyExecutable
                && nixpkgsLib.hasSuffix "/bin/claudex-gate" claudexDescriptor.gateExecutable
                && toString hm.home.file.".local/bin/claudex".source == "${claudexDescriptor.source}/bin/claudex"
                &&
                  toString hm.home.file.".local/libexec/claudex/claudex-proxy-launcher".source
                  == claudexDescriptor.proxyLauncher
              else
                claudexDescriptor.proxyVersion == null
                && claudexDescriptor.command == null
                && claudexDescriptor.proxyExecutable == null
                && claudexDescriptor.gateExecutable == null
                && claudexDescriptor.proxyLauncher == null
                && claudexDescriptor.generation == null
                && claudexDescriptor.source == null
            )
            && !(builtins.hasAttr ".local/bin/claudex-login" hm.home.file)
            && !(builtins.hasAttr ".local/bin/claudex-status" hm.home.file)
            && !claudexRuntimeReferencesProxy;
        }
        {
          name = "Test D17 ${hostName}: claudex launchd 정의는 로그인 시 자동 활성화되지 않아야 함";
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
        {
          # op_get 무인 SA 폴백(#1041/#1094 인접 DX) 회귀 핀 — 구현 형태가 아니라 계약 마커를 잠근다:
          # (1) SA token 경로 상수(constants.onePassword.saTokenMacRelPath)가 initContent에 배선됨
          #     (무인 경로 존재 — 경로는 상수와 동일 소스이므로 경로 정책 변경에도 테스트가 따라간다).
          # (2) biometric opt-in 플래그(OP_GET_BIOMETRIC)가 존재 — 이 마커가 사라지면 무인 컨텍스트
          #     biometric 차단 가드가 통째로 제거된 것이므로 원격/LLM 셸의 승인 대기 hang 회귀다.
          name = "Test D18 ${hostName}: op_get 무인 SA 폴백 배선 + biometric opt-in 가드 마커가 initContent에 있어야 함";
          cond =
            hasHost
            && (
              let
                zshInit = hm.programs.zsh.initContent;
              in
              nixpkgsLib.hasInfix constants.onePassword.saTokenMacRelPath zshInit
              && nixpkgsLib.hasInfix "OP_GET_BIOMETRIC" zshInit
            );
        }
        {
          # launcher/snapshot/background-scoped D 계약(#1094): stable private PATH는
          # personal Darwin의 marked child, Claude tool 셸, background session에만
          # 배선한다. vendor snapshot은 zsh 평가 PATH가 아니라 claude process.env.PATH를
          # 리터럴 기록하므로(2026-08-24 실측) rc 캡처에 의존하지 않고, snapshot 계층은
          # 멱등 append 수리를 activation(nrs 시점) + launchd WatchPaths agent(상시)
          # 두 곳에 배선해야 `timeout ssh`가 raw SSH로 새지 않는다.
          # 전역 sessionPath에는 넣지 않아 interactive Ghostty/일반 SSH를 보존한다.
          name = "Test D19 ${hostName}: headless SSH dispatcher는 personal agent child에만 배선되어야 함";
          cond =
            hasHost
            && (
              let
                stableRoot = "${hm.home.homeDirectory}/${constants.paths.headlessSshDispatcherRelPath}";
                stableBin = "${stableRoot}/bin";
                zshEnv = hm.programs.zsh.envExtra;
                zshInit = hm.programs.zsh.initContent;
                snapshotRefresh = hm.home.activation.refreshClaudeShellSnapshotPaths.data or "";
                agentEnv = (claudeRcAgent cfg).config.EnvironmentVariables;
                hasDispatcher = builtins.hasAttr constants.paths.headlessSshDispatcherRelPath hm.home.file;
                snapshotDir = "${hm.home.homeDirectory}/.claude/shell-snapshots";
                repairAgent = hm.launchd.agents.claude-snapshot-path-repair or null;
                repairAgentArgs = if repairAgent == null then [ ] else repairAgent.config.ProgramArguments or [ ];
              in
              if isPersonalHost then
                hasDispatcher
                && nixpkgsLib.hasInfix "NIXOS_CONFIG_HEADLESS_SSH" zshEnv
                && nixpkgsLib.hasInfix "CLAUDECODE" zshEnv
                && nixpkgsLib.hasInfix "CLAUDE_CODE_SESSION_KIND" zshEnv
                && nixpkgsLib.hasInfix "= \"bg\"" zshEnv
                && nixpkgsLib.hasInfix stableBin zshEnv
                && nixpkgsLib.hasInfix "BEGIN nixos-config headless SSH snapshot PATH finalizer" zshInit
                && nixpkgsLib.hasInfix stableBin zshInit
                && nixpkgsLib.hasInfix "refresh-claude-snapshot-paths.sh" snapshotRefresh
                && nixpkgsLib.hasInfix stableBin snapshotRefresh
                && !(builtins.elem stableBin hm.home.sessionPath)
                && (agentEnv.NIXOS_CONFIG_HEADLESS_SSH or "") == "1"
                && nixpkgsLib.hasPrefix "${stableBin}:" agentEnv.PATH
                && (repairAgent != null)
                && (repairAgent.enable or false)
                && nixpkgsLib.any (nixpkgsLib.hasInfix "refresh-claude-snapshot-paths.sh") repairAgentArgs
                && builtins.elem snapshotDir repairAgentArgs
                && builtins.elem stableBin repairAgentArgs
                && builtins.elem snapshotDir (repairAgent.config.WatchPaths or [ ])
                && (repairAgent.config.RunAtLoad or false)
              else
                !hasDispatcher
                && !nixpkgsLib.hasInfix stableBin zshEnv
                && !nixpkgsLib.hasInfix stableBin zshInit
                && !nixpkgsLib.hasInfix "CLAUDECODE" zshEnv
                && !nixpkgsLib.hasInfix "CLAUDE_CODE_SESSION_KIND" zshEnv
                && snapshotRefresh == ""
                && (agentEnv.NIXOS_CONFIG_HEADLESS_SSH or "") == ""
                && !nixpkgsLib.hasInfix stableBin agentEnv.PATH
                && (repairAgent == null)
            );
        }
        {
          # agenix 영속 배치 계약 (2026-08-24 dirhelper 소실 재발 방지): darwin HM
          # 시크릿은 $TMPDIR(dirhelper 3일 미접근 청소 대상)가 아닌 영속 위치
          # (constants.paths.agenixDarwinSecretsRelPath)에 복호화되고, stale cleanup도
          # 같은 값(secretsMountPoint 단일 소스)을 봐야 한다.
          # darwin per-host 리스트의 번호는 NixOS 전역 리스트와 네임스페이스가 분리다
          # (D20이 양쪽에 독립 존재). 이 리스트의 기존 최댓값 D33(한국어 입력기) 다음.
          name = "Test D34 ${hostName}: agenix secretsDir는 dirhelper 청소권 밖 영속 경로여야 함";
          cond =
            hasHost
            && (
              let
                persistentRoot = "${hm.home.homeDirectory}/${constants.paths.agenixDarwinSecretsRelPath}";
                cleanupData = hm.home.activation.cleanupAgenixStaleGenerations.data or "";
              in
              hm.age.secretsDir == persistentRoot
              && hm.age.secretsMountPoint == "${persistentRoot}.d"
              && nixpkgsLib.hasInfix "${persistentRoot}.d" cleanupData
              && !nixpkgsLib.hasInfix "DARWIN_USER_TEMP_DIR" cleanupData
            );
        }
        {
          # C + D 계약: headless alias는 1Password agent를 사용하지 않고, Codex
          # child marker와 personal dispatcher가 함께 존재한다. 기존의 전체 remote
          # command timeout 구현은 다시 들어오면 안 된다(장시간 명령 DX 보존).
          name = "Test D20 ${hostName}: C key alias와 Claude/Codex auth-phase dispatcher 계약";
          cond =
            hasHost
            && (
              let
                zshInit = hm.programs.zsh.initContent;
                stableBin = "${hm.home.homeDirectory}/${constants.paths.headlessSshDispatcherRelPath}/bin";
                sshSettings = hm.programs.ssh.settings;
                codexDarwinConfig = builtins.readFile ../modules/shared/programs/codex/files/config.darwin.toml;
              in
              if isPersonalHost then
                (sshSettings ? "minipc-headless")
                && ((sshSettings."minipc-headless".data.IdentityAgent or "") == "none")
                && (
                  (sshSettings."minipc-headless".data.IdentityFile or "")
                  == "${hm.home.homeDirectory}/${constants.onePassword.headlessKeyRelPath}"
                )
                && nixpkgsLib.hasInfix "NIXOS_CONFIG_HEADLESS_SSH = \"1\"" codexDarwinConfig
                && nixpkgsLib.hasInfix "${stableBin}/ssh" zshInit
                && nixpkgsLib.hasInfix "SSH_CONNECTION" zshInit
                && nixpkgsLib.hasInfix "CLAUDE_CODE_SESSION_KIND" zshInit
                && !nixpkgsLib.hasInfix "timeout \"$_ssh_deadline\" ssh" zshInit
                && !nixpkgsLib.hasInfix "timeout \"$_hdl_deadline\" ssh" zshInit
              else
                true
            );
        }
        {
          # Termius mobile-ssh는 개인 Mac 원격 접속용 신원이다. work Mac까지
          # 허용하면 공유 모바일 키의 blast radius가 업무 호스트로 확장되므로,
          # personal에는 정확히 1개·work에는 0개인 양방향 계약을 최종 평가값에서 검증한다.
          name = "Test D23 ${hostName}: mobile-ssh authorized key는 personal Mac에만 정확히 1개 있어야 함";
          cond =
            hasHost
            && (
              let
                authorizedKeys = cfg.users.users.${cfg.system.primaryUser}.openssh.authorizedKeys.keys;
                mobileKeyCount = builtins.length (
                  builtins.filter (key: key == constants.sshDeviceKeys.mobile) authorizedKeys
                );
              in
              if builtins.elem hostName personalDarwinHosts then mobileKeyCount == 1 else mobileKeyCount == 0
            );
        }
        {
          name = "Test D23b ${hostName}: Ghostty.app cask가 정확히 한 번 선언되어야 함";
          cond = hasHost && ghosttyCaskCount cfg == 1;
        }
        {
          name = "Test D23c ${hostName}: Ghostty AppSupport config를 Nix가 점유하고 설정 지시어가 0줄이어야 함";
          cond =
            hasHost
            && builtins.hasAttr ghosttyAppSupportPath hm.home.file
            && ghosttyStubIsInert (hm.home.file.${ghosttyAppSupportPath}.text or "");
        }
        {
          name = "Test D23d ${hostName}: shift+enter keybind의 백슬래시가 리터럴로 보존되어야 함";
          cond =
            hasHost
            && nixpkgsLib.hasInfix ''keybind = shift+enter=text:\n'' (
              hm.xdg.configFile."ghostty/config".text or ""
            );
        }
        {
          name = "Test D24 ${hostName}: Claude Remote Control ensure가 login 및 1분 주기로 자동 복구되어야 함";
          cond =
            hasHost
            && (
              let
                agent = claudeRcAgent cfg;
              in
              agent.enable
              && agent.config.RunAtLoad
              && agent.config.StartInterval == 60
              && agent.config.AbandonProcessGroup
              && agent.config.EnvironmentVariables.CLAUDE_RC_DRIFT_POLICY == "defer"
            );
        }
        {
          name = "Test D25 ${hostName}: Claude Remote Control launchd argv가 maint ensure만 실행해야 함";
          cond =
            hasHost
            && (
              let
                args = (claudeRcAgent cfg).config.ProgramArguments;
              in
              builtins.length args == 2
              && builtins.match ".*/claude-rc-maint" (builtins.elemAt args 0) != null
              && builtins.elemAt args 1 == "ensure"
            );
        }
        {
          name = "Test D25b ${hostName}: Claude RC maint 수동 경로가 personal에서 headless launcher를 사용해야 함";
          cond =
            hasHost
            && (
              let
                source = toString hm.home.file.".local/bin/claude-rc-maint".source;
                isPersonal = builtins.elem hostName personalDarwinHosts;
              in
              builtins.match ".*/claude-rc-maint" source != null
              && (
                if isPersonal then
                  nixpkgsLib.hasInfix "claude-rc-maint-headless-launcher" source
                else
                  !nixpkgsLib.hasInfix "claude-rc-maint-headless-launcher" source
              )
            );
        }
        {
          name = "Test D26 ${hostName}: 선언 Claude Remote Control instance가 worktree+bypassPermissions 단일 entry여야 함";
          cond =
            hasHost
            && (
              let
                instances = claudeRcDeclaredInstances cfg;
                instance = if builtins.length instances == 1 then builtins.elemAt instances 0 else null;
              in
              instance != null
              &&
                builtins.attrNames instance == [
                  "capacity"
                  "path"
                  "permissionMode"
                  "spawn"
                ]
              && instance.spawn == "worktree"
              && instance.permissionMode == "bypassPermissions"
              && instance.capacity == null
              && instance.path == "${hm.home.homeDirectory}/Workspace/nixos-config"
            );
        }
        {
          name = "Test D27 ${hostName}: Shottr의 선언된 activation entries가 모두 존재해야 함";
          cond = hasHost && hasShottrActivationEntries (shottrActivation cfg);
        }
        {
          name = "Test D33 ${hostName}: 한국어 입력기 삭제 방식이 글자 단위(DeleteBy=2)로 선언되어야 함";
          cond =
            hasHost && cfg.system.defaults.CustomUserPreferences."com.apple.inputmethod.Korean".DeleteBy == 2;
        }
      ]
    ) expectedDarwinHosts
  );

  # ═══════════════════════════════════════════════════════════════
  # 테스트 실행
  # ═══════════════════════════════════════════════════════════════

  # ── private job runner (#1135): generic 계약(unit 경로·hardening·bounded
  # timeout·sync cadence·linger) 고정 — 작업 실체는 기기 로컬 소유라 여기 없다.
  claudexNixosHm = nixosCfg.home-manager.users.${constants.username or "greenhead"};
  claudexNixosDescriptor = builtins.fromJSON (
    claudexNixosHm.home.file.".config/claudex/runtime.json".text
  );
  claudexNixosService = claudexNixosHm.systemd.user.services.claudex-proxy;
  pjTemplate = nixosCfg.systemd.user.services."private-job@";
  pjSync = nixosCfg.systemd.user.services."private-jobs-sync";
  pjSyncTimer = nixosCfg.systemd.user.timers."private-jobs-sync";
  pjHardeningOk =
    svc:
    svc.serviceConfig.UMask == "0077"
    && svc.serviceConfig.NoNewPrivileges == true
    && svc.serviceConfig.PrivateTmp == true
    && svc.serviceConfig.ProtectSystem == "full"
    && svc.serviceConfig.KillMode == "control-group";
  # RestrictNamespaces는 의도적으로 미적용이다 — 일부 작업의 하위 도구가 user
  # namespace를 요구한다 (모듈 주석의 결정을 여기서 고정: 켜면 이 테스트가 깨져
  # 의도적 재결정을 강제한다).
  pjNoNamespaceRestriction =
    !(pjTemplate.serviceConfig ? RestrictNamespaces) && !(pjSync.serviceConfig ? RestrictNamespaces);
  pjBoundedTimeout =
    pjTemplate.serviceConfig.TimeoutStartSec == "8h" && pjSync.serviceConfig.TimeoutStartSec == "5min";
  pjLingerOn = nixosCfg.users.users.${constants.username or "greenhead"}.linger or false;

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
      # 무인 headless 키(#1094 C안)의 blast radius 제한 회귀 핀 — from=(Mac Tailscale IP)로
      # 출발지를 제한하고 no-*-forwarding으로 포워딩(피벗)을 차단하는 옵션이 authorized_keys
      # 엔트리에 반드시 함께 있어야 한다. 이 옵션이 빠지면 headless 키가 무제한 신원이 된다.
      name = "Test 5e: minipc headless authorized_key에 from=(Mac IP) + no-forwarding 제한이 있어야 함";
      cond =
        let
          keys = nixosCfg.users.users.greenhead.openssh.authorizedKeys.keys;
          hl = builtins.filter (k: nixpkgsLib.hasInfix "minipc-headless" k) keys;
        in
        builtins.length hl == 1
        && nixpkgsLib.hasInfix ''from="${constants.network.macbookTailscaleIP}"'' (builtins.head hl)
        && nixpkgsLib.hasInfix "no-port-forwarding" (builtins.head hl)
        && nixpkgsLib.hasInfix "no-agent-forwarding" (builtins.head hl)
        && nixpkgsLib.hasInfix "no-X11-forwarding" (builtins.head hl);
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
    # 셸 startup 최적화 회귀 lock — modules/nixos/configuration.nix.
    # darwin D10-D12와 같은 불변식 쌍을 NixOS에도 잠근다. 타이밍이 아닌 config-level만 검증
    # (결정론적, 부하 무관). 이 호스트 실측으로 동일 병리를 확인했다: /etc/zshrc의 compinit이
    # home-manager 사용자 compinit과 중복 실행되고, prompt suse는 Starship이 덮어써 사문이다.
    {
      name = "Test 8a: NixOS 시스템 compinit 중복 제거 — enableGlobalCompInit이 false여야 함";
      cond = nixosCfg.programs.zsh.enableGlobalCompInit == false;
    }
    {
      name = "Test 8b: NixOS 사문 promptinit 제거 — promptInit이 빈 문자열이어야 함 (Starship이 프롬프트를 덮어씀)";
      cond = nixosCfg.programs.zsh.promptInit == "";
    }
    {
      # 8a가 시스템 compinit을 제거하므로 사용자 compinit이 유일 정본이 되어야 한다.
      # 부정 불변식(8a)과 긍정 불변식(이 테스트)을 한 쌍으로 잠가 단일-정본 추상화를 보호한다.
      # 검증 대상 enableCompletion/completionInit은 이 repo가 명시 설정하지 않고 home-manager
      # 업스트림 기본값에 의존한다 — repo를 grep해도 설정이 안 나오는 이유다. 깨지면
      # (enableCompletion=false / oh-my-zsh·prezto 도입 / 업스트림 변경) 이 호스트의 셸 completion이
      # 전면 사망하므로 framework 기본값을 의도적으로 잠근다.
      name = "Test 8c: NixOS 시스템 compinit 제거의 짝 — 사용자(home-manager) compinit이 단일 정본으로 존재해야 함";
      cond =
        let
          # NixOS에는 darwin의 system.primaryUser 옵션이 없으므로 home-manager.users의 실제 키를
          # 사용한다(이 호스트는 사용자 1명 — 늘어나면 이 단언이 먼저 깨져 재검토를 강제한다).
          hmUsers = builtins.attrNames nixosCfg.home-manager.users;
          hmZsh = nixosCfg.home-manager.users.${builtins.head hmUsers}.programs.zsh;
        in
        builtins.length hmUsers == 1
        && hmZsh.enableCompletion
        # builtins.match는 전체-문자열 앵커(부분 매치 아님)라 .* 래핑이 필요하고, POSIX ERE의 `.`은
        # newline을 매치하지 않아 completionInit이 멀티라인이면 전체 매치가 실패하므로 newline을
        # 공백으로 평탄화한다(현 HM 기본값은 단일 라인이라 평탄화는 방어적 no-op).
        #
        # `compinit` 부분 문자열이 아니라 초기화 시퀀스 전체를 요구한다. 부분 문자열만 보면
        # `# compinit은 나중에` 같은 주석이나 compinit을 실제로 호출하지 않는 값도 통과해,
        # "사용자 compinit이 단일 정본으로 살아있다"는 이 테스트의 불변식이 헐거워진다.
        # 현 HM 기본값(실측: `autoload -U compinit && compinit`)과 정확히 대응하며, 업스트림이
        # 이 시퀀스를 바꾸면 의도대로 여기서 먼저 깨져 재검토를 강제한다.
        &&
          builtins.match ".*autoload -U compinit && compinit.*" (
            builtins.replaceStrings [ "\n" ] [ " " ] hmZsh.completionInit
          ) != null;
    }
  ]
  ++ [
    {
      name = "Test D9: unexpected Darwin host가 없어야 함 (현재 unexpected: [${builtins.concatStringsSep ", " unexpectedDarwinHosts}])";
      cond = unexpectedDarwinHosts == [ ];
    }
    {
      name = "Test D18: CLIProxyAPI pin은 검증한 v7.2.111 darwin-arm64/linux-amd64 자산과 해시여야 함";
      cond =
        claudexPin.version == "7.2.111"
        && claudexPin.tag == "v7.2.111"
        &&
          builtins.attrNames claudexPin.platforms == [
            "aarch64-darwin"
            "x86_64-linux"
          ]
        && claudexPin.platforms.aarch64-darwin.asset == "CLIProxyAPI_7.2.111_darwin_aarch64.tar.gz"
        && claudexPin.platforms.aarch64-darwin.hash == "sha256-WJIoDb5yaEzj9/MDu2B6GHFkosd7gRA2q+729o1NE/E="
        && claudexPin.platforms.x86_64-linux.asset == "CLIProxyAPI_7.2.111_linux_amd64.tar.gz"
        && claudexPin.platforms.x86_64-linux.hash == "sha256-wYxPvd0UaFZuSuXSYnkcM0PTuZpCLxBnHqcTneyyHoU="
        && claudexPackage.pname == "cli-proxy-api"
        && claudexPackage.version == "7.2.111"
        &&
          claudexPackage.src.url
          == "https://github.com/router-for-me/CLIProxyAPI/releases/download/v7.2.111/CLIProxyAPI_7.2.111_darwin_aarch64.tar.gz"
        && claudexPackage.src.hash == "sha256-WJIoDb5yaEzj9/MDu2B6GHFkosd7gRA2q+729o1NE/E="
        && claudexPackage.meta.mainProgram == "cli-proxy-api"
        &&
          claudexPackage.meta.platforms == [
            "aarch64-darwin"
            "x86_64-linux"
          ]
        && nixpkgsLib.hasInfix "verify-release-layout.sh" claudexPackage.installPhase
        && nixpkgsLib.hasInfix "install -Dm755 unpacked/cli-proxy-api" claudexPackage.installPhase
        && claudexUnsupportedPackage.success == false;
    }
    {
      # 의도된 플랫폼 비대칭을 잠근다: linux prebuilt는 glibc 동적 링크에 FHS interpreter
      # (/lib64/ld-linux-x86-64.so.2)를 달고 오므로 NixOS에서 patch 없이는 실행 자체가 불가하고,
      # darwin prebuilt는 반대로 Mach-O 서명을 건드리면 안 되므로 patch를 끈 채 둬야 한다.
      name = "Test D18b: claudex linux 패키지는 linux-amd64 자산을 ELF patch 경로로 설치해야 함";
      cond =
        claudexLinuxPackage.src.url
        == "https://github.com/router-for-me/CLIProxyAPI/releases/download/v7.2.111/CLIProxyAPI_7.2.111_linux_amd64.tar.gz"
        && claudexLinuxPackage.src.hash == "sha256-wYxPvd0UaFZuSuXSYnkcM0PTuZpCLxBnHqcTneyyHoU="
        && claudexLinuxPackage.dontPatchELF == false
        && claudexLinuxPackage.nativeBuildInputs != [ ]
        && claudexLinuxPackage.buildInputs != [ ]
        && claudexPackage.dontPatchELF == true
        && claudexPackage.nativeBuildInputs == [ ]
        && claudexPackage.buildInputs == [ ];
    }
    {
      name = "Test D19: claudex config base는 runtime slot을 비우고 관리/플러그인/로그/통계를 꺼야 함";
      cond =
        claudexTemplate.host == null
        && claudexTemplate.port == null
        && claudexTemplate.tls.enable == false
        && claudexTemplate.remote-management.allow-remote == false
        && claudexTemplate.remote-management.secret-key == ""
        && claudexTemplate.remote-management.disable-control-panel == true
        && claudexTemplate.remote-management.disable-auto-update-panel == true
        && claudexTemplate.auth-dir == ""
        && claudexTemplate.api-keys == [ ]
        && claudexTemplate.debug == false
        && claudexTemplate.pprof.enable == false
        && claudexTemplate.pprof.addr == null
        && claudexTemplate.plugins.enabled == false
        && claudexTemplate.commercial-mode == true
        && claudexTemplate.logging-to-file == false
        && claudexTemplate.usage-statistics-enabled == false
        && claudexTemplate.proxy-url == ""
        && claudexTemplate.max-retry-credentials == 1;
    }
    {
      name = "Test D20: synthetic disabled Claudex host는 metadata만 남기고 실행 표면을 노출하지 않아야 함";
      cond =
        !(builtins.elem claudexDisabledFixture.hostname claudexTargetHosts)
        && claudexDisabledDescriptor.schema == 3
        && claudexDisabledDescriptor.hostName == claudexDisabledFixture.hostname
        && claudexDisabledDescriptor.targetHosts == claudexTargetHosts
        && claudexDisabledDescriptor.enabled == false
        && claudexDisabledDescriptor.source == null
        && claudexDisabledDescriptor.command == null
        && claudexDisabledDescriptor.proxyExecutable == null
        && claudexDisabledDescriptor.gateExecutable == null
        && claudexDisabledDescriptor.proxyLauncher == null
        && claudexDisabledDescriptor.proxyVersion == null
        && claudexDisabledDescriptor.generation == null
        && !(claudexDisabledDescriptor ? launchAgentPlist)
        && builtins.hasAttr ".local/lib/claudex/runtime.sh" claudexDisabledHm.home.file
        && builtins.all (
          path: !(builtins.hasAttr path claudexDisabledHm.home.file)
        ) claudexDisabledPublicFiles;
    }
    {
      name = "Test D21: synthetic disabled Claudex runtime derivation은 CLIProxyAPI를 참조하지 않아야 함";
      cond = !claudexDisabledRuntimeReferencesProxy;
    }
    {
      name = "Test D22: synthetic enabled Claudex의 portable Nix derivation 계약이 descriptor와 일치해야 함";
      cond =
        claudexEnabledDescriptor.enabled == true
        && toString claudexEnabledRuntimeSource == claudexEnabledDescriptor.runtimeLibrary
        && claudexEnabledRuntimeBuildPhaseMatchesDescriptor;
    }
    {
      name = "Test D22b: NixOS Claudex user service는 자동 기동 없이 실패 복구·graceful stop 계약을 가져야 함";
      cond =
        claudexNixosDescriptor.enabled == true
        && claudexNixosDescriptor.lifecycle.platform == "systemd-user"
        && claudexNixosService.Unit.X-SwitchMethod == "keep-old"
        && !(claudexNixosService ? Install)
        && claudexNixosService.Service.Restart == "on-failure"
        && claudexNixosService.Service.RestartSec == "2s"
        && claudexNixosService.Service.StandardOutput == "append:${claudexNixosDescriptor.logFile}"
        && claudexNixosService.Service.StandardError == "append:${claudexNixosDescriptor.logFile}"
        && claudexNixosService.Service.UMask == "0077"
        && claudexNixosService.Service.KillMode == "mixed"
        && claudexNixosService.Service.TimeoutStopSec == "45s"
        && builtins.length claudexNixosService.Service.ExecStart == 1
        && nixpkgsLib.hasInfix "claudex-proxy-launcher" (
          builtins.elemAt claudexNixosService.Service.ExecStart 0
        )
        && nixpkgsLib.hasSuffix " --managed" (builtins.elemAt claudexNixosService.Service.ExecStart 0);
    }
    {
      name = "Test D22c: Claudex generation은 동일 버전 executable의 store path 변경도 추적해야 함";
      cond =
        claudexEnabledDescriptor.proxyVersion == claudexAlternateProxyDescriptor.proxyVersion
        && claudexEnabledDescriptor.proxyExecutable != claudexAlternateProxyDescriptor.proxyExecutable
        && claudexEnabledDescriptor.generation != claudexAlternateProxyDescriptor.generation;
    }
    {
      name = "Test PJ1: private-job@ template·sync unit이 존재하고 공통 hardening(UMask 0077·NoNewPrivileges·PrivateTmp·ProtectSystem full·cgroup kill)을 갖는다";
      cond = pjHardeningOk pjTemplate && pjHardeningOk pjSync;
    }
    {
      name = "Test PJ2: RestrictNamespaces는 의도적으로 미적용 (하위 도구의 user namespace 요구 — 켜려면 이 테스트와 함께 재결정)";
      cond = pjNoNamespaceRestriction;
    }
    {
      name = "Test PJ3: bounded timeout — template 8h, sync 5min";
      cond = pjBoundedTimeout;
    }
    {
      name = "Test PJ4: sync timer가 timers.target에 걸리고 부팅 2분 + 15분 간격으로 돈다";
      cond =
        pjSyncTimer.wantedBy == [ "timers.target" ]
        && pjSyncTimer.timerConfig.OnBootSec == "2min"
        && pjSyncTimer.timerConfig.OnUnitActiveSec == "15min";
    }
    {
      name = "Test PJ5: linger 활성 — 로그인 세션 없이 user manager가 부팅부터 상주해야 무인 스케줄이 성립";
      cond = pjLingerOn;
    }
    {
      name = "Test D28a: C 정책의 persistent additional working roots는 exact Workspace-only여야 함";
      cond = claudeSettings.permissions.additionalDirectories == expectedClaudeAdditionalDirectories;
    }
    {
      name = "Test D28b: on-demand CLAUDE.md auto-load flag는 유지하되 deadline/TCC 성공 증거가 아님";
      cond = claudeSettings.env.CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD == "1";
    }
    {
      name = "Test D31: Claude RC의 플랫폼별 flock selector가 exact 구현을 반환해야 함";
      cond = claudeRcLinuxFlock == "util-linux" && claudeRcDarwinFlock == "discoteq-flock";
    }
    {
      name = "Test D32: NixOS Claude RC ensure는 unattended automatic drift policy를 유지해야 함";
      cond =
        nixosCfg.homeserver.claudeRemoteControl.enable
        && nixosCfg.systemd.services.claude-rc-ensure.environment.CLAUDE_RC_DRIFT_POLICY == "automatic";
    }
    {
      # linux(MiniPC)는 XDG_RUNTIME_DIR(systemd tmpfs, dirhelper 없음) — darwin 전용
      # 영속 배치 override(darwin 리스트의 D34)가 linux로 새지 않고 upstream 기본값을
      # 유지해야 한다. HM 사용자는 기존 let 바인딩 claudexNixosHm(constants.username
      # 고정)을 재사용한다.
      name = "Test D33: NixOS HM agenix secretsDir는 XDG_RUNTIME_DIR 기본값을 유지해야 함";
      cond =
        nixpkgsLib.hasInfix "XDG_RUNTIME_DIR" claudexNixosHm.age.secretsDir
        && nixpkgsLib.hasInfix "XDG_RUNTIME_DIR" claudexNixosHm.age.secretsMountPoint;
    }
  ]
  ++ darwinIntentTests;

  # 모든 테스트를 순차적으로 평가 (실패 시 해당 테스트 이름과 함께 throw)
  runTests = builtins.foldl' (acc: t: if acc then check t.name t.cond true else acc) true tests;

in
runTests
