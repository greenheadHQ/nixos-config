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
