# libraries/constants.nix
# 프로젝트 전역 상수 - 단일 소스 (Single Source of Truth)
# secrets/secrets.nix에서도 import하므로 SSH 키의 유일한 정의 위치
{
  # ═══════════════════════════════════════════════════════════════
  # 네트워크
  # ═══════════════════════════════════════════════════════════════
  network = {
    # Tailscale IP (tailscale ip -4 로 확인)
    minipcTailscaleIP = "100.79.80.95";
    macbookTailscaleIP = "100.65.50.98";

    # 서비스 포트
    ports = {
      immich = 2283;
      immichMl = 3003;
      uptimeKuma = 3002;
      ankiSync = 27701;
      copyparty = 3923;
      vaultwarden = 8222;
      caddy = 443;
    };

    # Podman 브릿지 네트워크 기본 서브넷
    podmanSubnet = "10.88.0.0/16";
  };

  # ═══════════════════════════════════════════════════════════════
  # 도메인 및 리버스 프록시
  # ═══════════════════════════════════════════════════════════════
  domain = {
    base = "greenhead.dev";
    subdomains = {
      immich = "immich";
      uptimeKuma = "uptime-kuma";
      copyparty = "copyparty";
      vaultwarden = "vaultwarden";
      dev = "dev";
    };
  };

  # ═══════════════════════════════════════════════════════════════
  # 경로
  # ═══════════════════════════════════════════════════════════════
  paths = {
    dockerData = "/var/lib/docker-data"; # SSD - 컨테이너 데이터
    mediaData = "/mnt/data"; # HDD - 미디어 파일
    immichUploadCache = "/var/lib/docker-data/immich/upload-cache"; # immich 업로드 캐시
  };

  # ═══════════════════════════════════════════════════════════════
  # SSH 공개키 (cat ~/.ssh/id_ed25519.pub)
  # secrets/secrets.nix에서 이 값을 import하므로 여기가 단일 소스
  # ═══════════════════════════════════════════════════════════════
  sshKeys = {
    # MacBook Pro (greenhead-MacBookPro)
    macbook = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDN048Qg9ABnM26jU0X0w2mG9pqcrwuVrcihvDbkRVX8 greenhead-home-mac-2025-10";
    # MiniPC (greenhead-minipc)
    minipc = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN64oEThAvKkI806sMRcIXOJxiaT2A8BbqcO4DfWlirO greenhead@minipc";
  };

  # ═══════════════════════════════════════════════════════════════
  # 컨테이너 리소스 제한
  # ═══════════════════════════════════════════════════════════════
  containers = {
    immich = {
      postgres = {
        memory = "1g";
      };
      redis = {
        memory = "512m";
      };
      ml = {
        memory = "2g";
        memorySwap = "3g";
        cpus = "2";
      };
      server = {
        memory = "4g";
        memorySwap = "6g";
      };
    };
    uptimeKuma = {
      memory = "512m";
      cpus = "0.5";
    };
    copyparty = {
      memory = "1g";
      memorySwap = "1g";
      cpus = "1";
    };
    vaultwarden = {
      memory = "256m";
      cpus = "0.5";
    };
  };

  # ═══════════════════════════════════════════════════════════════
  # UID/GID (시스템 사용자/그룹 ID)
  # ═══════════════════════════════════════════════════════════════
  ids = {
    postgres = 999; # PostgreSQL 컨테이너 기본 UID
    user = 1000; # greenhead 사용자 UID
    users = 100; # users 그룹 GID
    render = 303; # NixOS render 그룹 GID (하드웨어 가속, /dev/dri)
  };

  # ═══════════════════════════════════════════════════════════════
  # macOS 설정
  # ═══════════════════════════════════════════════════════════════
  macos = {
    dock.tileSize = 36; # Dock 아이콘 크기 (픽셀)
    keyboard = {
      initialKeyRepeat = 15; # 키 반복 지연 (15 = 225ms, 최소값)
      keyRepeat = 1; # 키 반복 속도 (1 = 15ms, 최소=가장 빠름)
    };
  };

  # ═══════════════════════════════════════════════════════════════
  # SSH 타임아웃 설정 (Darwin sshd + NixOS openssh 공통)
  # ═══════════════════════════════════════════════════════════════
  ssh = {
    clientAliveInterval = 60; # 초 단위
    clientAliveCountMax = 3; # 최대 재시도 횟수
  };

  # ═══════════════════════════════════════════════════════════════
  # 온도 모니터링 임계값
  # 하드웨어 기준: CPU crit=105°C, NVMe crit=94.8°C
  # 소프트웨어 임계값은 하드웨어 대비 ~10°C 마진으로 조기 대응
  # ═══════════════════════════════════════════════════════════════
  tempMonitor = {
    cpu = {
      warning = 80; # °C — Pushover priority 0 (일반)
      critical = 95; # °C — Pushover priority 1 (긴급)
    };
    nvme = {
      warning = 70;
      critical = 85;
    };
    cooldown = {
      warning = 900; # 15분 (초)
      critical = 300; # 5분 (초)
    };
  };
}
