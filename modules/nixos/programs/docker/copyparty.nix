# modules/nixos/programs/docker/copyparty.nix
# 셀프호스팅 파일 서버 (Google Drive 대체)
{
  config,
  pkgs,
  lib,
  constants,
  ...
}:

let
  cfg = config.homeserver.copyparty;
  inherit (constants.network) minipcTailscaleIP;
  inherit (constants.paths) dockerData mediaData;
  inherit (constants.containers) copyparty;

  configPath = "${dockerData}/copyparty/config/copyparty.conf";
  passwordPath = config.age.secrets.copyparty-password.path;

  # 비밀번호를 주입한 설정 파일 생성
  # <<'CONF' (quoted heredoc)로 셸 해석 방지 + printf로 비밀번호만 안전 삽입
  configScript = pkgs.writeShellScript "copyparty-config-gen" ''
    PASSWORD=$(cat ${passwordPath})
    cat > ${configPath} <<'CONF'
    [global]
      hist: /cfg/hists
      th-maxage: 7776000

    [accounts]
    CONF
    printf '  greenhead: %s\n\n' "$PASSWORD" >> ${configPath}
    cat >> ${configPath} <<'CONF'
    [/immich]
      /data/immich
      accs:
        r: greenhead

    [/backups]
      /data/backups
      accs:
        r: greenhead

    [/]
      /data
      accs:
        rwda: greenhead
    CONF
    chmod 0600 ${configPath}
  '';
in
{
  config = lib.mkIf cfg.enable {
    # agenix 시크릿
    age.secrets.copyparty-password = {
      file = ../../../../secrets/copyparty-password.age;
      owner = "root";
      mode = "0400";
    };

    # 데이터 디렉토리 (SSD)
    systemd.tmpfiles.rules = [
      "d ${dockerData}/copyparty/hists 0755 root root -"
      "d ${dockerData}/copyparty/config 0700 root root -"
    ];

    # 비밀번호 주입 서비스 (컨테이너 시작 전 실행)
    systemd.services.copyparty-config = {
      description = "Generate Copyparty config with secrets";
      wantedBy = [ "podman-copyparty.service" ];
      before = [ "podman-copyparty.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = configScript;
        RemainAfterExit = true;
        UMask = "0077";
      };
    };

    # Copyparty 컨테이너
    # copyparty/ac 이미지의 ENTRYPOINT에 이미 `-c /z/initcfg`가 포함됨
    # -c는 반복 가능하며, 나중 설정이 이전을 오버라이드
    virtualisation.oci-containers.containers.copyparty = {
      image = "copyparty/ac:latest";
      autoStart = true;
      cmd = [
        "-c"
        "/cfg/config.conf"
      ];
      ports = [ "${minipcTailscaleIP}:${toString cfg.port}:3923" ];
      volumes = [
        "${configPath}:/cfg/config.conf:ro"
        "${dockerData}/copyparty/hists:/cfg/hists"
        "${mediaData}:/data"
      ];
      environment = {
        TZ = config.time.timeZone;
      };
      extraOptions = [
        "--memory=${copyparty.memory}"
        "--memory-swap=${copyparty.memorySwap}"
        "--cpus=${copyparty.cpus}"
      ];
    };

    # Tailscale IP 바인딩 대기 + 설정 파일 존재 확인
    systemd.services.podman-copyparty = {
      after = [ "tailscaled.service" ];
      wants = [ "tailscaled.service" ];
      serviceConfig = {
        ExecStartPre = import ../../lib/tailscale-wait.nix { inherit pkgs; };
        ConditionPathExists = configPath;
      };
    };

    # 방화벽
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ cfg.port ];
  };
}
