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

macOS MiniPC 경로는 interactive와 launcher child가 다름
- interactive Ghostty의 `ssh minipc`는 기존 1Password agent(mac-ssh)+preflight를 유지한다.
- personal Claude Remote Control/Codex launcher가 표시한 non-TTY child는 private dispatcher와
  dedicated `minipc-headless` key(`IdentityAgent none`)를 사용한다. 1Password GUI를 기다리지 않는다.
- launcher 경로는 인증 성립까지만 15초 deadline을 적용하고, 인증 뒤 장시간 command는 자르지 않는다.
- `HEADLESS_SSH_AUTH_TIMEOUT`이면 actual child의 `command -v ssh` → agenix
  `minipc-headless` materialization metadata → MiniPC authorized_keys entry → Tailscale 순서로 점검한다.
- `minipc-emergency`는 interactive 수동 복구 전용이다. headless key나 자동 fallback으로 재사용하지 않는다.

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
| `$HOME/.ssh/minipc-headless` | personal launcher 전용 agenix materialization; 내용 출력 금지 |
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

### `minipc-headless` rotate/revoke runbook

이 키는 일반 SSH·emergency key와 혼용하지 않는다. private material의 SSOT는
`secrets/minipc-headless.age`, recipient는 `constants.sshKeys.macbook`, personal Mac
materialization은 `~/.ssh/minipc-headless` mode 0400이다. key 본체를 출력하거나 평문 파일로
Git에 추가하지 않는다.

- `rotate`: credential/server mutation 직전에 action-time 확인을 받는다. 새 전용 key의
  restricted candidate 공개키를 기존 엔트리와 함께 MiniPC에 먼저 배포한다. private key는
  macbook recipient로 `.age`에 암호화하고 Mac에 배포한다. 1Password가 quit/locked인 actual
  launcher E2E가 통과한 뒤에만 구 공개키를 제거한다. 실패하면 구 key를 유지하고 candidate를
  제거한다.
- `즉시 revoke / Mac 분실`: 분실 Mac의 headless key에 의존하지 않는 승인된 관리 경로로
  MiniPC authorized_keys의 해당 restricted entry를 먼저 제거하고 배포한다. `from=` 제한만으로
  revoke됐다고 간주하지 않는다. 이어서 encrypted private key와 공개키 constant를 새 key로
  rotate하고 Mac materialization을 재배포하며, 구 private material과 임시 평문은 확인 후 폐기한다.
- `검증`: 값 대신 recipient/파일 type/owner/mode, restricted server entry, bounded
  actual-child exit/elapsed/prompt만 기록한다. `minipc-emergency`를 bootstrap이나 자동
  fallback으로 재사용하지 않는다.

## 핵심 절차

1. 먼저 runtime binding을 구분한다. interactive Ghostty는 1Password preflight, personal Claude/Codex non-TTY child는 `NIXOS_CONFIG_HEADLESS_SSH=1`+private dispatcher 경로다.
2. launcher 경로의 `HEADLESS_SSH_AUTH_TIMEOUT`은 1Password 잠금 문제가 아니다. actual child의 `command -v ssh`, agenix materialization의 존재/권한 metadata, 선언된 server entry, Tailscale 순으로 확인한다. key 본체는 읽거나 로그로 남기지 않는다.
3. `Load key ... invalid format`이면 키 파일 형식 문제로 분류한다. 파일 끝 개행, CRLF, 복사 손상을 확인한다.
4. 인증이 아니라 timeout/no route 계열이면 Tailscale 상태(`tailscale status`, `tailscale up`)를 확인한다.
5. NixOS 로컬 키 문제는 `home.nix`의 `services.ssh-agent`와 `programs.keychain`, `ssh-add -l`을 점검한다.
6. 서버 키 배포는 `libraries/constants.nix`의 `sshDeviceKeys`를 갱신한 뒤 `authorizedKeys` 선언을 재적용한다.

## 자주 발생하는 문제

1. interactive 1Password agent 미실행/잠금: `ssh minipc` preflight 안내에 따라 1Password 잠금 해제; launcher child에는 해당하지 않는다.
2. launcher `HEADLESS_SSH_AUTH_TIMEOUT`: child binary path, agenix materialization metadata, server entry, Tailscale을 점검하며 emergency key로 자동 fallback하지 않는다.
3. SSH 키 invalid format: 키 파일 끝 개행, CRLF, 복사 손상 확인
4. Tailscale 만료/미연결: `tailscale status`, `tailscale up`으로 확인
5. sudo 인증 실패: `sudo -E` 또는 SSH_AUTH_SOCK 유지

## 레퍼런스

- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
- Tailscale 설정: [references/tailscale.md](references/tailscale.md)
