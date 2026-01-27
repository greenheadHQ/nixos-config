# nixos-config

macOS와 NixOS 개발 환경을 nix-darwin/NixOS + Home Manager로 선언적 관리하는 프로젝트

## 핵심 명령어

| 명령어 | 설명 |
|--------|------|
| `nrs` | 설정 적용 (미리보기 + 적용) |
| `nrs --offline` | 오프라인 rebuild (캐시만 사용, 빠름) |
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
| `modules/darwin/` | macOS 전용 설정 |
| `modules/nixos/` | NixOS 전용 설정 |
| `modules/shared/` | 공유 설정 |

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
| agenix, age, secret, .age 파일, 재암호화 | `managing-secrets` |
| Cursor extensions, extensions.json | `managing-cursor` |
