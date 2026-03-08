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
  imageName = "ghcr.io/greenheadhq/awesome-anki:latest";

  # GHCR에서 latest 이미지 pull → digest 비교 → 변경 시 systemctl restart
  # podman auto-update는 NixOS oci-containers의 systemd 라이프사이클과 충돌하므로
  # systemctl restart를 직접 사용하여 안전하게 교체
  autoUpdateScript = pkgs.writeShellScript "awesome-anki-auto-update" ''
    set -euo pipefail
    CURRENT=$(${pkgs.podman}/bin/podman inspect awesome-anki --format '{{.Image}}' 2>/dev/null || echo "none")
    ${pkgs.podman}/bin/podman pull ${imageName} >/dev/null 2>&1 || exit 0
    NEW=$(${pkgs.podman}/bin/podman image inspect ${imageName} --format '{{.Id}}' 2>/dev/null || echo "none")
    if [ "$CURRENT" != "$NEW" ]; then
      echo "awesome-anki: new image detected, restarting..."
      /run/current-system/sw/bin/systemctl restart podman-awesome-anki
    fi
  '';

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
      image = imageName;
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

    # ═══════════════════════════════════════════════════════════════
    # 이미지 자동 업데이트 (5분 주기)
    # ═══════════════════════════════════════════════════════════════
    systemd.services.awesome-anki-auto-update = {
      description = "Auto-update awesome-anki container image";
      after = [ "podman-awesome-anki.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = autoUpdateScript;
      };
    };

    systemd.timers.awesome-anki-auto-update = {
      description = "awesome-anki image auto-update timer";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*:0/5";
        Persistent = true;
      };
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
