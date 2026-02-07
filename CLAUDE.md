# nixos-config

macOS와 NixOS 개발 환경을 nix-darwin/NixOS + Home Manager로 선언적 관리하는 프로젝트

## 핵심 명령어

| 명령어 | 설명 |
|--------|------|
| `nrs` | 설정 적용 (미리보기 + 적용) |
| `ssh minipc` | MiniPC SSH 접속 (Tailscale VPN) |
| `ssh mac` | macOS SSH 접속 (Tailscale VPN) |

## 빌드 시 주의사항

`nrs` alias를 사용하세요. `darwin-rebuild`/`nixos-rebuild`를 직접 실행하지 마세요.

`nrs`가 자동으로 처리하는 것들:
- launchd agent 정리 (setupLaunchAgents 멈춤 방지, macOS)
- Hammerspoon 재시작 (macOS)

## 주요 디렉토리

| 경로 | 설명 |
|------|------|
| `libraries/constants.nix` | 전역 상수 (IP, 경로, SSH 키, UID 등) - 단일 소스 |
| `libraries/packages.nix` | 공통 패키지 (shared/darwinOnly/nixosOnly) |
| `modules/darwin/` | macOS 전용 설정 |
| `modules/nixos/` | NixOS 전용 설정 |
| `modules/nixos/options/homeserver.nix` | 홈서버 mkOption 정의 (immich, uptime-kuma, plex, anki-sync) |
| `modules/shared/` | 공유 설정 |
| `scripts/` | 자동화 스크립트 (add-host, pre-rebuild-check, update-input) |

## 상수 참조

하드코딩된 IP, 경로, SSH 키, UID 등을 추가/변경할 때는 반드시 `libraries/constants.nix`를 수정하세요.

- `constants.network.minipcTailscaleIP` - MiniPC IP
- `constants.paths.dockerData` / `mediaData` - 데이터 경로
- `constants.sshKeys.macbook` / `minipc` - SSH 공개키
- `constants.containers.*` - 컨테이너 리소스 제한
- `constants.ids.*` - UID/GID (postgres, user, render 등)

상수는 `flake.nix`에서 `specialArgs`/`extraSpecialArgs`로 모든 모듈에 전달됩니다.

## 홈서버 서비스

NixOS 홈서버 서비스는 `homeserver.*` 옵션으로 활성화합니다:

```nix
# modules/nixos/configuration.nix
homeserver.immich.enable = true;
homeserver.uptimeKuma.enable = true;
homeserver.plex.enable = false;
homeserver.ankiSync.enable = true;
```

## 스킬 라우팅

| 상황 | 스킬 |
|------|------|
| 플랫폼별 | |
| NixOS, MiniPC(미니PC), nixos-rebuild, disko | `managing-minipc` |
| nix-darwin, macOS settings, Homebrew | `managing-macos` |
| flake, nix-command, slow build, experimental features | `understanding-nix` |
| 도구별 | |
| Atuin sync, shell history, `atuin status` | `syncing-atuin` |
| Claude Code hooks, plugins | `configuring-claude-code` |
| Hammerspoon hotkeys, launchd stuck, Ghostty | `automating-hammerspoon` |
| Podman/Docker, immich, container OOM, homeserver.*, immich update | `running-containers` |
| Anki sync server, anki 동기화, anki 서버, anki 백업 | `hosting-anki` |
| immich 사진 경로, immich 파일 보여줘, 이미치 사진 | `viewing-immich-photo` |
| Git config, delta, rerere, lazygit, gitconfig conflicts | `configuring-git` |
| mise, runtime versions, .nvmrc | `managing-mise` |
| tmux config, keybindings, pane notepad, tmux-resurrect | `managing-tmux` |
| SSH keys, Tailscale VPN, sudo auth failure | `managing-ssh` |
| agenix, age, secret, .age 파일, 재암호화 | `managing-secrets` |
| Neovim, LazyVim, LSP, nvim 플러그인, lazy.nvim, 한글 입력, im-select | `configuring-neovim` |
| Cursor extensions, extensions.json | `managing-cursor` |
| Pushover, 텍스트 공유, MiniPC→iPhone, push 함수 | `sharing-text` |
