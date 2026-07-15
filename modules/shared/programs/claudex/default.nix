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
  ];
  enabled = builtins.elem hostname targetHosts;
  homeDir = config.home.homeDirectory;
  stateDir = "${homeDir}/Library/Application Support/claudex";
  authDir = "${stateDir}/auth";
  configFile = "${stateDir}/config.yaml";
  apiKeyFile = "${stateDir}/client-api-key";
  stateLock = "${stateDir}/state.lock";
  workDir = "${stateDir}/work";
  runtimeContract = {
    bindHost = "127.0.0.1";
    port = 8317;
    model = "gpt-5.6-sol";
    label = "org.nix-community.home.claudex-proxy";
  };
  inherit (runtimeContract)
    bindHost
    port
    model
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
    lockfBin = "/usr/bin/lockf";
    launchctlBin = "/bin/launchctl";
    inherit
      bindHost
      model
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
      model
      ;
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
