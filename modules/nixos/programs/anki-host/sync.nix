# modules/nixos/programs/anki-host/sync.nix
# 인스턴스별 AnkiWeb 주기 동기화 (헬퍼 애드온 /sync 호출) + 상태 파일 + Pushover 알림
#
# 과거 anki-connect/sync.nix(61dadbe1^)와의 차이: AnkiConnect `sync` 액션(GUI 경로) 대신
# 헬퍼 애드온이 API를 직접 호출해 결과 코드를 돌려주고, 전후 스냅샷 차이로 "다른 기기의 학습이
# 내려왔는지"를 판정해 알림(b)을 보낸다. full sync 요구는 자동 결정하지 않고 알림(c)만 보낸다.
{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.homeserver.ankiHost;
  user = cfg.user;
  stateRoot = "/var/lib/anki-host";
  pushoverCredPath = config.age.secrets.pushover-anki.path;
  pushoverHelper = ../../../shared/scripts/lib/pushover.sh;
  syncInstances = lib.filterAttrs (_: inst: inst.enable && inst.sync.enable) cfg.instances;

  syncScript = pkgs.writeShellApplication {
    name = "anki-host-sync";
    runtimeInputs = with pkgs; [
      curl
      jq
      coreutils
      util-linux # flock
    ];
    text = builtins.readFile ./files/anki-host-sync.sh;
  };

  mkSyncService =
    name: inst:
    lib.nameValuePair "anki-host-sync-${name}" {
      description = "AnkiWeb periodic sync for headless Anki instance '${name}'";
      after = [
        "anki-host-${name}.service"
        "network-online.target"
      ];
      wants = [
        "anki-host-${name}.service"
        "network-online.target"
      ];
      partOf = [ "anki-host-${name}.service" ];

      # 시크릿이 아직 없으면(운영자 게이트 전) 조용히 건너뛴다 — EXIT_CREDENTIALS 실패 스팸 방지
      unitConfig.ConditionPathExists = pushoverCredPath;

      environment = {
        HELPER_PORT = toString inst.helperPort;
        STATE_DIR = "${stateRoot}/${name}";
        INSTANCE = name;
        PUSHOVER_HELPER = "${pushoverHelper}";
      };

      serviceConfig = {
        Type = "oneshot";
        User = user;
        Group = user;
        # root 소유 0400 시크릿을 서비스 유저에게 파일 하나로만 넘긴다 (karakeep-notify 패턴)
        LoadCredential = [ "pushover:${pushoverCredPath}" ];
        ExecStart = "${syncScript}/bin/anki-host-sync";
        TimeoutStartSec = "40min";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ "${stateRoot}/${name}" ];
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
      };
    };

  mkSyncTimer =
    name: inst:
    lib.nameValuePair "anki-host-sync-${name}" {
      description = "Periodic AnkiWeb sync trigger for '${name}'";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        Unit = "anki-host-sync-${name}.service";
        OnBootSec = "3min";
        OnUnitActiveSec = inst.sync.interval;
        Persistent = true;
        RandomizedDelaySec = "1min";
      };
    };
in
{
  config = lib.mkIf (cfg.enable && syncInstances != { }) {
    # Anki 전용 Pushover 앱 토큰 (PUSHOVER_TOKEN=/PUSHOVER_USER=). backup.nix와 동일 선언 — 모듈 시스템이 merge
    age.secrets.pushover-anki = {
      file = ../../../../secrets/pushover-anki.age;
      owner = "root";
      mode = "0400";
    };

    systemd.services = lib.mapAttrs' mkSyncService syncInstances;
    systemd.timers = lib.mapAttrs' mkSyncTimer syncInstances;
  };
}
