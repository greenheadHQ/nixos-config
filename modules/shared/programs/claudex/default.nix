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
    inherit configTemplate wrapperSettings;
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
