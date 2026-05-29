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
      ankiConnect = 8765;
      copyparty = 3923;
      vaultwarden = 8222;
      karakeep = 3000;
      awesomeAnki = 3100;
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
      karakeep = "archive";
      awesomeAnki = "anki";
    };
  };

  # ═══════════════════════════════════════════════════════════════
  # 경로
  # ═══════════════════════════════════════════════════════════════
  paths = {
    dockerData = "/var/lib/docker-data"; # SSD - 컨테이너 데이터
    mediaData = "/mnt/data"; # HDD - 미디어 파일
    immichUploadCache = "/var/lib/docker-data/immich/upload-cache"; # immich 업로드 캐시
    # agenix 복호화 identity (host private key) + opnix SA 만료 record source (PRD #780)
    # host key는 부팅 의존 시크릿(SA token) 복호화 전용. user key(/home/<user>/.ssh/id_ed25519)는
    # username 보간이 필요해 정적 constants에 담을 수 없으므로 configuration.nix에서 inline 유지한다.
    agenixHostIdentityKey = "/etc/ssh/ssh_host_ed25519_key";
    opnixServiceAccountExpirySource = ../secrets/opnix-service-account-expiry.txt;
    # opnix SA token agenix secret — opnix/default.nix가 tokenFile 등록에 사용
    opnixServiceAccountTokenAge = ../secrets/opnix-service-account-token.age;
  };

  # ═══════════════════════════════════════════════════════════════
  # SSH 공개키 (cat ~/.ssh/id_ed25519.pub)
  # secrets/secrets.nix에서 이 값을 import하므로 여기가 단일 소스
  # ═══════════════════════════════════════════════════════════════
  sshKeys = {
    # MacBook Pro (greenhead-MacBookPro)
    macbook = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDN048Qg9ABnM26jU0X0w2mG9pqcrwuVrcihvDbkRVX8 greenhead-home-mac-2025-10";
    # MiniPC (greenhead-minipc) — 사용자 로그인 키 (user key)
    minipc = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN64oEThAvKkI806sMRcIXOJxiaT2A8BbqcO4DfWlirO greenhead@minipc";
  };

  # ═══════════════════════════════════════════════════════════════
  # SSH Host 공개키 (cat /etc/ssh/ssh_host_ed25519_key.pub)
  # 머신 고유 키(root 전용). 부팅 의존 시크릿(SA token 등) 전용 recipient.
  # user 로그인 키(sshKeys)와 분리해 노출 표면을 최소화한다 (PRD #780 host key 기반 복호화).
  # ═══════════════════════════════════════════════════════════════
  hostKeys = {
    minipc = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMq3woA41glyia2HaxsQl7JL4GfSGsmn3vJoiGFXO3Qi root@greenhead-minipc";
  };

  # ═══════════════════════════════════════════════════════════════
  # 디바이스별 SSH 공개키 — MiniPC authorized_keys 등록용 (PRD #780 Phase 2a)
  # 1Password Automation vault `ssh` tag inventory와 일관. agenix recipient(sshKeys)와는 분리.
  # private 보관: macSsh = 1Password vault(SSH agent), emergency = ~/.ssh + 1Password backup,
  #   iphone/ipad = Termius 디바이스 keychain.
  # ═══════════════════════════════════════════════════════════════
  sshDeviceKeys = {
    macSsh = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGijyrxefX4n5oRJ2775QDOFtBfjPeNzjym2i7TJx9qr mac-ssh";
    iphone = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMBwI6UCcwfwcnwHIer2GACL1S8qW7azfwGigAcngj3X iphone-ssh";
    ipad = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFF+/kpJu3NOOFvjPZAKPqjT+IG8Q2cMKYi/YV4yR355 ipad-ssh";
    emergency = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMM0hYpFqehy7U96Ms4348SStVue7pYbR3+B3PlGV+de emergency-fallback";
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
    awesomeAnki = {
      memory = "1g";
      cpus = "1";
    };
    karakeep = {
      app = {
        memory = "2g";
        memorySwap = "3g";
        cpus = "1";
      };
      chrome = {
        memory = "2g";
        memorySwap = "3g";
        cpus = "1";
      };
      meilisearch = {
        memory = "1g";
        memorySwap = "1536m";
        cpus = "0.5";
      };
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
    paths = {
      # Shottr/FolderActions 공통 저장 경로 (HOME 상대경로)
      shottrDefaultFolderRelative = "FolderActions/upload-immich";
    };
  };

  # ═══════════════════════════════════════════════════════════════
  # 1Password vault 이름 (단일 소스)
  # GUI에서 동일 이름으로 vault를 생성해야 op CLI가 조회 가능
  # ═══════════════════════════════════════════════════════════════
  onePassword = {
    # op CLI 멀티 계정(개인+회사) 환경에서 Automation vault가 속한 개인 account 고정.
    # my.1password.com은 개인 1Password 공통 sign-in 도메인 (개인 식별 정보 아님).
    # MiniPC(Phase 3)는 OP_SERVICE_ACCOUNT_TOKEN이 account를 결정하므로 본 값은 Mac biometric 경로 전용.
    account = "my.1password.com";
    vaults = {
      personal = "Personal"; # 1Password 기본 Personal vault (GUI 표시명)
      automation = "Automation"; # LLM·자동화·시스템 토큰 + 디바이스 SSH key inventory
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
  # mise (런타임 버전 관리자) — shims 경로 SoT
  # ═══════════════════════════════════════════════════════════════
  # shims 디렉토리 우선순위 (mise 공식 규약):
  #   MISE_DATA_DIR → $XDG_DATA_HOME/mise → $HOME/.local/share/mise
  # 사용처: modules/shared/programs/shell/default.nix envExtra/initContent의 PATH 가드.
  # shell expansion 문자열로 저장 — nix는 literal로 흘려보내고 zsh가 평가한다.
  # 본 저장소는 MISE_DATA_DIR과 XDG_DATA_HOME 둘 다 명시 설정하지 않아 기본 경로가 사용된다.
  mise = {
    shimsDirExpr = "\${MISE_DATA_DIR:-\${XDG_DATA_HOME:-$HOME/.local/share}/mise}/shims";
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
