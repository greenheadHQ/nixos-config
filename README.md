# green/nixos-config

macOS와 NixOS 개발 환경을 **nix-darwin/NixOS + Home Manager**로 선언적으로 관리하는 프로젝트입니다.

## 플랫폼 구성

| 호스트 | OS | 용도 | 접속 방법 |
|--------|-----|------|----------|
| MacBook Pro | macOS (nix-darwin) | 메인 개발 환경 | 로컬 |
| greenhead-minipc | NixOS | 홈서버 + 원격 개발 서버 | `ssh minipc` |

**공유 설정** (`modules/shared/`):
- 쉘 환경 (zsh, starship, atuin, fzf, zoxide)
- 개발 도구 (git, tmux, neovim (LazyVim), lazygit, direnv)
- AI 도구 (Claude Code, Codex CLI, agent-browser)
- 시크릿 관리 (agenix)

**플랫폼별 설정**:
- macOS: Homebrew GUI 앱, Hammerspoon, Cursor, Ghostty, Shottr, 폴더 액션
- NixOS: 홈서버 14개 서비스, Tailscale VPN, SSH/mosh, 하드웨어 모니터링

---

## 아키텍처

```
flake.nix                          # 진입점: mkDarwinConfig / mkNixosConfig
├── libraries/
│   ├── constants.nix              # 전역 상수 (IP, 포트, 경로, SSH 키, UID 등)
│   ├── packages.nix               # 공통 패키지 (shared/darwinOnly/nixosOnly)
│   ├── nixpkgs/default.nix        # overlay 설정
│   └── packages/
│       └── sarasa-mono-k-nerd-font.nix  # 커스텀 폰트 패키지
├── modules/
│   ├── shared/                    # Darwin + NixOS 공통
│   │   ├── configuration.nix      # Nix GC, 병렬 다운로드, flakes
│   │   └── programs/              # git, tmux, neovim, shell, claude, codex,
│   │                              # lazygit, direnv, broot, agent-browser, secrets
│   ├── darwin/                    # macOS 전용
│   │   ├── configuration.nix      # Dock, Finder, 키보드, 단축키, Touch ID sudo
│   │   ├── home.nix               # HM 패키지 + 모듈 import
│   │   └── programs/              # hammerspoon, cursor, ghostty, shottr,
│   │                              # folder-actions, keybindings, atuin, sshd, ssh, mosh
│   └── nixos/                     # NixOS 전용
│       ├── configuration.nix      # systemd-boot, watchdog, nix-ld, 서비스 활성화
│       ├── home.nix               # HM 패키지 + 모듈 import
│       ├── options/
│       │   └── homeserver.nix     # mkOption 서비스 정의 (14개)
│       ├── lib/
│       │   ├── service-lib.nix    # 공통 셸 라이브러리 (Nix store 배치)
│       │   ├── mk-update-module.nix # 서비스 업데이트 모듈 생성 헬퍼
│       │   ├── caddy-security-headers.nix
│       │   └── tailscale-wait.nix # Tailscale IP 대기 유틸리티
│       └── programs/
│           ├── docker/            # 컨테이너 서비스 (Podman 기반)
│           │   ├── runtime.nix    # Podman 공통 설정
│           │   ├── immich.nix     # 사진 백업 (PostgreSQL + Redis + ML)
│           │   ├── immich-backup.nix
│           │   ├── uptime-kuma.nix
│           │   ├── copyparty.nix  # 파일 서버 (Google Drive 대체)
│           │   ├── vaultwarden.nix # 비밀번호 관리자
│           │   ├── vaultwarden-backup.nix
│           │   ├── archivebox.nix # 웹 아카이버
│           │   ├── archivebox-backup.nix
│           │   └── archivebox-notify.nix
│           ├── anki-sync-server/  # Anki 동기화 서버 (네이티브 모듈)
│           ├── caddy.nix          # HTTPS 리버스 프록시 (Cloudflare DNS)
│           ├── dev-proxy/         # dev.greenhead.dev 개발 서버 프록시
│           ├── immich-cleanup/    # 임시 앨범 자동 삭제
│           ├── immich-update/     # 버전 체크 + Pushover 알림
│           ├── uptime-kuma-update/
│           ├── copyparty-update/
│           ├── archivebox-update/
│           ├── temp-monitor/      # CPU/NVMe 온도 모니터링 (Pushover)
│           ├── smartd.nix         # S.M.A.R.T. 디스크 건강 모니터링
│           ├── tailscale.nix      # VPN
│           ├── ssh.nix            # OpenSSH 서버
│           ├── mosh.nix           # 모바일 쉘
│           └── ssh-client/        # macOS SSH 접속 설정
├── hosts/greenhead-minipc/        # 호스트별 하드웨어 설정 (disko, WoL, HDD)
├── secrets/                       # agenix 암호화 시크릿 (16개 .age 파일)
├── scripts/                       # 자동화 스크립트
│   ├── add-host.sh                # 호스트 추가 마법사
│   ├── pre-rebuild-check.sh       # 빌드 전 검증
│   └── update-input.sh            # Flake input 업데이트
└── tests/
    └── eval-tests.nix             # Nix 평가 테스트
```

