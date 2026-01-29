#!/usr/bin/env bash
# scripts/add-host.sh
# 새 호스트 추가 마법사 - 필요한 파일 생성 및 수정 안내
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

echo "═══════════════════════════════════════════════════"
echo " nixos-config 호스트 추가 마법사"
echo "═══════════════════════════════════════════════════"
echo

# 1. 플랫폼 선택
echo "1. 플랫폼을 선택하세요:"
echo "   [1] macOS (nix-darwin)"
echo "   [2] NixOS"
read -rp "선택 (1/2): " platform_choice

case "$platform_choice" in
  1) platform="darwin" ;;
  2) platform="nixos" ;;
  *) echo "잘못된 선택입니다."; exit 1 ;;
esac

# 2. 호스트명
read -rp "2. 호스트명 (예: greenhead-MacBookPro): " hostname

# 3. 사용자명
read -rp "3. 사용자명 (예: green): " username

# 4. 호스트 유형
echo "4. 호스트 유형을 선택하세요:"
echo "   [1] personal"
echo "   [2] work"
echo "   [3] server"
read -rp "선택 (1/2/3): " type_choice

case "$type_choice" in
  1) host_type="personal" ;;
  2) host_type="work" ;;
  3) host_type="server" ;;
  *) echo "잘못된 선택입니다."; exit 1 ;;
esac

# 5. SSH 공개키
read -rp "5. SSH 공개키 (ssh-ed25519 AAAA...): " ssh_pubkey

echo
echo "═══════════════════════════════════════════════════"
echo " 입력 확인"
echo "═══════════════════════════════════════════════════"
echo "  플랫폼:    $platform"
echo "  호스트명:  $hostname"
echo "  사용자명:  $username"
echo "  유형:      $host_type"
echo "  SSH 공개키: ${ssh_pubkey:0:50}..."
echo

read -rp "계속하시겠습니까? (y/N): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo "취소되었습니다."
  exit 0
fi

echo
echo "═══════════════════════════════════════════════════"
echo " 수동 수정 안내"
echo "═══════════════════════════════════════════════════"
echo
echo "아래 파일들을 수동으로 수정해주세요:"
echo

# NixOS인 경우 호스트 디렉토리 생성
if [[ "$platform" == "nixos" ]]; then
  host_dir="$ROOT_DIR/hosts/$hostname"
  if [[ ! -d "$host_dir" ]]; then
    mkdir -p "$host_dir"
    echo "✓ 호스트 디렉토리 생성됨: hosts/$hostname/"

    cat > "$host_dir/default.nix" << 'NIXEOF'
# HOST_NAME 호스트 설정
{
  config,
  lib,
  pkgs,
  inputs,
  username,
  constants,
  ...
}:

{
  imports = [
    ./hardware-configuration.nix
  ];

  # SSH 공개키 (원격 접속용)
  users.users.${username}.openssh.authorizedKeys.keys = [
    constants.sshKeys.SSH_KEY_NAME
  ];
}
NIXEOF
    sed -i "s/HOST_NAME/$hostname/g" "$host_dir/default.nix"
    echo "✓ hosts/$hostname/default.nix 생성됨 (SSH_KEY_NAME 수정 필요)"
    echo
    echo "  ⚠️  hardware-configuration.nix는 NixOS 설치 후 생성됩니다."
    echo "  ⚠️  필요하면 disko.nix도 추가하세요."
  fi
  echo
fi

echo "1️⃣  libraries/constants.nix - sshKeys에 새 키 추가:"
echo "    sshKeys = {"
echo "      # ... 기존 키 ..."
echo "      newHost = \"$ssh_pubkey\";"
echo "    };"
echo

echo "2️⃣  flake.nix - ${platform}Hosts에 새 호스트 추가:"
if [[ "$platform" == "darwin" ]]; then
  echo "    darwinHosts = {"
  echo "      # ... 기존 호스트 ..."
  echo "      \"$hostname\" = mkDarwinHost \"$username\" \"$host_type\";"
  echo "    };"
else
  echo "    nixosHosts = {"
  echo "      # ... 기존 호스트 ..."
  echo "      \"$hostname\" = mkNixosHost \"$username\" \"$host_type\";"
  echo "    };"
fi
echo

echo "3️⃣  기존 시크릿 재암호화 (새 호스트가 복호화할 수 있도록):"
echo "    cd $ROOT_DIR"
echo "    nix run github:ryantm/agenix -- -r"
echo

echo "4️⃣  빌드 검증:"
if [[ "$platform" == "darwin" ]]; then
  echo "    nix build .#darwinConfigurations.$hostname.system --dry-run"
else
  echo "    nix build .#nixosConfigurations.$hostname.config.system.build.toplevel --dry-run"
fi
echo

echo "═══════════════════════════════════════════════════"
echo " 완료!"
echo "═══════════════════════════════════════════════════"
