---
name: managing-ssh
description: |
  Configure SSH, Tailscale VPN, mosh, sudo auth.
  Trigger: 'SSH 인증 실패', 'Tailscale', 'ssh-agent 문제', 'MagicDNS', 'mosh', 'authorized_keys 설정'.
  NOT for tmux (use managing-tmux). NOT for Atuin (use syncing-atuin).
---

# SSH 및 Tailscale 관리

SSH 키, ssh-agent, Tailscale VPN 관련 가이드입니다.

## 목적과 범위

SSH 인증, ssh-agent 로드, Tailscale 접속, sudo 환경변수 이슈를 통합적으로 다룬다.

## Known Issues

sudo에서 SSH_AUTH_SOCK 유실
- `sudo` 실행 시 환경변수가 초기화되어 SSH 키 인증 실패
- 해결: `sudo -E` 또는 sudoers에서 `SSH_AUTH_SOCK` 유지 설정

macOS에서 `ssh minipc` preflight 차단 (1Password agent)
- Phase 2a 후 macOS SSH는 1Password agent(mac-ssh)로 인증 — 로컬 id_ed25519는 archive됨
- 1Password 데스크탑 미실행/잠금 시 `ssh()` preflight가 안내·자동 기동·최대 15초 대기
- 해결: 1Password 잠금 해제. 즉시 접속은 `ssh minipc-emergency` (passphrase). 상세: references/troubleshooting.md

NixOS에서 SSH 키 자동 로드 실패
- NixOS는 launchd가 아니라 `services.ssh-agent` + `programs.keychain`으로 키 로드
- 수동 로드: `ssh-add $HOME/.ssh/id_ed25519`

## 빠른 참조

### SSH 키 상태 확인

```bash
# 로드된 키 확인
ssh-add -l

# 키 로드
ssh-add $HOME/.ssh/id_ed25519

# 키 언로드
ssh-add -d $HOME/.ssh/id_ed25519
```

### Tailscale 상태

```bash
# 연결 상태 확인
tailscale status

# 재인증 (만료 시)
tailscale up

# IP 확인
tailscale ip -4
```

### SSH 설정 파일

| 파일 | 용도 |
|------|------|
| `$HOME/.ssh/config` | SSH 호스트 설정 |
| `$HOME/.ssh/mac-ssh.pub` | macOS `minipc` IdentityFile 고정용 공개키 (`constants.sshDeviceKeys.macSsh`에서 생성) |
| `$HOME/.ssh/emergency_ed25519` | 1Password 장애 시 `minipc-emergency` fallback 개인 키 |
| `$HOME/.ssh/id_ed25519` | NixOS/GitHub 로컬 개인 키 |
| `$HOME/.ssh/authorized_keys` | 인증된 키 (서버) |
| `modules/darwin/programs/ssh/default.nix` | macOS 1Password SSH agent/host 설정 |
| `modules/nixos/programs/ssh-client/default.nix` | NixOS SSH 클라이언트 설정 |
| `modules/nixos/programs/tailscale.nix` | NixOS Tailscale VPN + 방화벽 설정 |
| `modules/nixos/programs/mosh.nix` | NixOS mosh 설정 (Tailscale 전용, LAN 비노출) |
| `modules/nixos/home.nix` | NixOS `services.ssh-agent`/`programs.keychain` 설정 |
| `libraries/constants.nix` | SSH 공개키, 1Password agent socket, Tailscale IP 단일 소스 |

### authorizedKeys 추가 (NixOS)

```nix
# hosts/<hostname>/default.nix
users.users.${username}.openssh.authorizedKeys.keys = with constants.sshDeviceKeys; [
  macSsh
  mobile
  emergency
];
```

공개키 문자열은 직접 하드코딩하지 말고 `libraries/constants.nix`의 `sshDeviceKeys`를 참조한다. 실제 MiniPC 구성은 `hosts/greenhead-minipc/default.nix` 기준.

## 핵심 절차

1. macOS `ssh minipc` 인증 실패는 먼저 1Password 데스크탑/agent 상태를 본다. `modules/darwin/programs/ssh/default.nix`의 `IdentityAgent`, `agent.toml`, `onepassword-autostart`와 `modules/shared/programs/shell/darwin.nix`의 `ssh()` preflight가 현행 경로다.
2. `Load key ... invalid format`이면 키 파일 형식 문제로 분류한다. 파일 끝 개행, CRLF, 복사 손상을 확인한다.
3. 인증이 아니라 timeout/no route 계열이면 Tailscale 상태(`tailscale status`, `tailscale up`)를 확인한다.
4. NixOS 로컬 키 문제는 `home.nix`의 `services.ssh-agent`와 `programs.keychain`, `ssh-add -l`을 점검한다.
5. 서버 키 배포는 `libraries/constants.nix`의 `sshDeviceKeys`를 갱신한 뒤 `authorizedKeys` 선언을 재적용한다.

## 자주 발생하는 문제

1. 1Password agent 미실행/잠금: `ssh minipc` preflight 안내에 따라 1Password 잠금 해제, 긴급 시 `ssh minipc-emergency`
2. SSH 키 invalid format: 키 파일 끝 개행, CRLF, 복사 손상 확인
3. Tailscale 만료/미연결: `tailscale status`, `tailscale up`으로 확인
4. sudo 인증 실패: `sudo -E` 또는 SSH_AUTH_SOCK 유지

## 레퍼런스

- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
- Tailscale 설정: [references/tailscale.md](references/tailscale.md)
