#!/usr/bin/env bash
# MiniPC NixOS 설치 스크립트 (참조용)
# NixOS ISO로 부팅 후 실행

set -euo pipefail

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
echo_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
echo_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 1. root 확인
if [[ $EUID -ne 0 ]]; then
   echo_error "이 스크립트는 root 권한으로 실행해야 합니다."
   echo_info "sudo -i 로 root로 전환 후 다시 실행하세요."
   exit 1
fi

echo_info "=== MiniPC NixOS 설치 스크립트 ==="
echo ""

# 2. 네트워크 확인
echo_info "네트워크 연결 확인 중..."
if ! ping -c 1 google.com &> /dev/null; then
    echo_error "네트워크 연결이 필요합니다."
    echo_info "WiFi 연결: wpa_supplicant -B -i wlp... -c <(wpa_passphrase SSID PASSWORD)"
    exit 1
fi
echo_info "네트워크 연결 확인됨"
echo ""

# 3. 디스크 구성 확인 (매우 중요!)
echo_warn "=== 디스크 구성 확인 (중요!) ==="
echo ""
lsblk -o NAME,SIZE,MODEL,TYPE,MOUNTPOINTS
echo ""

echo_warn "예상 구성:"
echo "  - nvme0n1 (476.9G) ← NixOS 설치 대상 (포맷됨)"
echo "  - sda (1.8T)       ← 보존! (media 데이터)"
echo ""

read -p "위 디스크 구성이 맞습니까? (y/N): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo_error "설치를 중단합니다. 디스크 구성을 확인하세요."
    exit 1
fi

# 4. disko 설정 다운로드
echo_info "disko 설정 다운로드 중..."
curl -o /tmp/disko.nix https://raw.githubusercontent.com/greenheadHQ/nixos-config/main/hosts/greenhead-minipc/disko.nix

echo_info "disko 설정 확인:"
grep "device =" /tmp/disko.nix
echo ""

read -p "disko가 nvme0n1을 대상으로 하고 있습니까? (y/N): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo_error "disko.nix의 device 설정을 확인하세요."
    exit 1
fi

# 5. disko 실행
echo_warn "=== disko로 NVMe 파티셔닝 시작 ==="
echo_warn "이 작업은 nvme0n1의 모든 데이터를 삭제합니다!"
echo ""

read -p "계속하시겠습니까? (y/N): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo_error "설치를 중단합니다."
    exit 1
fi

echo_info "disko 실행 중..."
nix --experimental-features "nix-command flakes" run \
  github:nix-community/disko -- \
  --mode disko /tmp/disko.nix

echo_info "파티셔닝 완료"
echo ""

# 6. 마운트 확인
echo_info "마운트 상태 확인:"
mount | grep /mnt || true
lsblk
echo ""

# 7. NixOS 설치
echo_info "=== NixOS 설치 시작 ==="
echo_info "flake: github:greenheadHQ/nixos-config#greenhead-minipc"
echo ""

read -p "NixOS 설치를 시작하시겠습니까? (y/N): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo_error "설치를 중단합니다."
    exit 1
fi

nixos-install --flake github:greenheadHQ/nixos-config#greenhead-minipc

echo ""
echo_info "=== 설치 완료! ==="
echo_info "재부팅 후 greenhead 사용자로 로그인하세요."
echo_info "초기 비밀번호는 설정해야 할 수 있습니다."
echo ""
echo_warn "다음 단계:"
echo "  1. reboot"
echo "  2. sudo tailscale up"
echo "  3. hardware-configuration.nix 교체 (Phase 2.5)"
echo ""

read -p "지금 재부팅하시겠습니까? (y/N): " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
    reboot
fi
