# green/nixos-config

macOS와 NixOS 개발 환경을 **nix-darwin/NixOS + Home Manager**로 선언적으로 관리하는 프로젝트입니다.

## 플랫폼 구성

| 호스트 | OS | 용도 | 접속 방법 |
|--------|-----|------|----------|
| MacBook Pro | macOS (nix-darwin) | 메인 개발 환경 | 로컬 |
| greenhead-minipc | NixOS | 24시간 원격 개발 서버 | `ssh minipc` |

**공유 설정** (`modules/shared/`):
- 쉘 환경 (zsh, starship, atuin, fzf, zoxide)
- 개발 도구 (git, tmux, neovim (LazyVim), lazygit)
- Claude Code 설정

**플랫폼별 설정**:
- macOS: Homebrew GUI 앱, Hammerspoon, Cursor, 폴더 액션
- NixOS: SSH 서버, mosh, Tailscale VPN

---

## 아키텍처

```
flake.nix                          # 진입점: mkDarwinConfig / mkNixosConfig
├── libraries/
│   ├── constants.nix              # 전역 상수 (IP, 경로, SSH 키, UID 등)
│   ├── packages.nix               # 공통 패키지 (shared/darwinOnly/nixosOnly)
│   └── nixpkgs/default.nix        # overlay 설정
├── modules/
│   ├── shared/                    # Darwin + NixOS 공통
│   │   ├── configuration.nix      # Nix GC, substitution
│   │   └── programs/              # git, tmux, neovim, shell, claude, secrets
│   ├── darwin/                    # macOS 전용
│   │   ├── configuration.nix      # Dock, Finder, 키보드
│   │   ├── home.nix               # HM 패키지 + 모듈 import
│   │   └── programs/              # hammerspoon, cursor, sshd, ssh
│   └── nixos/                     # NixOS 전용
│       ├── configuration.nix      # systemd-boot, 로케일, 서비스 활성화
│       ├── home.nix               # HM 패키지 + 모듈 import
│       ├── options/
│       │   └── homeserver.nix     # mkOption 서비스 정의 (immich, uptime-kuma, anki-sync)
│       ├── lib/
│       │   ├── tailscale-wait.nix # Tailscale IP 대기 유틸리티
│       │   ├── mk-update-module.nix # 서비스 업데이트 모듈 생성 헬퍼
│       │   └── service-lib.sh     # 공통 셸 라이브러리
│       └── programs/
│           ├── anki-sync-server/  # Anki sync 서버 (NixOS 네이티브 모듈)
│           ├── docker/            # 컨테이너 서비스 (runtime, immich, uptime-kuma)
│           ├── ssh.nix            # OpenSSH 서버
│           └── tailscale.nix      # VPN
├── hosts/greenhead-minipc/        # 호스트별 하드웨어 설정
├── secrets/                       # agenix 암호화 시크릿
└── scripts/                       # 자동화 스크립트
    ├── add-host.sh                # 호스트 추가 마법사
    ├── pre-rebuild-check.sh       # 빌드 전 검증
    └── update-input.sh            # Flake input 업데이트
```

### 상수 관리

모든 공유 상수는 `libraries/constants.nix`에서 단일 소스로 관리됩니다:
- 네트워크: Tailscale IP, 서비스 포트
- 경로: Docker 데이터, 미디어 데이터
- SSH 공개키: `secrets/secrets.nix`에서도 import
- 컨테이너 리소스 제한
- UID/GID, macOS 설정, SSH 타임아웃

### 홈서버 서비스 (mkOption)

NixOS 홈서버 서비스는 `homeserver.*` 옵션으로 선언적 활성화:

```nix
# modules/nixos/configuration.nix
homeserver.immich.enable = true;
homeserver.uptimeKuma.enable = true;
homeserver.ankiSync.enable = true;
```

---

## Getting Started

### 새 Mac 설정

```bash
# 1. Nix 설치
curl -L https://nixos.org/nix/install | sh
# 설치 후 터미널 재시작

# 2. 저장소 클론
mkdir -p ~/Workspace && cd ~/Workspace
git clone https://github.com/shren207/nixos-config.git
cd nixos-config

# 3. SSH 키 복원 (~/.ssh/id_ed25519)
# 상세: .claude/skills/managing-ssh/ 참고

# 4. flake.nix에서 username/hostname 수정
# username: whoami 출력값
# hostname: scutil --get LocalHostName 출력값

# 5. nix-darwin 부트스트랩
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
sudo mv /etc/bashrc /etc/bashrc.before-nix-darwin
sudo mv /etc/zshrc /etc/zshrc.before-nix-darwin
ssh-add ~/.ssh/id_ed25519
sudo --preserve-env=SSH_AUTH_SOCK nix run nix-darwin -- switch --flake .

# 6. 이후 설정 적용
nrs
```

### 새 호스트 추가

```bash
bash scripts/add-host.sh
```

마법사가 안내하는 대로 `flake.nix`, `constants.nix` 수정 후 시크릿 재암호화를 수행합니다.

### MiniPC 접속

```bash
ssh minipc              # Tailscale VPN 연결 시
ssh greenhead@100.79.80.95  # 직접 IP
```

설치/복구 가이드: `.claude/skills/managing-minipc/` 참고

---

## 문서

상세 문서는 `.claude/skills/` 폴더에서 관리됩니다.
Claude Code 세션에서 질문하면 관련 스킬이 자동으로 로드됩니다.

| 주제 | 스킬 |
|------|------|
| macOS 설정 | `managing-macos` |
| NixOS/MiniPC | `managing-minipc` |
| Nix/flake | `understanding-nix` |
| SSH/Tailscale | `managing-ssh` |
| 시크릿 관리 | `managing-secrets` |
| 컨테이너 서비스 | `running-containers` |

전체 스킬 목록은 `CLAUDE.md`를 참고하세요.

> pre-commit `ai-skills-consistency` 훅이 `.claude/skills`, `.agents/skills`, `modules/shared/programs/codex` 관련 staged 변경에서 구조 불일치를 감지하면 커밋을 차단합니다.
> 불일치 해결 후 `nrs`와 `./scripts/ai/verify-ai-compat.sh`로 재검증하세요.
> 긴급 우회: `SKIP_AI_SKILL_CHECK=1 git commit ...`
