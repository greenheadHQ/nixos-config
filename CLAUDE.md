# nixos-config

macOS와 NixOS 개발 환경을 nix-darwin/NixOS + Home Manager로 선언적 관리하는 프로젝트

## 실행 환경 인식

이 프로젝트는 macOS(Mac)와 NixOS(MiniPC) 두 머신에서 사용됩니다.
Environment 섹션의 `Platform` 값으로 현재 실행 환경을 판별하세요:

| Platform | 현재 환경 | MiniPC 작업 | Mac 작업 |
|----------|----------|------------|---------|
| `linux` | **MiniPC** (NixOS) | 로컬 명령어 직접 실행 | `ssh mac` |
| `darwin` | **Mac** (macOS) | `ssh minipc` | 로컬 명령어 직접 실행 |

**금지**: 현재 환경의 머신에 SSH 접속 금지.
`Platform: linux`이면 이미 MiniPC — `ssh minipc` 절대 실행하지 말 것.
`Platform: darwin`이면 이미 Mac — `ssh mac` 절대 실행하지 말 것.

> 현재 NixOS 호스트는 MiniPC 1대뿐이므로 `Platform: linux` = MiniPC로 판별합니다.
> 호스트가 추가되면 `hostname` 명령으로 구분하세요.

## 핵심 명령어

| 명령어 | 설명 |
|--------|------|
| `nrs` | 설정 적용 (미리보기 + 적용) |
| `ssh minipc` | MiniPC SSH 접속 — **Mac에서만** (Platform: darwin) |
| `ssh mac` | macOS SSH 접속 — **MiniPC에서만** (Platform: linux) |

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
| `modules/nixos/options/homeserver.nix` | 홈서버 mkOption 정의 (immich, immichBackup, uptime-kuma, anki-sync, copyparty, vaultwarden) |
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
homeserver.ankiSync.enable = true;
homeserver.copyparty.enable = true;
homeserver.vaultwarden.enable = true;
homeserver.immichBackup.enable = true;
```

## 스킬 라우팅

| 상황 | 스킬 |
|------|------|
| 플랫폼별 | |
| NixOS, MiniPC(미니PC), nixos-rebuild, disko, rollback, 설정 배치, 하드웨어 설정, WoL, smartd, lm-sensors | `managing-minipc` |
| nix-darwin, macOS settings, Homebrew Cask, darwin-rebuild | `managing-macos` |
| flake, derivation, substituter, slow build, direnv, devShell | `understanding-nix` |
| 도구별 | |
| Atuin sync, shell history, `atuin status`, encryption key | `syncing-atuin` |
| Claude Code hooks, plugins, MCP, settings.json | `configuring-claude-code` |
| Hammerspoon hotkeys, launchd agents, Ghostty terminal | `automating-hammerspoon` |
| Podman/Docker, immich, container OOM, service-lib, 서비스 업데이트, immich-db-backup | `running-containers` |
| Anki sync server, anki 동기화, anki 서버, anki 백업 | `hosting-anki` |
| Copyparty, 파일 서버, WebDAV, Google Drive 대체, 파일 공유 | `hosting-copyparty` |
| Vaultwarden, Bitwarden, 비밀번호 관리자, 볼트워든, admin token | `hosting-vaultwarden` |
| immich 사진 경로, immich 파일 보여줘, 이미치 사진 | `viewing-immich-photo` |
| Git config, delta, rerere, lazygit, gitconfig conflicts | `configuring-git` |
| mise, Node.js, pnpm, shims, .nvmrc | `managing-mise` |
| tmux config, keybindings, prefix, resurrect, pane notepad | `managing-tmux` |
| SSH keys, ssh-agent, Tailscale VPN, mosh, sudo auth | `managing-ssh` |
| agenix, .age encryption, secrets.nix, re-encrypt, age key | `managing-secrets` |
| Neovim, LazyVim, LSP, nvim 플러그인, lazy.nvim, im-select | `configuring-neovim` |
| Cursor IDE, Nix extensions.json, duti, 확장 0개 표시 | `managing-cursor` |
| Pushover, 텍스트 공유, MiniPC→iPhone, share text | `sharing-text` |
| Codex sync, codex harness, codex 동기화, codex 투영 | `syncing-codex-harness` |
