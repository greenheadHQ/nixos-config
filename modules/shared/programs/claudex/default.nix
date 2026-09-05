# Declarative Claudex runtime: run Claude Code through an on-demand loopback gate backed by
# pinned CLIProxyAPI OAuth credentials. Login-time activation and OAuth remain explicit.
args@{
  config,
  hostname,
  lib,
  pkgs,
  ...
}:

let
  targetHosts = [
    "greenhead-MacBookPro"
    "work-MacBookPro"
    "greenhead-minipc"
  ];
  enabled = builtins.elem hostname targetHosts;
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  homeDir = config.home.homeDirectory;
  # macOS keeps its Application Support convention; Linux follows the XDG state directory.
  # Both stay under $HOME, so the symlinked-ancestor guard in the runtime applies unchanged.
  stateDir =
    if isDarwin then
      "${homeDir}/Library/Application Support/claudex"
    else
      "${homeDir}/.local/state/claudex";
  authDir = "${stateDir}/auth";
  configFile = "${stateDir}/config.yaml";
  apiKeyFile = "${stateDir}/client-api-key";
  stateLock = "${stateDir}/state.lock";
  lifecycleLock = "${stateDir}/lifecycle.lock";
  controlSocket = "${stateDir}/control.sock";
  logFile = "${stateDir}/proxy.log";
  workDir = "${stateDir}/work";
  # CIR: the model contract is role-split for the --mixed session mode (issue #1127).
  #   defaultMainModel — the default-mode main model (and the descriptor `.model` alias
  #     below, kept for schema backward compatibility with existing consumers/eval locks).
  #   subagentModel — every mode's CLAUDE_CODE_SUBAGENT_MODEL.
  #   mixedMainModel — the --mixed main model (Claude via the proxy's claude credential).
  #     The id exists in the pinned proxy's embedded catalog; entitlement is confirmed at
  #     session start by the wrapper's catalog check, not here.
  # CIR: mixedMainModel moved from claude-fable-5 to claude-opus-4-8 — Fable 5 is a
  #     limited-run model on the subscription quota plan (available through 2026-07-20),
  #     so pinning it made mixed sessions expire with it. This constant is a build-time
  #     value with no runtime channel by design (the wrapper rejects --model and re-owns
  #     inherited env), so plan/model-policy changes require editing the sync points
  #     tracked in issue #1130 and redeploying. Mid-session /model switching to another
  #     catalog model remains available (user-measured 2026-07-17) — the pin fixes the
  #     session's starting model, not a session-long invariant.
  # CIR: mixedMainModel then moved claude-opus-4-8 → claude-opus-5 (2026-09, issue #1130).
  #     The Fable 5 expiry rationale above is unchanged; what went stale is the implicit
  #     assumption that opus-4-8 is the current generation. claude-opus-5 is present in the
  #     pinned proxy's embedded catalog, but a catalog hit is not a subscription entitlement
  #     (the wrapper says so in its own error text), so the promotion is only confirmed by a
  #     post-deploy self-report run: claudex --mixed -p "Reply with exactly your model name".
  #     If that fails, roll back to claude-opus-4-8 and record the observation on #1130.
  # CIR: the Codex-side pins (defaultMainModel/subagentModel) are bounded by the pinned
  #     CLIProxyAPI (cli-proxy-api-pin.json) embedded catalog, not by the newest Codex model.
  #     7.2.111 carries no gpt-6 family, so following the Codex frontier needs a proxy pin
  #     bump first — the wrapper's catalog check is fail-closed and would exit 1 on a model
  #     the proxy does not serve. Reverify (static, works with the proxy down):
  #       strings -a <pinned proxy>/bin/cli-proxy-api | grep -oE 'gpt-[0-9][0-9a-z.-]*' | sort -u
  #     The static scan is strong evidence, not proof; the decisive check is the running
  #     proxy's catalog: curl -s http://127.0.0.1:8317/v1/models | jq -r '.data[].id'
  # mixedMainModel/subagentModel are deliberately NOT exposed in the descriptor: no
  # consumer exists today, and schema surface grows only with a consumer + schema bump.
  runtimeContract = {
    bindHost = "127.0.0.1";
    port = 8317;
    defaultMainModel = "gpt-5.6-sol";
    subagentModel = "gpt-5.6-sol";
    mixedMainModel = "claude-opus-5";
    label = "org.nix-community.home.claudex-proxy";
  };
  inherit (runtimeContract)
    bindHost
    port
    defaultMainModel
    subagentModel
    mixedMainModel
    label
    ;
  pprofPort = port - 1;
  backendPort = port + 1;
  gracefulDrainSeconds = 30;
  childStopSeconds = 10;
  serviceName = "claudex-proxy.service";
  # Manager behavior is part of the runtime generation contract. Keep these values
  # centralized so a launchd/systemd lifecycle change cannot leave an already-loaded
  # manager definition looking current to the gate.
  managerLifecycle = {
    autoStart = "first-session";
    restart = "on-failure";
    restartDelay = "2s";
    stopTimeoutSeconds = 45;
    privateUmask = "0077";
    launchd = {
      runAtLoad = false;
      keepAliveSuccessfulExit = false;
      abandonProcessGroup = false;
    };
    systemd = {
      logMode = "append";
      killMode = "mixed";
    };
  };

  cliProxyApi = args.claudexCliProxyApi or (import ./package.nix { inherit pkgs; });
  gatePackage = pkgs.buildGoModule {
    pname = "claudex-gate";
    version = "1.0.0";
    src = ./gate;
    vendorHash = null;
    subPackages = [ "." ];
    ldflags = [
      "-s"
      "-w"
    ];
    meta = {
      description = "Claudex loopback traffic gate and child supervisor";
      license = lib.licenses.mit;
      mainProgram = "claudex-gate";
      platforms = [
        "aarch64-darwin"
        "x86_64-linux"
      ];
    };
  };
  proxyExecutablePath = "${cliProxyApi}/bin/cli-proxy-api";
  gateExecutablePath = "${gatePackage}/bin/claudex-gate";
  runtimeGeneration = builtins.hashString "sha256" (
    builtins.toJSON {
      sources = map builtins.readFile [
        ./files/claudex-runtime.sh
        ./files/claudex.sh
        ./files/claudex-login.sh
        ./files/claudex-status.sh
        ./files/claudex-proxy.sh
        ./files/claudex-proxy-launcher.sh
        ./files/config-template.json
        ./cli-proxy-api-pin.json
        ./gate/go.mod
        ./gate/main.go
      ];
      contract = runtimeContract // {
        inherit
          backendPort
          gracefulDrainSeconds
          childStopSeconds
          serviceName
          maxContextTokens
          managerLifecycle
          ;
        platform = if isDarwin then "darwin" else "linux";
        proxyVersion = cliProxyApi.version;
        gateVersion = gatePackage.version;
        proxyExecutable = proxyExecutablePath;
        gateExecutable = gateExecutablePath;
      };
    }
  );
  # config-template.json은 JSON이라 주석을 담을 수 없고, runtime.sh가 렌더된 config의 key 목록을
  # 화이트리스트로 정확히 검증하므로 설명용 `_comment` key도 넣을 수 없다. 따라서 보안 관련 값의
  # 근거는 여기에 남긴다.
  #   commercial-mode = true: upstream 기본값은 false이며, 이 플래그는 상용/라이선스 스위치가 아니라
  #   "high-overhead request logging과 HTTP middleware를 비활성화해 per-request 메모리를 줄이는" 옵션이다.
  #   credential·request 본문이 로그에 남지 않도록 request logging을 억제할 목적으로 의도적으로 true로
  #   두었으며, logging-to-file·usage-statistics-enabled를 끄는 config-template의 보안 기본값과 같은 맥락이다.
  # CIR: 아래 resilience knob 4종은 upstream 기본값이 전부 "비활성"이라 단일 credential 세션이
  #   Cloudflare 520 → 429 credential cooldown 연쇄로 불안정했던 것을 완화한다 (deep-research + v7.2.73
  #   소스 대조). max-retry-interval=30: code default 0이면 cooldown 흡수가 완전히 꺼져 429가 그대로
  #   클라이언트로 샌다 — 30초 이하 cooldown을 proxy가 내부 대기·재시도로 흡수한다. passthrough-headers=true:
  #   30초 초과 긴 cooldown의 Retry-After(proxy 자체 합성분 포함)를 Claude Code에 전달해 blind backoff를
  #   정확한 대기로 바꾼다. transient-error-cooldown-seconds=-1: 5xx(408/500/502/503/504) 후 legacy 60초
  #   벤치를 끈다(단일 credential이라 이 벤치가 전면 차단이 된다). streaming.bootstrap-retries=1: first-byte
  #   이전 520(>=500)을 안전 재시도하고, keepalive-seconds=15: SSE heartbeat로 client idle timeout을 막는다.
  #   mid-stream drop(응답 도중 서버측 종료)은 어떤 knob으로도 완화 불가이며 upstream 버그 수정이 필요하다.
  configTemplateBase = builtins.fromJSON (builtins.readFile ./files/config-template.json);
  configTemplate = pkgs.writeText "claudex-config-template.json" (
    builtins.toJSON (
      configTemplateBase
      // {
        host = bindHost;
        inherit port;
        pprof = configTemplateBase.pprof // {
          addr = "${bindHost}:${toString pprofPort}";
        };
      }
    )
  );
  wrapperSettings = pkgs.writeText "claudex-wrapper-settings.json" (
    builtins.toJSON {
      env.CLAUDE_CODE_EXTRA_BODY = "{}";
    }
  );
  # CIR: the fast variant carries the Codex fast tier in the wrapper-owned request body.
  # The injected value is the final on-wire id "priority" (upstream catalog id="priority",
  # name="Fast", 1.5x speed) rather than the "fast" alias: the pinned proxy's claude->codex
  # translator maps fast->priority today, but its openai-responses translator already drops
  # anything that is not exactly "priority", so pinning the canonical id keeps the contract
  # independent of upstream alias leniency. Both variants stay pinned Nix store files;
  # `claudex --fast` merely selects which one is passed to --settings.
  wrapperSettingsFast = pkgs.writeText "claudex-wrapper-settings-fast.json" (
    builtins.toJSON {
      env.CLAUDE_CODE_EXTRA_BODY = builtins.toJSON { service_tier = "priority"; };
    }
  );
  # CIR: the wrapper-launched CLI does not recognize the pinned model and assumes a 200k context
  # window, and the pinned proxy hard-codes usage 0/0 into SSE message_start (upstream
  # declined to change this), which pushes the CLI's context tracking onto a character-based
  # local estimate. Both errors combine to saturate the statusline at "100% context used"
  # far too early. CLAUDE_CODE_MAX_CONTEXT_TOKENS is the CLI's official override that only
  # applies to non-claude model names. The value tracked here is the official Codex catalog's
  # raw context_window (272000 for gpt-5.6-sol). The catalog's max_context_window is a
  # different, larger field (872000 as of 2026-09 for the gpt-5.6/gpt-6 tier) and is
  # deliberately not followed: what it grants this loopback path has never been measured, and
  # over-declaring the window costs more than under-declaring it (the CLI would stop reserving
  # compaction headroom in time), so the conservative field wins until #1113 measures the
  # ceiling that actually applies here. Codex separately applies its 95% effective-window
  # policy and therefore reports 258400 as usable input; that policy value is not the raw
  # Codex catalog window either. Claude Code applies its own output and compaction headroom
  # below the declared window, so feeding the Codex effective value here would reserve
  # headroom twice. Keep both wrapper channels anchored to the raw catalog value and re-tune
  # them together when the official model metadata changes. The numerator stays a local
  # estimate, so the displayed percentage remains an approximation. Reverify with the
  # model-agnostic form below — a `select(.slug == "<pinned model>")` filter fails silently
  # (empty output, exit 0) once the pin moves or the slug leaves the catalog, which reads as
  # "nothing to see" instead of "the command is stale":
  #   codex debug models | jq '.models[] | select(.visibility == "list") |
  #     {slug,context_window,max_context_window,effective_context_window_percent}'
  maxContextTokens = 272000;

  runtimeLibrary = pkgs.replaceVars ./files/claudex-runtime.sh {
    allowTestOverrides = "false";
    bashBin = "${pkgs.bash}/bin/bash";
    inherit
      homeDir
      stateDir
      authDir
      configFile
      apiKeyFile
      stateLock
      lifecycleLock
      controlSocket
      logFile
      workDir
      ;
    jqBin = "${pkgs.jq}/bin/jq";
    curlBin = "${pkgs.curl}/bin/curl";
    opensslBin = "${pkgs.openssl}/bin/openssl";
    cmpBin = "${pkgs.diffutils}/bin/cmp";
    cpBin = "${pkgs.coreutils}/bin/cp";
    statBin = "${pkgs.coreutils}/bin/stat";
    chmodBin = "${pkgs.coreutils}/bin/chmod";
    mkdirBin = "${pkgs.coreutils}/bin/mkdir";
    mktempBin = "${pkgs.coreutils}/bin/mktemp";
    mvBin = "${pkgs.coreutils}/bin/mv";
    rmBin = "${pkgs.coreutils}/bin/rm";
    sleepBin = "${pkgs.coreutils}/bin/sleep";
    envBin = "${pkgs.coreutils}/bin/env";
    idBin = "${pkgs.coreutils}/bin/id";
    # The state lock uses flock's fd mode on both platforms. nixpkgs ships a darwin flock
    # (discoteq), already relied on by claude-rc-maint, so the lock contract, its argv, and its
    # tests stay single-path across macOS and NixOS. macOS /usr/bin/lockf is deliberately no
    # longer used: its flags are not interchangeable with flock's (lockf -s means silent,
    # flock -s means a *shared* lock, and the timeout flag is -t vs -w), so keeping both would
    # fork the one code path that guards all state mutation.
    flockBin = if isDarwin then "${pkgs.flock}/bin/flock" else "${pkgs.util-linux}/bin/flock";
    launchctlBin = if isDarwin then "/bin/launchctl" else "";
    systemctlBin = if isDarwin then "" else "${pkgs.systemd}/bin/systemctl";
    gateBin = if enabled then gateExecutablePath else "";
    generation = runtimeGeneration;
    platform = if isDarwin then "darwin" else "linux";
    inherit
      bindHost
      defaultMainModel
      subagentModel
      mixedMainModel
      label
      ;
    port = toString port;
    pprofPort = toString pprofPort;
    inherit configTemplate;
  };

  mkRuntimeScript =
    source: replacements:
    pkgs.replaceVarsWith {
      src = source;
      isExecutable = true;
      replacements = {
        bashBin = "${pkgs.bash}/bin/bash";
        inherit runtimeLibrary;
      }
      // replacements;
    };

  statusScript = mkRuntimeScript ./files/claudex-status.sh {
    inherit serviceName;
    proxyBin = proxyExecutablePath;
  };
  loginScript = mkRuntimeScript ./files/claudex-login.sh {
    proxyBin = proxyExecutablePath;
    inherit configTemplate;
  };
  proxyLauncherScript = mkRuntimeScript ./files/claudex-proxy-launcher.sh {
    proxyBin = proxyExecutablePath;
    gateBin = gateExecutablePath;
    generation = runtimeGeneration;
    backendPort = toString backendPort;
    gracefulDrainSeconds = toString gracefulDrainSeconds;
    childStopSeconds = toString childStopSeconds;
    inherit configTemplate;
  };
  launchdPlist = pkgs.writeText "claudex-proxy.plist" ''
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>${label}</string>
      <key>ProgramArguments</key>
      <array>
        <string>${proxyLauncherScript}</string>
        <string>--managed</string>
      </array>
      <key>RunAtLoad</key>
      <${if managerLifecycle.launchd.runAtLoad then "true" else "false"}/>
      <key>KeepAlive</key>
      <dict>
        <key>SuccessfulExit</key>
        <${if managerLifecycle.launchd.keepAliveSuccessfulExit then "true" else "false"}/>
      </dict>
      <key>AbandonProcessGroup</key>
      <${if managerLifecycle.launchd.abandonProcessGroup then "true" else "false"}/>
      <key>ExitTimeOut</key>
      <integer>${toString managerLifecycle.stopTimeoutSeconds}</integer>
      <key>StandardOutPath</key>
      <string>${logFile}</string>
      <key>StandardErrorPath</key>
      <string>${logFile}</string>
    </dict>
    </plist>
  '';
  proxyScript = mkRuntimeScript ./files/claudex-proxy.sh {
    proxyLauncher = proxyLauncherScript;
    proxyBin = proxyExecutablePath;
    inherit
      launchdPlist
      serviceName
      ;
    statusHandler = statusScript;
    tailBin = "${pkgs.coreutils}/bin/tail";
    gracefulDrainSeconds = toString gracefulDrainSeconds;
  };
  claudexScript = mkRuntimeScript ./files/claudex.sh {
    inherit configTemplate wrapperSettings wrapperSettingsFast;
    maxContextTokens = toString maxContextTokens;
    loginHandler = loginScript;
    statusHandler = statusScript;
    proxyHandler = proxyScript;
  };

  runtimePackage = pkgs.runCommand "claudex-runtime-stage2" { } ''
    install -Dm755 ${claudexScript} "$out/bin/claudex"
    install -Dm755 ${loginScript} "$out/libexec/claudex/claudex-login"
    install -Dm755 ${statusScript} "$out/libexec/claudex/claudex-status"
    install -Dm755 ${proxyScript} "$out/libexec/claudex/claudex-proxy"
    install -Dm755 ${proxyLauncherScript} "$out/libexec/claudex/claudex-proxy-launcher"
  '';

  descriptor = {
    schema = 3;
    inherit
      enabled
      targetHosts
      label
      stateDir
      authDir
      configFile
      controlSocket
      logFile
      bindHost
      port
      ;
    # Descriptor `.model` stays the defaultMainModel alias for existing consumers;
    # role-split fields are wrapper-internal until a descriptor consumer exists.
    model = defaultMainModel;
    hostName = hostname;
    runtimeLibrary = toString runtimeLibrary;
    source = if enabled then toString runtimePackage else null;
    command =
      if enabled then
        [
          "${runtimePackage}/libexec/claudex/claudex-proxy-launcher"
          "--managed"
        ]
      else
        null;
    proxyExecutable = if enabled then proxyExecutablePath else null;
    gateExecutable = if enabled then gateExecutablePath else null;
    proxyLauncher =
      if enabled then "${runtimePackage}/libexec/claudex/claudex-proxy-launcher" else null;
    proxyVersion = if enabled then cliProxyApi.version else null;
    generation = if enabled then runtimeGeneration else null;
    lifecycle = {
      inherit (managerLifecycle) autoStart restart;
      platform = if isDarwin then "launchd" else "systemd-user";
      gracefulDrainSeconds = gracefulDrainSeconds;
    };
    readiness = {
      method = "GET";
      url = "http://${bindHost}:${toString port}/v1/models";
      catalogIsEntitlement = false;
    };
  };
  # Descriptor paths are operational metadata, not dependency declarations. Their referenced
  # store objects are retained by home.file sources; discarding context keeps the JSON parseable
  # in eval tests and avoids pulling the proxy closure into disabled hosts through metadata.
  descriptorJson = builtins.unsafeDiscardStringContext (builtins.toJSON descriptor);
