# NixOS MiniPC 설치/복구 가이드

## 목차

- [시스템 정보](#시스템-정보)
- [디스크 레이아웃](#디스크-레이아웃)
- [재설치 시 핵심 단계](#재설치-시-핵심-단계)
- [복구 방법](#복구-방법)
- [주요 설정 파일](#주요-설정-파일)

---

## 시스템 정보

| 항목 | 값 |
|------|-----|
| 호스트명 | greenhead-minipc |
| 사용자 | greenhead |
| Tailscale IP | 100.79.80.95 |
| SSH 접속 | `ssh minipc` |

---

## 디스크 레이아웃

```
NVMe (476.9GB) - /dev/nvme0n1
├── nvme0n1p1: 512MB  vfat  /boot
├── nvme0n1p2: 467GB  ext4  /
└── nvme0n1p3: 8GB    swap  [SWAP]

HDD (1.8TB) - /dev/sda
└── sda1: 1.8TB ext4 → /mnt/data (⚠️ 보존!)
```

> **경고**: HDD(/dev/sda)에는 295GB의 미디어 데이터가 있습니다. 재설치 시 절대 포맷하지 마세요.

---

## 재설치 시 핵심 단계

### 1. NixOS Live USB 부팅

```bash
sudo -i
lsblk -o NAME,SIZE,MODEL,TYPE  # HDD 확인 필수!
```

### 2. disko로 NVMe 파티셔닝

```bash
nix --experimental-features "nix-command flakes" run github:nix-community/disko -- \
  --mode disko /tmp/disko.nix
```

### 3. NixOS 설치

```bash
nixos-install --flake github:greenheadHQ/nixos-config#greenhead-minipc --no-root-passwd
```

### 4. 재부팅 후 초기 설정

```bash
# Tailscale 인증
sudo tailscale up

# nixos-config 클론
git clone git@github.com:greenheadHQ/nixos-config.git
cd nixos-config && nrs
```

---

## 복구 방법

### 부팅 실패 시

1. systemd-boot 메뉴에서 이전 세대 선택
2. 또는 Live USB로 부팅 후:

```bash
mount /dev/nvme0n1p2 /mnt
mount /dev/nvme0n1p1 /mnt/boot
nixos-enter
nixos-rebuild switch --rollback
```

### 세대 관리

```bash
# 세대 목록
nix-env --list-generations -p /nix/var/nix/profiles/system

# 롤백
sudo nixos-rebuild switch --rollback

# 가비지 컬렉션
nix-collect-garbage -d
```

---

## 주요 설정 파일

| 파일 | 용도 |
|------|------|
| `hosts/greenhead-minipc/default.nix` | 호스트 설정 |
| `hosts/greenhead-minipc/disko.nix` | 디스크 파티셔닝 |
| `hosts/greenhead-minipc/hardware-configuration.nix` | 하드웨어 설정 |
| `modules/nixos/configuration.nix` | NixOS 공통 설정 |
