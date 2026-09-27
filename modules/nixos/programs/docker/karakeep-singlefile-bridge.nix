# modules/nixos/programs/docker/karakeep-singlefile-bridge.nix
# SingleFile 업로드 크기 기준 분기 브리지:
# - 임계값 이하: Karakeep singlefile API로 전달
# - 임계값 초과: 링크 북마크 생성 + fullPageArchive asset 직접 연결
{
  config,
  pkgs,
  lib,
  constants,
  ...
}:

let
  cfg = config.homeserver.karakeepSinglefileBridge;
  karakeepCfg = config.homeserver.karakeep;

  pushoverCredPath = config.age.secrets.pushover-karakeep.path;

  bridgeScript = pkgs.writeText "karakeep-singlefile-bridge.py" (
    builtins.readFile ./karakeep-singlefile-bridge/files/singlefile-bridge.py
  );
in
{
  config = lib.mkIf (cfg.enable && karakeepCfg.enable) {
    # Pushover credentials 재사용 (모듈 시스템 merge)
    age.secrets.pushover-karakeep = {
      file = ../../../../secrets/pushover-karakeep.age;
      owner = "root";
      mode = "0400";
    };

    systemd.services.karakeep-singlefile-bridge = {
      description = "Karakeep SingleFile size-guard bridge";
      after = [
        "network.target"
        "podman-karakeep.service"
      ];
      wants = [ "podman-karakeep.service" ];
      partOf = [ "podman-karakeep.service" ];
      wantedBy = [ "multi-user.target" ];

      unitConfig = {
        ConditionPathExists = pushoverCredPath;
      };

      path = with pkgs; [ curl ];

      serviceConfig = {
        Type = "simple";
        # bridge script uses PEP 604 typing syntax (`str | None`), requires Python 3.10+.
        ExecStart = "${pkgs.python3}/bin/python3 ${bridgeScript}";
        EnvironmentFile = pushoverCredPath;
        Restart = "on-failure";
        RestartSec = "5s";
        # 90 = systemd 기본값과 동일(동작 변화 없음). 이 브리지 코드는 SIGTERM을 받으면
        # 실행 중인 요청을 최대 SHUTDOWN_DRAIN_TIMEOUT_SEC(기본 30초, singlefile-bridge.py)까지
        # 기다린 뒤 스스로 종료한다. 그 상한보다 이 값이 짧아지면 systemd가 브리지의 정상
        # drain을 못 기다리고 SIGKILL로 끊어버리므로, 항상 drain 상한보다 여유 있게 크게 둔다.
        TimeoutStopSec = 90;
        # 기본값 control-group에서는 stop 시 SIGTERM이 cgroup의 모든 프로세스로 간다 —
        # drain 중인 요청이 run_curl/send_pushover로 띄운 curl 자식도 함께 죽어, drain이
        # 업로드 완료를 기다린다는 의도가 무너진다. mixed는 SIGTERM을 메인에만 보내고,
        # 남은 프로세스는 메인 종료 후 또는 위 TimeoutStopSec을 넘긴 뒤에만 SIGKILL로 정리한다.
        KillMode = "mixed";
        PrivateTmp = true;
        NoNewPrivileges = true;
      };

      environment = {
        SINGLEFILE_BRIDGE_LISTEN = "127.0.0.1";
        SINGLEFILE_BRIDGE_PORT = toString cfg.port;
        MAX_ASSET_SIZE_MB = toString cfg.maxAssetSizeMb;
        SINGLEFILE_BRIDGE_MAX_REQUEST_MB = toString (lib.max (cfg.maxAssetSizeMb * 3) 200);
        KARAKEEP_BASE_URL = "http://127.0.0.1:${toString karakeepCfg.port}";
        KARAKEEP_DB_PATH = "${constants.paths.mediaData}/karakeep/db.db";
        KARAKEEP_QUEUE_DB_PATH = "${constants.paths.mediaData}/karakeep/queue.db";
        SINGLEFILE_BRIDGE_SQLITE_TIMEOUT_MS = "5000";
      };
    };
  };
}