in
{
  home.file = {
    ".config/claudex/runtime.json".text = descriptorJson;
    ".local/lib/claudex/runtime.sh".source = runtimeLibrary;
  }
  // lib.optionalAttrs enabled {
    ".local/bin/claudex" = {
      source = "${runtimePackage}/bin/claudex";
      executable = true;
    };
    ".local/libexec/claudex/claudex-proxy-launcher" = {
      source = "${runtimePackage}/libexec/claudex/claudex-proxy-launcher";
      executable = true;
    };
  };

  systemd.user.services.claudex-proxy = lib.mkIf (!isDarwin && enabled) {
    Unit = {
      Description = "Claudex on-demand loopback proxy";
      X-SwitchMethod = "keep-old";
    };
    Service = {
      Type = "simple";
      ExecStart = "${proxyLauncherScript} --managed";
      Restart = managerLifecycle.restart;
      RestartSec = managerLifecycle.restartDelay;
      StandardOutput = "${managerLifecycle.systemd.logMode}:${logFile}";
      StandardError = "${managerLifecycle.systemd.logMode}:${logFile}";
      UMask = managerLifecycle.privateUmask;
      KillMode = managerLifecycle.systemd.killMode;
      TimeoutStopSec = "${toString managerLifecycle.stopTimeoutSeconds}s";
    };
  };
}
