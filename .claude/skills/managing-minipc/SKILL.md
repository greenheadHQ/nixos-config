---
name: managing-minipc
description: |
  This skill should be used when the user asks about NixOS MiniPC management,
  nixos-rebuild, disko, hardware-configuration.nix, generation rollback,
  config placement ("설정 배치", "어디에 넣어야", "configuration.nix에 넣을까 host에 넣을까"),
  or NixOS boot/rebuild errors.
  Triggers: "MiniPC", "미니PC", "nixos-rebuild", "disko",
  "hardware-configuration.nix", "rollback", "WoL", "Wake-on-LAN", "watchdog",
  "호스트 설정", "하드웨어 설정", "설정 배치", "어디에 넣어야", "boot failure".
  For nix-darwin use managing-macos. For flake issues use understanding-nix.
---

# NixOS MiniPC 관리

NixOS MiniPC 설치, 설정, 유지보수, 설정 배치 가이드입니다. (NixOS 전용)

## 설정 배치 규칙

새 NixOS 설정을 추가할 때 반드시 아래 기준에 따라 배치 위치를 결정할 것.

### 판단 기준: "다른 NixOS 호스트에서도 동일하게 적용할 수 있는가?"

| 배치 위치 | 기준 | 예시 |
|-----------|------|------|
| `hosts/<hostname>/default.nix` | 특정 하드웨어에 종속된 설정 | 인터페이스명(`enp2s0`), 디스크 UUID, WoL, PCI 장치 |
| `hosts/<hostname>/disko.nix` | 디스크 파티셔닝 | NVMe 파티션 레이아웃 |
| `hosts/<hostname>/hardware-configuration.nix` | 자동 생성 하드웨어 감지 | 커널 모듈, CPU 마이크로코드 |
| `modules/nixos/configuration.nix` | 모든 NixOS 호스트에 공통 적용 | watchdog, kernel.panic, sudo, nix-ld |
| `modules/nixos/programs/*.nix` | 공통 서비스/프로그램 모듈 | Tailscale, SSH 서버, Caddy |
| `libraries/constants.nix` | 여러 모듈에서 참조하는 값 | IP, 포트, 경로, SSH 키, UID |

### 하드웨어 종속 설정 판별 체크리스트

다음 중 하나라도 해당하면 `hosts/<hostname>/`에 배치:

- 네트워크 인터페이스명 포함 (`enp2s0`, `wlp1s0`, `eno1` 등)
- 디스크 장치 경로 또는 UUID 포함 (`/dev/nvme0n1`, `by-uuid/...`)
- PCI 버스/슬롯 주소 참조 (`0000:02:00.0`)
- 특정 하드웨어 모델/드라이버에 의존
- `fileSystems.*` 마운트 포인트 (disko가 관리하지 않는 추가 디스크)

### 현재 hosts/greenhead-minipc/default.nix 구성

```nix
# 하드웨어 종속 설정만 포함
users.users.${username}.openssh.authorizedKeys.keys = [ ... ];  # 이 호스트의 SSH 접근 허용키
networking.interfaces.enp2s0.wakeOnLan.enable = true;           # NIC 종속 (Intel igc, PCI 02:00.0)
fileSystems."/mnt/data" = { device = "by-uuid/..."; };          # HDD UUID 종속
```

## 빠른 참조

### Rebuild 명령어

```bash
nrs             # 설정 적용 (미리보기 + 적용)
nrs --offline   # 오프라인 rebuild (캐시만 사용)
nrp             # 미리보기만
```

### MiniPC 접속

```bash
ssh minipc      # ~/.ssh/config에 정의됨 (macOS에서)
```

### 주요 파일 위치

| 파일 | 용도 |
|------|------|
| `hosts/greenhead-minipc/default.nix` | 호스트별 하드웨어 종속 설정 |
| `hosts/greenhead-minipc/disko.nix` | 디스크 파티셔닝 |
| `hosts/greenhead-minipc/hardware-configuration.nix` | 하드웨어 설정 (자동 생성) |
| `modules/nixos/configuration.nix` | NixOS 공통 설정 + 홈서버 서비스 활성화 |
| `modules/nixos/options/homeserver.nix` | mkOption 기반 서비스 정의 |
| `modules/nixos/programs/` | 공통 서비스 모듈 (Tailscale, SSH, Caddy 등) |
| `modules/nixos/home.nix` | Home Manager (NixOS) |
| `libraries/constants.nix` | 전역 상수 (IP, 경로, SSH 키 등) |

## 시스템 복구

`nixos-rebuild switch --rollback` 또는 systemd-boot 메뉴에서 이전 세대 선택.
상세 내용: [references/installation.md](references/installation.md)

## 원격 복원력

커널 패닉 자동 재부팅(10초), systemd watchdog(30초 hang 감지 → 10분 후 강제 재부팅), WoL 지원.
상세 내용: [references/features.md](references/features.md)

## 자주 발생하는 문제

1. **nixos-install 시 flake 캐시 문제**: `--refresh` 옵션 사용
2. **hardware-configuration.nix 충돌**: disko와 fileSystems 중복 확인
3. **부팅 불가**: systemd-boot에서 이전 세대 선택 후 롤백

## 레퍼런스

- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
- 설치 가이드: [references/installation.md](references/installation.md)
- 기능 목록: [references/features.md](references/features.md)
