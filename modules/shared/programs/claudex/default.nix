# Declarative PoC: run Claude Code against a loopback CLIProxyAPI backed by Codex OAuth.
#
# Stage 1's Nix build/eval/activation path intentionally contains no launchd agent,
# activation hook, nrs integration, OAuth execution, or proxy smoke run. Manual Gate B is
# documented separately in the handoff.
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
  # mixedMainModel/subagentModel are deliberately NOT exposed in the descriptor: no
  # consumer exists today, and schema surface grows only with a consumer + schema bump.
  runtimeContract = {
    bindHost = "127.0.0.1";
    port = 8317;
    defaultMainModel = "gpt-5.6-sol";
    subagentModel = "gpt-5.6-sol";
    mixedMainModel = "claude-opus-4-8";
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

  cliProxyApi = args.claudexCliProxyApi or (import ./package.nix { inherit pkgs; });
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
  # CIR: the pinned CLI does not recognize the pinned model and assumes a 200k context
  # window, and the pinned proxy hard-codes usage 0/0 into SSE message_start (upstream
  # declined to change this), which pushes the CLI's context tracking onto a character-based
  # local estimate. Both errors combine to saturate the statusline at "100% context used"
  # far too early. CLAUDE_CODE_MAX_CONTEXT_TOKENS is the CLI's official override that only
  # applies to non-claude model names. 258000 is the limit the Codex app currently reports
  # for the pinned model (user-measured 2026-07-15) and is itself a TEMPORARY upstream
  # value: the model shipped with 372k, OpenAI reverted the product limit while fixing an
  # over-billing bug and announced it will be raised again — re-tune this value when that
  # lands (tracked in issue #1113; see also the handoff limits section). The numerator stays
  # a local estimate, so the displayed percentage remains an approximation.
  maxContextTokens = 258000;

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
      workDir
      ;
    jqBin = "${pkgs.jq}/bin/jq";
    curlBin = "${pkgs.curl}/bin/curl";
    opensslBin = "${pkgs.openssl}/bin/openssl";
    cmpBin = "${pkgs.diffutils}/bin/cmp";
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
    # Stage 1 ships no service unit on either platform, so this probe only ever reports the
    # absence of a launchd agent. Linux gets an empty value and the status command reports
    # service=n/a rather than implying knowledge of a systemd unit that does not exist.
    launchctlBin = if isDarwin then "/bin/launchctl" else "";
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
    pkgs.replaceVars source (
      {
        bashBin = "${pkgs.bash}/bin/bash";
        inherit runtimeLibrary;
      }
      // replacements
    );

  claudexScript = mkRuntimeScript ./files/claudex.sh {
    inherit configTemplate wrapperSettings wrapperSettingsFast;
    maxContextTokens = toString maxContextTokens;
  };
  statusScript = mkRuntimeScript ./files/claudex-status.sh { };
  loginScript = mkRuntimeScript ./files/claudex-login.sh {
    proxyBin = "${cliProxyApi}/bin/cli-proxy-api";
    inherit configTemplate;
  };
  proxyLauncherScript = mkRuntimeScript ./files/claudex-proxy-launcher.sh {
    proxyBin = "${cliProxyApi}/bin/cli-proxy-api";
    inherit configTemplate;
  };

  runtimePackage = pkgs.runCommand "claudex-runtime-stage1" { } ''
    install -Dm755 ${claudexScript} "$out/bin/claudex"
    install -Dm755 ${loginScript} "$out/bin/claudex-login"
    install -Dm755 ${statusScript} "$out/bin/claudex-status"
    install -Dm755 ${proxyLauncherScript} "$out/libexec/claudex/claudex-proxy-launcher"
  '';

  descriptor = {
    schema = 2;
    inherit
      enabled
      targetHosts
      label
      stateDir
      authDir
      configFile
      bindHost
      port
      ;
    # Descriptor `.model` stays the defaultMainModel alias (schema 2 compatibility);
    # role-split fields are wrapper-internal until a descriptor consumer exists.
    model = defaultMainModel;
    hostName = hostname;
    runtimeLibrary = toString runtimeLibrary;
    source = if enabled then toString runtimePackage else null;
    command = if enabled then [ "${runtimePackage}/libexec/claudex/claudex-proxy-launcher" ] else null;
    proxyExecutable = if enabled then "${cliProxyApi}/bin/cli-proxy-api" else null;
    proxyLauncher =
      if enabled then "${runtimePackage}/libexec/claudex/claudex-proxy-launcher" else null;
    proxyVersion = if enabled then cliProxyApi.version else null;
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
    ".local/bin/claudex-login" = {
      source = "${runtimePackage}/bin/claudex-login";
      executable = true;
    };
    ".local/bin/claudex-status" = {
      source = "${runtimePackage}/bin/claudex-status";
      executable = true;
    };
    ".local/libexec/claudex/claudex-proxy-launcher" = {
      source = "${runtimePackage}/libexec/claudex/claudex-proxy-launcher";
      executable = true;
    };
  };
}
