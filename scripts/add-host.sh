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

    # `sed -i`는 BSD·GNU 인자 규칙이 달라 쓰지 않는다(#1382). 호스트명 주석은 printf로,
    # Nix 본문은 quoted heredoc으로 임시 파일에 쓴 뒤 mv로 배치해 미완성 파일이 남지 않게 한다.
    # 서브셸을 `if ! ( … )` 같은 조건 문맥에 두면 bash가 그 안의 errexit를 무시하므로
    # (bash 3.2·5.x 동일) 최상위에서 실행하고 rc를 따로 받는다.
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
      # mktemp의 0600 대신 heredoc 리다이렉트가 만들었을 모드(0666 & ~umask)로 맞춘다.
      default_nix_mode=$(( 0666 & ~0$(umask) ))
      chmod "$(( default_nix_mode / 64 ))$(( default_nix_mode / 8 % 8 ))$(( default_nix_mode % 8 ))" \
        "$default_nix_tmp"
      mv "$default_nix_tmp" "$host_dir/default.nix"
    )
    default_nix_write_rc=$?
    set -e
    if [[ "$default_nix_write_rc" -ne 0 ]]; then
      # 이번 실행이 만든 디렉토리를 지워 재시도할 수 있게 한다(비어 있지 않으면 남긴다).
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
echo "    NixOS 호스트 한정: 호스트 키 전용 시크릿이 필요하면 그 호스트의 /etc/ssh/ssh_host_ed25519_key.pub를 hostKeys에 따로 등록한다."
echo "    (darwin은 Home Manager agenix가 사용자 키로만 복호화한다)"
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

echo "3️⃣  시크릿 recipient 갱신 (새 호스트가 복호화해야 하는 항목만):"
echo "    작업 위치: 재암호화할 호스트의 저장소 checkout(갱신한 constants.nix·secrets.nix가 반영된 상태)의 secrets/"
echo "      agenix는 현재 디렉토리의 규칙 파일 secrets.nix를 읽는다. 이 호스트에서 한다면:"
printf '    cd %q\n' "$ROOT_DIR/secrets"
echo "    a. 새 호스트가 복호화해야 하는 시크릿을 고른다. 모든 항목에 추가하지 않는다."
echo "    b. secrets.nix에서 고른 항목마다 publicKeys를 확인한다. recipient 종류마다 복호화 identity가 다르다:"
echo "       공통 그룹(여러 호스트의 사용자 키) → 그룹에 든 호스트 중 한 곳의 사용자 ~/.ssh/id_ed25519"
echo "       사용자 키 전용 → 그 사용자의 ~/.ssh/id_ed25519"
echo "       호스트 키 전용 → 그 호스트의 /etc/ssh/ssh_host_ed25519_key (root만 읽을 수 있어 d~g를 sudo로 실행)"
echo "    c. 고른 항목의 publicKeys에만 필요한 키를 추가한다. 공통 그룹을 고치면 그 그룹을 쓰는 모든 항목이 함께 바뀐다."
echo "    d. 재암호화할 호스트에서, 넘길 identity로 각 항목을 복호화할 수 있는지 확인하고 재암호화 전 바이트 수를 적어 둔다 (원문은 버린다):"
echo "       test -f <name>.age && nix run github:ryantm/agenix -- -d <name>.age -i <identity> >/dev/null && nix run github:ryantm/agenix -- -d <name>.age -i <identity> | wc -c"
echo "       test -f <name>.age && sudo nix run github:ryantm/agenix -- -d <name>.age -i /etc/ssh/ssh_host_ed25519_key >/dev/null && sudo nix run github:ryantm/agenix -- -d <name>.age -i /etc/ssh/ssh_host_ed25519_key | wc -c  # 호스트 키"
echo "       바이트 수가 출력되지 않으면 파일이 없거나 복호화에 실패한 것이다 (-d는 파일이 없어도, 파이프 뒤 wc는 복호화가 실패해도 rc 0이다)."
echo "       빈 값 placeholder는 0일 수 있다."
echo "    e. 확인된 항목만 재암호화한다. EDITOR=:가 agenix까지 전달되지 않으면 비대화형 실행에서 표준입력이 값을 대체해 시크릿이 비워진다:"
echo "       EDITOR=: nix run github:ryantm/agenix -- -e <name>.age -i <identity>"
echo "       호스트 키(root)는 sudo가 앞에 둔 EDITOR를 넘기지 않으므로 sudo 뒤에 둔다:"
echo "       sudo EDITOR=: nix run github:ryantm/agenix -- -e <name>.age -i /etc/ssh/ssh_host_ed25519_key"
echo "       sudo chown \"\$USER\" <name>.age  # root 소유가 된 새 파일을 되돌린다"
echo "    f. 재암호화한 항목의 바이트 수가 재암호화 전과 같은지 본다 (다르면 git restore <name>.age로 되돌린다):"
echo "       test -f <name>.age && nix run github:ryantm/agenix -- -d <name>.age -i <identity> >/dev/null && nix run github:ryantm/agenix -- -d <name>.age -i <identity> | wc -c"
echo "       test -f <name>.age && sudo nix run github:ryantm/agenix -- -d <name>.age -i /etc/ssh/ssh_host_ed25519_key >/dev/null && sudo nix run github:ryantm/agenix -- -d <name>.age -i /etc/ssh/ssh_host_ed25519_key | wc -c  # 호스트 키"
echo "       바이트 수가 출력되지 않으면 복호화에 실패한 것이다 (값 비교 전에 멈춘다)."
echo "    g. 커밋·push 뒤 새 호스트에서 pull하고, 새 호스트의 identity로 복호화해 바이트 수가 d에서 적은 값과 같은지 본다:"
echo "       test -f <name>.age && nix run github:ryantm/agenix -- -d <name>.age -i ~/.ssh/id_ed25519 >/dev/null && nix run github:ryantm/agenix -- -d <name>.age -i ~/.ssh/id_ed25519 | wc -c"
echo "       test -f <name>.age && sudo nix run github:ryantm/agenix -- -d <name>.age -i /etc/ssh/ssh_host_ed25519_key >/dev/null && sudo nix run github:ryantm/agenix -- -d <name>.age -i /etc/ssh/ssh_host_ed25519_key | wc -c  # 호스트 키"
echo "       바이트 수가 출력되지 않으면 복호화에 실패한 것이다 (값 비교 전에 멈춘다)."
echo "       d~f는 기존 identity로만 복호화하므로 틀린 공개키를 등록해도 통과한다. 이 확인 전에는 recipient 갱신을 완료로 보지 않는다."
echo "       실패하면 새 호스트의 ssh-keygen -y -f ~/.ssh/id_ed25519 출력(호스트 키는 /etc/ssh/ssh_host_ed25519_key.pub)을"
echo "       libraries/constants.nix 값과 비교해 고친 뒤 d~g를 다시 한다."
echo "    전체 재암호화(-r)는 넘긴 identity로 secrets.nix의 모든 항목을 복호화할 수 있을 때만 쓴다."
echo "    복호화하지 못하는 항목에서 멈추고, 그 앞 항목만 재암호화된 채 남는다."
echo "    identity가 없는 항목은 그 identity가 있는 호스트에서 재암호화한다."
echo "    상세: .claude/skills/managing-secrets/references/workflows.md \"호스트 추가\""
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
