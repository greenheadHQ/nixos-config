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
      no-crt
      rproxy: 1

    [accounts]
    CONF
    printf '  greenhead: %s\n\n' "$PASSWORD" >> ${configPath}
    cat >> ${configPath} <<'CONF'
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
    # 이미지 ENTRYPOINT가 `-c /z/initcfg`를 로드하여 루트 볼륨 충돌 발생
    # --entrypoint로 오버라이드하여 우리 설정만 사용
    virtualisation.oci-containers.containers.copyparty = {
      image = "copyparty/ac:latest";
      autoStart = true;
      cmd = [
        "-m"
        "copyparty"
        "-c"
        "/cfg/config.conf"
      ];
      ports = [ "127.0.0.1:${toString cfg.port}:3923" ];
      volumes = [
        "${configPath}:/cfg/config.conf:ro"
        "${dockerData}/copyparty/hists:/cfg/hists"
        "${mediaData}:/data"
      ];
      environment = {
        TZ = config.time.timeZone;
      };
      extraOptions = [
        "--entrypoint=python3"
        "--memory=${copyparty.memory}"
        "--memory-swap=${copyparty.memorySwap}"
        "--cpus=${copyparty.cpus}"
      ];
    };

    # 설정 파일 존재 확인
    systemd.services.podman-copyparty = {
      serviceConfig = {
        ConditionPathExists = configPath;
      };
    };
  };
}
