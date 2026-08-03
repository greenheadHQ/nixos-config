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
  inherit (constants.network) podmanSubnet;

  configPath = "${dockerData}/copyparty/config/copyparty.conf";
  passwordPath = config.age.secrets.copyparty-password.path;

  # 비밀번호를 주입한 설정 파일 생성
  # <<'CONF' (quoted heredoc)로 셸 해석 방지 + printf로 비밀번호만 안전 삽입
  #
  # 검색 인덱싱 3옵션: e2dsa = 시작 시 전 볼륨 색인 (이게 없으면 웹 UI에 검색 버튼 자체가 안 뜬다),
  # no-hash의 `.`은 "모든 경로"를 뜻하는 정규식 (초기 해시 스캔 회피), re-maxage = 재스캔 주기(초).
  # no-hash는 값이 필수인 옵션이라 `.`만 지우고 키를 남기면 argparse가 거부해 컨테이너가 기동하지 않는다
  # — 해시를 되살리려면 줄째로 지운다. 트레이드오프 상세는
  # .claude/skills/hosting-copyparty/SKILL.md "검색 인덱싱" 참조.
  configScript = pkgs.writeShellScript "copyparty-config-gen" ''
    PASSWORD=$(cat ${passwordPath})
    cat > ${configPath} <<'CONF'
    [global]
      hist: /cfg/hists
      th-maxage: 7776000
      no-crt
      rproxy: 1
      xff-src: ${podmanSubnet}
      e2dsa
      no-hash: .
      re-maxage: 86400

    [accounts]
    CONF
    printf '  greenhead: %s\n\n' "$PASSWORD" >> ${configPath}
    cat >> ${configPath} <<'CONF'
    [/]
      /data
      accs:
        rwmda: greenhead
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
      "d ${dockerData}/copyparty/sessions 0700 root root -" # 세션 DB + salt + iphash
    ];

    # 비밀번호 주입 서비스 (컨테이너 시작 전 실행)
    systemd.services.copyparty-config = {
      description = "Generate Copyparty config with secrets";
      wantedBy = [ "podman-copyparty.service" ];
      before = [ "podman-copyparty.service" ];
      # configScript는 비밀번호 '경로'만 담으므로 .age를 재암호화해도 store path가 그대로다.
      # 암호문 자체를 트리거로 걸어야 비밀번호 교체가 conf 재생성으로 이어진다.
      restartTriggers = [ config.age.secrets.copyparty-password.file ];
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
      image = "copyparty/ac:1.20.12";
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
        "${dockerData}/copyparty/sessions:/cfg/copyparty" # 세션 영속성
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

    # 시크릿 존재 확인 (런타임 생성 config 파일보다 안정적)
    systemd.services.podman-copyparty = {
      unitConfig = {
        ConditionPathExists = passwordPath;
      };
      # config 내용은 컨테이너 유닛에 들어가지 않고 경로만 볼륨 인자로 들어간다.
      # conf의 두 입력(생성 스크립트 + 비밀번호 암호문)을 모두 트리거로 걸어야
      # 설정 변경과 비밀번호 교체가 컨테이너 재시작으로 이어진다
      # (copyparty는 시작 시점에만 conf를 읽는다).
      restartTriggers = [
        configScript
        config.age.secrets.copyparty-password.file
      ];
    };
  };
}
