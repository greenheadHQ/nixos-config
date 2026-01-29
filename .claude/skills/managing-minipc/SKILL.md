---
name: managing-minipc
description: |
  This skill should be used when the user asks about NixOS installation,
  "nixos-rebuild", "disko", "hardware-configuration.nix", "generation rollback",
  or encounters NixOS errors. For nix-darwin, use managing-macos.
  For flake issues, use understanding-nix.
---

# NixOS MiniPC 관리

NixOS MiniPC 설치, 설정, 유지보수 가이드입니다. (NixOS 전용)

## 빠른 참조

### Rebuild 명령어

```bash
# 설정 적용 (미리보기 + 적용)
nrs

# 오프라인 rebuild (캐시만 사용)
nrs --offline

# 미리보기만
nrp
```

### MiniPC 접속

```bash
# Tailscale VPN 사용 (권장)
ssh greenhead-minipc  # ~/.ssh/config에 정의됨

# 직접 IP 접속
ssh green@100.x.x.x
```

### 주요 파일 위치

| 파일 | 용도 |
|------|------|
| `hosts/greenhead-minipc/default.nix` | MiniPC 호스트 설정 |
| `hosts/greenhead-minipc/disko.nix` | 디스크 파티셔닝 |
| `hosts/greenhead-minipc/hardware-configuration.nix` | 하드웨어 설정 (자동 생성) |
| `modules/nixos/configuration.nix` | NixOS 공통 설정 + 홈서버 서비스 활성화 |
| `modules/nixos/options/homeserver.nix` | mkOption 기반 서비스 정의 |
| `modules/nixos/programs/docker/runtime.nix` | Podman 런타임 공통 설정 |
| `modules/nixos/programs/docker/immich.nix` | Immich 서비스 (mkIf 래핑) |
| `modules/nixos/home.nix` | Home Manager (NixOS) |
| `libraries/constants.nix` | 전역 상수 (IP, 경로, SSH 키 등) |

## 시스템 복구

### 부팅 실패 시

```bash
# GRUB 메뉴에서 이전 세대 선택
# 또는 Live USB로 부팅 후

# 1. 파티션 마운트
mount /dev/nvme0n1p2 /mnt
mount /dev/nvme0n1p1 /mnt/boot

# 2. 이전 세대로 롤백
nixos-rebuild switch --rollback
```

### 세대 관리

```bash
# 세대 목록 확인
nix-env --list-generations -p /nix/var/nix/profiles/system

# 특정 세대로 롤백
nixos-rebuild switch --rollback

# 오래된 세대 정리
nix-collect-garbage -d
```

## 자주 발생하는 문제

1. **nixos-install 시 flake 캐시 문제**: `--refresh` 옵션 사용
2. **hardware-configuration.nix 충돌**: disko와 fileSystems 중복 확인
3. **부팅 불가**: GRUB에서 이전 세대 선택 후 롤백

## 레퍼런스

- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
- 설치 가이드: [references/installation.md](references/installation.md)
- 기능 목록: [references/features.md](references/features.md)
