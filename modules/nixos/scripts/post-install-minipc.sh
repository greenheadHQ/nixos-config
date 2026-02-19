#!/usr/bin/env bash
# MiniPC Phase 2.5 + 3: 설치 후 설정 스크립트
# NixOS 재부팅 후 greenhead 사용자로 실행

set -euo pipefail

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
echo_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
echo_error() { echo -e "${RED}[ERROR]${NC} $1"; }
echo_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

echo_info "=== MiniPC 설치 후 설정 ==="
echo ""

# Phase 2.5: hardware-configuration.nix 교체
echo_step "Phase 2.5: hardware-configuration.nix 교체"
echo ""

# 1. 현재 hardware-configuration.nix 확인
echo_info "현재 hardware-configuration.nix:"
cat /etc/nixos/hardware-configuration.nix
echo ""

# 2. SSH 키 생성 (GitHub 접근용)
if [[ ! -f ~/.ssh/id_ed25519 ]]; then
    echo_info "SSH 키 생성 중..."
    ssh-keygen -t ed25519 -C "greenhead@minipc" -N "" -f ~/.ssh/id_ed25519
    echo ""
    echo_warn "다음 공개키를 GitHub에 등록하세요:"
    echo ""
    cat ~/.ssh/id_ed25519.pub
    echo ""
    echo_info "GitHub → Settings → SSH and GPG keys → New SSH key"
    echo ""
    read -p "GitHub에 SSH 키를 등록했으면 Enter를 누르세요..."
fi

# 3. nixos-config 클론
if [[ ! -d ~/nixos-config ]]; then
    echo_info "nixos-config 클론 중..."
    git clone git@github.com:greenheadHQ/nixos-config.git ~/nixos-config
fi

cd ~/nixos-config

# 4. git 설정
git config user.email "shren0812@gmail.com"
git config user.name "greenhead"

# 5. hardware-configuration.nix 복사
echo_info "hardware-configuration.nix 복사 중..."
cp /etc/nixos/hardware-configuration.nix hosts/greenhead-minipc/

# 6. 커밋 및 푸시
echo_info "변경사항 커밋 중..."
git add hosts/greenhead-minipc/hardware-configuration.nix
git commit -m "feat(minipc): add actual hardware-configuration.nix"
git push

echo_info "Phase 2.5 완료!"
echo ""

# Phase 3: 초기 설정
echo_step "Phase 3: 초기 설정"
echo ""

# 3.1 Tailscale 인증
echo_info "3.1 Tailscale 인증"
if ! tailscale status &> /dev/null; then
    echo_warn "Tailscale 인증이 필요합니다."
    echo_info "다음 명령을 실행하고 표시되는 URL로 인증하세요:"
    echo ""
    echo "  sudo tailscale up"
    echo ""
    read -p "Tailscale 인증을 완료했으면 Enter를 누르세요..."
fi

echo_info "Tailscale 상태:"
tailscale status
TAILSCALE_IP=$(tailscale ip -4)
echo_info "Tailscale IP: $TAILSCALE_IP"
echo ""

# 3.2 rebuild 적용
echo_info "nixos-rebuild 적용 중..."
sudo nixos-rebuild switch --flake .#greenhead-minipc

echo ""
echo_info "=== 모든 설정 완료! ==="
echo ""
echo_warn "Mac에서 다음 작업을 수행하세요:"
echo ""
echo "1. SSH 설정 (~/.ssh/config에 추가):"
echo ""
cat << EOF
Host minipc
    HostName $TAILSCALE_IP
    User greenhead
    IdentityFile ~/.ssh/id_ed25519
EOF
echo ""
echo "2. Atuin key 복사:"
echo "   scp ~/.local/share/atuin/key minipc:~/.local/share/atuin/"
echo ""
echo "3. 접속 테스트:"
echo "   ssh minipc"
echo ""

# 3.3 검증
echo_step "검증 체크리스트"
echo ""
echo_info "시스템 정보:"
uname -a
echo ""
echo_info "NixOS 버전:"
nixos-version
echo ""

if [[ -d /mnt/data ]]; then
    echo_info "HDD 데이터 (/mnt/data):"
    ls -la /mnt/data 2>/dev/null || echo "  (마운트 필요)"
fi
echo ""

echo_info "개발 도구 확인:"
command -v claude && claude --version || echo "  claude: 설치 확인 필요"
command -v tmux && tmux -V || echo "  tmux: 설치 확인 필요"
command -v atuin && atuin status || echo "  atuin: 설치 확인 필요"
echo ""

echo_info "설정 완료!"
