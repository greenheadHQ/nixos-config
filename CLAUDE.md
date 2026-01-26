# nixos-config

macOS와 NixOS 개발 환경을 nix-darwin/NixOS + Home Manager로 선언적 관리하는 프로젝트

## Private 저장소 연동

이 프로젝트는 `nixos-config-secret` 저장소와 연동됩니다:

| 저장소 | 용도 |
|--------|------|
| `nixos-config` | 공개 설정 (CLI 도구, 시스템 설정, agenix 암호화 secrets) |
| `nixos-config-secret` | Private 설정 |

연동 방식:
- `flake.nix`에서 `nixos-config-secret`을 input으로 참조
- `lib.mkAfter`로 secret 설정을 공개 설정에 병합
- Nix 빌드 시 SSH 키가 필요 (Private 저장소 접근)

## 세션 시작 전 알아야 할 것

빌드 시 항상 `nrs` alias를 사용하세요. `darwin-rebuild`/`nixos-rebuild`를 직접 실행하지 마세요.

`nrs`가 자동으로 처리하는 것들:
- SSH 키 로드 (Private 저장소 접근)
- launchd agent 정리 (setupLaunchAgents 멈춤 방지)
- nixos-config-secret 변경 감지 및 경고
- Hammerspoon 재시작 (macOS)
- sudo SSH_AUTH_SOCK 전달 (NixOS)

## 디렉토리 구조

| 경로 | 설명 |
|------|------|
| `flake.nix` | Nix flake 진입점 |
| `secrets/` | agenix 암호화 secrets (pushover credentials, pane-note links 등) |
| `modules/shared/` | 공유 설정 (CLI 도구, git, tmux, claude) |
| `modules/shared/scripts/` | 공용 스크립트 (git-cleanup, validate-skills) |
| `modules/darwin/` | macOS 전용 (Homebrew, Hammerspoon, Cursor) |
| `modules/darwin/scripts/` | macOS 빌드 스크립트 (nrs, nrp, nrh) |
| `modules/nixos/` | NixOS 전용 (SSH, Tailscale, fail2ban, Docker) |
| `modules/nixos/scripts/` | NixOS 빌드 스크립트 (nrs, nrp, install-minipc) |
| `hosts/` | 호스트별 설정 (greenhead-minipc 등) |

## 주요 명령어

| 명령어 | 플랫폼 | 설명 |
|--------|--------|------|
| `nrs` | macOS/NixOS | 설정 적용 (미리보기 + 적용) |
| `nrs --update` | macOS/NixOS | nixos-config-secret flake input 업데이트 후 rebuild |

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
| Podman/Docker, immich, container OOM | `running-containers` |
| Git config, delta, rerere, gitconfig conflicts | `configuring-git` |
| mise, runtime versions, .nvmrc | `managing-mise` |
| tmux config, keybindings, pane notepad, tmux-resurrect | `managing-tmux` |
| SSH keys, Tailscale VPN, sudo auth failure | `managing-ssh` |
| Cursor extensions, extensions.json | `managing-cursor` |
