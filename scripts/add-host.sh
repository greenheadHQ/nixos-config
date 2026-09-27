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
read -rp "3. 사용자명 (예: greenhead): " username

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

    # macOS 기본 BSD sed의 in-place 인자 규칙은 GNU sed와 달라 `sed -i`로 HOST_NAME을
    # 치환하면 실행 환경에 따라 실패한다(#1382). 호스트명 주석은 printf로 직접 쓰고 Nix
    # 본문은 quoted heredoc으로 유지해 ${username} 같은 Nix 표현식이 셸에서 조기
    # 치환되지 않게 한다. 완성한 내용은 임시 파일에 쓴 뒤 최종 경로로 원자적 이동(mv)해,
    # 중간 실패로 HOST_NAME이 남은 default.nix가 완성본으로 오인되는 것을 막는다.
    #
    # 아래 서브셸을 `if ! ( … )`처럼 조건 문맥의 피연산자로 두면 안 된다 — bash는 조건
    # 문맥에 놓인 명령에는 errexit를 적용하지 않고, 서브셸 안에서 set -e를 다시 켜도 이
    # 예외가 풀리지 않는다(bash 3.2·5.x 양쪽에서 동일하게 재현됨). 그 상태에서는 printf·
    # cat 실패나 `{ } > tmp` 쓰기 실패가 조용히 무시되고 마지막 mv의 결과만 rc에 반영돼,
    # 쓰기가 중간에 실패해도 성공으로 보고된다. 그래서 서브셸을 최상위 명령으로 실행해
    # rc를 따로 받는다.
    set +e
    (
      set -euo pipefail
      default_nix_tmp=""
      trap 'rm -f "$default_nix_tmp"' EXIT
      default_nix_tmp="$(mktemp "$host_dir/.default.nix.XXXXXX")"
      {
        printf '# %s 호스트 설정\n' "$hostname"
        cat << 'NIXEOF'
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
      } > "$default_nix_tmp"
      # mktemp는 파일을 0600으로 만들고 mv는 이 모드를 그대로 옮긴다. 나머지 호스트
      # 파일과 같은 0644로 맞춘다(대부분의 umask에서 일반 파일이 갖는 값).
      chmod 0644 "$default_nix_tmp"
      mv "$default_nix_tmp" "$host_dir/default.nix"
    )
    default_nix_write_rc=$?
    set -e
    if [[ "$default_nix_write_rc" -ne 0 ]]; then
      # 이번 실행이 새로 만든 리프 디렉토리를 지워 재시도할 수 있게 한다(비어 있지
      # 않으면 rmdir이 그냥 실패하고 넘어간다). 호스트명에 "/"가 있으면 mkdir -p가
      # 상위 디렉토리도 새로 만들 수 있어 정리가 리프 한 단계에 그칠 수 있는데, 그
      # 입력 검증은 이 이슈 범위 밖이라 다루지 않는다.
      rmdir "$host_dir" 2>/dev/null || true
      echo "✗ hosts/$hostname/default.nix 생성 실패" >&2
      exit 1
    fi
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
