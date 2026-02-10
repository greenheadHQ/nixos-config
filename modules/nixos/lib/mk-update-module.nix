# modules/nixos/lib/mk-update-module.nix
# 서비스 업데이트 모듈 생성 헬퍼
# copyparty-update, uptime-kuma-update 등 동일 패턴의 업데이트 모듈을 간결하게 생성
#
# 사용법:
#   import ../../lib/mk-update-module.nix {
#     serviceName = "copyparty";
#     ...
#   }
{
  # 필수 파라미터
  serviceName, # 예: "copyparty" (하이픈 포함 가능)
  serviceDisplayName, # 예: "Copyparty"
  githubRepo, # 예: "9001/copyparty"

  # 옵션 접근자 (config에서 cfg를 추출하는 함수)
  updateCfgPath, # 예: cfg -> cfg.homeserver.copypartyUpdate
  parentCfgPath, # 예: cfg -> cfg.homeserver.copyparty

  # 시크릿
  pushoverSecretName, # 예: "pushover-copyparty"
  pushoverSecretFile, # 예: ../../../../secrets/pushover-copyparty.age

  # 스크립트
  versionCheckScript ? null, # null이면 generic-version-check.sh 사용
  updateScriptFile, # ./files/update-script.sh 경로

  # version-check runtimeInputs (기본: curl, jq, coreutils, podman)
  versionCheckInputs ? (
    pkgs: with pkgs; [
      curl
      jq
      coreutils
      podman
    ]
  ),
  # update-script runtimeInputs
  updateScriptInputs ? (
    pkgs: with pkgs; [
      curl
      jq
      coreutils
      podman
      systemd
    ]
  ),

  # 업데이트 스크립트 래퍼에 전달할 추가 환경변수
  extraUpdateEnv ? (_config: _constants: { }),

  # version-check 서비스에 전달할 추가 환경변수
  extraCheckEnv ? (_config: _constants: { }),

  # 추가 tmpfiles.rules (백업 디렉토리 등)
  extraTmpfilesRules ? [ ],

  # major version mismatch 감지 여부 (version-check.sh)
  detectMajorMismatch ? false,
}:
{
  config,
  pkgs,
  lib,
  constants,
  ...
}:

let
  updateCfg = updateCfgPath config;
  parentCfg = parentCfgPath config;
  port = toString parentCfg.port;
  pushoverCredPath = config.age.secrets.${pushoverSecretName}.path;
  serviceLib = import ./service-lib.nix { inherit pkgs; };

  containerImage = config.virtualisation.oci-containers.containers.${serviceName}.image;
  stateDir = "/var/lib/${serviceName}-update";

  actualVersionCheckScript = pkgs.writeShellApplication {
    name = "${serviceName}-version-check";
    runtimeInputs = versionCheckInputs pkgs;
    text =
      if versionCheckScript != null then
        builtins.readFile versionCheckScript
      else
        builtins.readFile ./generic-version-check.sh;
  };

  updateScriptInner = pkgs.writeShellApplication {
    name = "${serviceName}-update-inner";
    runtimeInputs = updateScriptInputs pkgs;
    text = builtins.readFile updateScriptFile;
  };

  baseUpdateEnv = {
    PUSHOVER_CRED_FILE = pushoverCredPath;
    SERVICE_LIB = "${serviceLib}";
    STATE_DIR = stateDir;
    CONTAINER_NAME = serviceName;
    CONTAINER_IMAGE = containerImage;
    SERVICE_UNIT = "podman-${serviceName}.service";
    HEALTH_URL = "http://127.0.0.1:${port}";
    GITHUB_REPO = githubRepo;
    SERVICE_DISPLAY_NAME = serviceDisplayName;
  };

  mergedUpdateEnv = baseUpdateEnv // (extraUpdateEnv config constants);

  updateScript = pkgs.writeShellScriptBin "${serviceName}-update" (
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (k: v: "export ${k}=\"${v}\"") mergedUpdateEnv
      ++ [ "exec ${updateScriptInner}/bin/${serviceName}-update-inner \"$@\"" ]
    )
  );

  baseCheckEnv = {
    PUSHOVER_CRED_FILE = pushoverCredPath;
    SERVICE_LIB = "${serviceLib}";
    STATE_DIR = stateDir;
    CONTAINER_NAME = serviceName;
    CONTAINER_IMAGE = containerImage;
    GITHUB_REPO = githubRepo;
    SERVICE_DISPLAY_NAME = serviceDisplayName;
  }
  // lib.optionalAttrs detectMajorMismatch { DETECT_MAJOR_MISMATCH = "true"; };

  mergedCheckEnv = baseCheckEnv // (extraCheckEnv config constants);
in
{
  config = lib.mkIf (updateCfg.enable && parentCfg.enable) {
    # ═══════════════════════════════════════════════════════════════
    # agenix 시크릿
    # ═══════════════════════════════════════════════════════════════
    age.secrets.${pushoverSecretName} = {
      file = pushoverSecretFile;
      owner = "root";
      mode = "0400";
    };

    # ═══════════════════════════════════════════════════════════════
    # 상태 디렉토리
    # ═══════════════════════════════════════════════════════════════
    systemd.tmpfiles.rules = [
      "d ${stateDir} 0700 root root -"
    ]
    ++ extraTmpfilesRules;

    # ═══════════════════════════════════════════════════════════════
    # 버전 체크 서비스 (oneshot) — systemd hardening 적용
    # ═══════════════════════════════════════════════════════════════
    systemd.services."${serviceName}-version-check" = {
      description = "${serviceDisplayName} version check and notification";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      unitConfig = {
        ConditionPathExists = [ pushoverCredPath ];
      };

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${actualVersionCheckScript}/bin/${serviceName}-version-check";

        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        ReadWritePaths = [ stateDir ];
      };

      environment = mergedCheckEnv;
    };

    # ═══════════════════════════════════════════════════════════════
    # 타이머 (매일 실행)
    # ═══════════════════════════════════════════════════════════════
    systemd.timers."${serviceName}-version-check" = {
      description = "Daily ${serviceDisplayName} version check";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        OnCalendar = updateCfg.checkTime;
        Persistent = true;
        RandomizedDelaySec = "5m";
      };
    };

    # ═══════════════════════════════════════════════════════════════
    # 수동 업데이트 스크립트
    # ═══════════════════════════════════════════════════════════════
    environment.systemPackages = [ updateScript ];
  };
}
