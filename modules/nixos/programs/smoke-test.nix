# modules/nixos/programs/smoke-test.nix
# 홈서버 런타임 스모크 테스트 (curl 헬스체크 + 백업 신선도)
# systemd timer로 주기적 실행, 실패 시 Pushover 알림
# 스크립트 본체: ./smoke-test/files/smoke-test.sh (검사 대상은 아래 environment로 주입)
#
# 패턴 참조: immich-backup.nix (service-lib.sh + Pushover)
{
  config,
  pkgs,
  lib,
  constants,
  ...
}:

let
  cfg = config.homeserver.smokeTest;
  inherit (constants.network) minipcTailscaleIP;
  inherit (constants.domain) base subdomains;
  inherit (constants.paths) mediaData ankiHostBackupsRelPath;

  immichMirrorEnabled =
    config.homeserver.immichOriginalsMirror.enable && config.homeserver.immich.enable;
  # 기록 경로는 작성하는 유닛을 정본으로 삼고, 타이머의 수동 중단 여부와 무관하게 검사한다.
  immichMirrorSuccessFile = lib.optionalString immichMirrorEnabled config.systemd.services.immich-originals-mirror.environment.LAST_SUCCESS_FILE;
  pushoverCredPath = config.age.secrets.pushover-system-monitor.path;
  serviceLib = import ../lib/service-lib.nix { inherit pkgs; };
  # headless Anki 백업 대상 인스턴스 — anki-host/backup.nix와 같은 필터(backup.enable). 활성일 때만 신선도 검사
  ankiBackupInstances = lib.optionals config.homeserver.ankiHost.enable (
    builtins.attrNames (
      lib.filterAttrs (_: inst: inst.backup.enable) config.homeserver.ankiHost.instances
    )
  );

  # 활성 서비스만 헬스체크 (비활성 서비스 false positive 방지)
  # 형식: "DOMAIN:EXPECTED_CODE:PATH"
  endpoints =
    lib.optionals config.homeserver.immich.enable [
      "${subdomains.immich}.${base}:200:/"
    ]
    ++ lib.optionals config.homeserver.uptimeKuma.enable [
      "${subdomains.uptimeKuma}.${base}:302:/"
    ]
    ++ lib.optionals config.homeserver.copyparty.enable [
      "${subdomains.copyparty}.${base}:200:/"
    ]
    ++ lib.optionals config.homeserver.karakeep.enable [
      "${subdomains.karakeep}.${base}:307:/"
    ];

  # 로컬 앱과 인터넷 입구를 각각 검사한다. 공개 Cloudflare 주소에는 tailnet --resolve를 적용하지 않는다.
  loopbackEndpoints = lib.optionals config.homeserver.ankiMcp.enable [
    "200|http://127.0.0.1:${toString config.homeserver.ankiMcp.port}/.well-known/oauth-authorization-server"
  ];
  publicEndpoints = lib.optionals config.homeserver.ankiMcp.enable [
    "200|https://${constants.ankiMcp.publicHostname}/.well-known/oauth-authorization-server"
    "401|https://${constants.ankiMcp.publicHostname}/mcp"
    "404|https://${constants.ankiMcp.publicHostname}/authorize"
  ];
  approvalFqdn = lib.optionalString config.homeserver.ankiMcp.enable constants.network.minipcTailnetFqdn;

  smokeScript = pkgs.writeShellApplication {
    name = "homeserver-smoke-test";
    runtimeInputs = with pkgs; [
      curl
      coreutils
      findutils
      jq
      systemd # failed 유닛 검출(systemctl --failed)
      tailscale # 승인 배선과 잔여 Funnel 검사
    ];
    text = builtins.readFile ./smoke-test/files/smoke-test.sh;
  };
in
{
  config = lib.mkIf cfg.enable {
    # Pushover 시크릿 (smartd, temp-monitor와 공유 — 모듈 시스템이 merge)
    age.secrets.pushover-system-monitor = {
      file = ../../../secrets/pushover-system-monitor.age;
      owner = "root";
      mode = "0400";
    };

    systemd.services.homeserver-smoke-test = {
      description = "Homeserver runtime smoke test (healthcheck + backup freshness)";
      after = [
        "network-online.target"
        "tailscaled.service"
      ];
      wants = [ "network-online.target" ];

      unitConfig = {
        ConditionPathExists = pushoverCredPath;
      };

      serviceConfig = {
        Type = "oneshot";
        TimeoutSec = "120";
        ExecStart = "${smokeScript}/bin/homeserver-smoke-test";
        ProtectSystem = "strict";
        ReadOnlyPaths = [
          "${mediaData}/backups"
        ]
        # 초기 실행 전 디렉터리가 없어도 스크립트가 기록 부재를 보고해야 한다.
        ++ lib.optionals immichMirrorEnabled [ "-${builtins.dirOf immichMirrorSuccessFile}" ];
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
      };

      environment = {
        PUSHOVER_CRED_FILE = pushoverCredPath;
        SERVICE_LIB = "${serviceLib}";
        TAILSCALE_IP = minipcTailscaleIP;
        BACKUP_MAX_AGE = toString cfg.backupMaxAgeHours;
        ENDPOINT_LIST = builtins.concatStringsSep " " endpoints;
        LOOPBACK_ENDPOINT_LIST = builtins.concatStringsSep " " loopbackEndpoints;
        PUBLIC_ENDPOINT_LIST = builtins.concatStringsSep " " publicEndpoints;
        APPROVAL_FQDN = approvalFqdn;
        LEGACY_FUNNEL_PORT = toString constants.network.ports.ankiMcpLegacyFunnel;
        APPROVAL_PORT = toString constants.network.ports.ankiMcpApprovalPublic;
        APPROVAL_TARGET = lib.optionalString config.homeserver.ankiMcp.enable "http://127.0.0.1:${toString config.homeserver.ankiMcp.approvalPort}";
        # 백업 신선도 검사 대상 — 빈 값이면 스크립트가 해당 검사를 건너뛴다
        IMMICH_BACKUP_DIR = lib.optionalString config.homeserver.immichBackup.enable "${mediaData}/backups/immich";
        # 매일 04:30 미러와 06:00 점검에는 기존 26시간 한계를 사용한다.
        # 개별 파일 복구 가능성이 아니라 마지막 미러 완료의 신선도를 뜻한다.
        IMMICH_ORIGINALS_LAST_SUCCESS_FILE = immichMirrorSuccessFile;
        KARAKEEP_BACKUP_DIR = lib.optionalString config.homeserver.karakeepBackup.enable "${mediaData}/backups/karakeep";
        ANKI_BACKUP_ROOT = "${mediaData}/${ankiHostBackupsRelPath}";
        ANKI_BACKUP_INSTANCES = builtins.concatStringsSep " " ankiBackupInstances;
      };
    };

    systemd.timers.homeserver-smoke-test = {
      description = "Daily homeserver smoke test";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        OnCalendar = cfg.timerInterval;
        RandomizedDelaySec = "5m";
        Persistent = true;
      };
    };
  };
}