### 상수 관리

모든 공유 상수는 `libraries/constants.nix`에서 단일 소스로 관리됩니다:

| 카테고리 | 내용 |
|----------|------|
| `network` | Tailscale IP, 서비스 포트 7개, Podman 서브넷 |
| `domain` | `greenhead.dev` + 서브도메인 6개 |
| `paths` | Docker 데이터(SSD), 미디어 데이터(HDD) |
| `sshKeys` | MacBook/MiniPC SSH 공개키 (`secrets/secrets.nix`에서도 import) |
| `containers` | 서비스별 리소스 제한 (메모리, CPU) |
| `ids` | UID/GID (postgres, user, render) |
| `macos` | Dock, 키보드, Shottr 경로 |
| `ssh` | 타임아웃 설정 (Darwin sshd + NixOS openssh 공통) |
| `tempMonitor` | CPU/NVMe 온도 경고/긴급 임계값 |

### 홈서버 서비스

NixOS 홈서버 서비스는 `homeserver.*` 옵션으로 선언적 활성화:

```nix
# modules/nixos/configuration.nix
homeserver.immich.enable = true;           # 사진 백업
homeserver.immichBackup.enable = true;     # PostgreSQL 매일 백업 (HDD)
homeserver.immichCleanup.enable = true;    # 임시 앨범 자동 삭제
homeserver.immichUpdate.enable = true;     # 버전 체크 + Pushover 알림
homeserver.uptimeKuma.enable = true;       # 서비스 모니터링
homeserver.uptimeKumaUpdate.enable = true;
homeserver.ankiSync.enable = true;         # Anki 동기화 서버
homeserver.copyparty.enable = true;        # 파일 서버 (Google Drive 대체)
homeserver.copypartyUpdate.enable = true;
homeserver.vaultwarden.enable = true;      # 비밀번호 관리자
homeserver.archiveBox.enable = true;       # 웹 아카이버 (SingleFile)
homeserver.archiveBoxBackup.enable = true; # SQLite 매일 백업 (HDD)
homeserver.archiveBoxNotify.enable = true; # 런타임 이벤트 알림
homeserver.archiveBoxUpdate.enable = true;
homeserver.reverseProxy.enable = true;     # Caddy HTTPS (*.greenhead.dev)
homeserver.devProxy.enable = true;         # dev.greenhead.dev
```

### 개발 도구 체인

| 도구 | 용도 |
|------|------|
| lefthook | Git 훅 관리 (pre-commit, pre-push) |
| nixfmt | Nix 코드 포매팅 |
| shellcheck | 셸 스크립트 린팅 |
| gitleaks | 시크릿 유출 방지 |
| eval-tests | Nix 평가 테스트 (`tests/eval-tests.nix`) |

pre-push 시 `nix flake check --no-build --all-systems` 자동 실행.

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
| Vaultwarden | `hosting-vaultwarden` |
| ArchiveBox | `hosting-archivebox` |
| Copyparty | `hosting-copyparty` |
| Anki 동기화 | `hosting-anki` |
| dev-proxy | `proxying-dev-server` |
| Claude Code | `configuring-claude-code` |

전체 스킬 목록은 `CLAUDE.md`를 참고하세요.

> pre-commit `ai-skills-consistency` 훅이 `.claude/skills`, `.agents/skills`, `modules/shared/programs/codex` 관련 staged 변경에서 구조 불일치를 감지하면 커밋을 차단합니다.
> 불일치 해결 후 `nrs`와 `./scripts/ai/verify-ai-compat.sh`로 재검증하세요.
> 긴급 우회: `SKIP_AI_SKILL_CHECK=1 git commit ...`
