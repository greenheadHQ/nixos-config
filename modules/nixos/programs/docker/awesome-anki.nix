# modules/nixos/programs/docker/awesome-anki.nix
# Anki 카드 분할 웹 서비스 (awesome-anki)
# --network=host: AnkiConnect가 Tailscale IP에서만 리슨하므로 호스트 네트워크 필요
# 알려진 제한: awesome-anki는 0.0.0.0에 바인딩됨 (HOST 환경변수 미지원).
# Tailscale 방화벽이 외부 TCP를 차단하고, WireGuard 암호화가 적용되므로 수용 가능.
{
  config,
  pkgs,
  lib,
  constants,
  ...
}:

let
  cfg = config.homeserver.awesomeAnki;
  inherit (constants.paths) dockerData;
  inherit (constants.containers) awesomeAnki;
  inherit (constants.network) minipcTailscaleIP;

  openaiKeyPath = config.age.secrets.awesome-anki-openai-key.path;
  geminiKeyPath = config.age.secrets.awesome-anki-gemini-key.path;
  envFilePath = "/run/awesome-anki-env";

  # agenix 시크릿에서 환경변수 파일 생성 (karakeep.nix 패턴)
  envScript = pkgs.writeShellScript "awesome-anki-env-gen" ''
    set -euo pipefail
    # 시크릿 파일에서 KEY=VALUE 접두어 제거 (karakeep.nix 패턴)
    OPENAI_RAW=$(cat ${openaiKeyPath})
    case "$OPENAI_RAW" in
      OPENAI_API_KEY=*) OPENAI_KEY="''${OPENAI_RAW#OPENAI_API_KEY=}" ;;
      *) OPENAI_KEY="$OPENAI_RAW" ;;
    esac
    GEMINI_RAW=$(cat ${geminiKeyPath})
    case "$GEMINI_RAW" in
      GEMINI_API_KEY=*) GEMINI_KEY="''${GEMINI_RAW#GEMINI_API_KEY=}" ;;
      *) GEMINI_KEY="$GEMINI_RAW" ;;
    esac
    printf 'OPENAI_API_KEY=%s\nGEMINI_API_KEY=%s\n' "$OPENAI_KEY" "$GEMINI_KEY" > ${envFilePath}
    chmod 0400 ${envFilePath}
  '';
in
{
  config = lib.mkIf cfg.enable {
    # ═══════════════════════════════════════════════════════════════
    # agenix 시크릿
    # ═══════════════════════════════════════════════════════════════
    age.secrets.awesome-anki-openai-key = {
      file = ../../../../secrets/awesome-anki-openai-key.age;
      owner = "root";
      mode = "0400";
    };
    age.secrets.awesome-anki-gemini-key = {
      file = ../../../../secrets/awesome-anki-gemini-key.age;
      owner = "root";
      mode = "0400";
    };

    # ═══════════════════════════════════════════════════════════════
    # 데이터 디렉토리 (SSD)
    # UID 1001은 컨테이너 내부 사용자 (constants.ids에 추가하지 않음)
    # ═══════════════════════════════════════════════════════════════
    systemd.tmpfiles.rules = [
      "d ${dockerData}/awesome-anki 0755 1001 1001 -"
      "d ${dockerData}/awesome-anki/data 0755 1001 1001 -"
      "d ${dockerData}/awesome-anki/output 0755 1001 1001 -"
    ];

    # ═══════════════════════════════════════════════════════════════
    # 환경변수 파일 생성 서비스 (컨테이너 시작 전)
    # ═══════════════════════════════════════════════════════════════
    systemd.services.awesome-anki-env = {
      description = "Generate awesome-anki environment file with API keys";
      wantedBy = [ "podman-awesome-anki.service" ];
      before = [ "podman-awesome-anki.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = envScript;
        RemainAfterExit = true;
        UMask = "0077";
      };
    };

    # ═══════════════════════════════════════════════════════════════
    # awesome-anki 컨테이너
    # ═══════════════════════════════════════════════════════════════
    virtualisation.oci-containers.containers.awesome-anki = {
      image = "ghcr.io/greenheadhq/awesome-anki:latest";
      autoStart = true;
      volumes = [
        "${dockerData}/awesome-anki/data:/app/data"
        "${dockerData}/awesome-anki/output:/app/output"
      ];
      environmentFiles = [ envFilePath ];
      environment = {
        ANKI_CONNECT_URL = "http://${minipcTailscaleIP}:${toString constants.network.ports.ankiConnect}";
        ANKI_SPLITTER_REQUIRE_API_KEY = "false";
        PORT = toString cfg.port;
      };
      extraOptions = [
        "--network=host"
        "--memory=${awesomeAnki.memory}"
        "--cpus=${awesomeAnki.cpus}"
      ];
    };

    # 시크릿 존재 확인 + env 서비스 의존성
    systemd.services.podman-awesome-anki = {
      after = [ "awesome-anki-env.service" ];
      wants = [ "awesome-anki-env.service" ];
      unitConfig = {
        ConditionPathExists = [
          openaiKeyPath
          geminiKeyPath
        ];
      };
    };
  };
}
