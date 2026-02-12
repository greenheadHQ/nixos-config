---
name: managing-ssh
description: |
  SSH keys, ssh-agent, Tailscale VPN, mosh, sudo auth issues.
  Triggers: "SSH key invalid format", authentication failures,
  Tailscale VPN issues, "sudo SSH_AUTH_SOCK", authorized keys, mosh setup.
---

# SSH 및 Tailscale 관리

SSH 키, ssh-agent, Tailscale VPN 관련 가이드입니다.

## Known Issues

**sudo에서 SSH_AUTH_SOCK 유실**
- `sudo` 실행 시 환경변수가 초기화되어 SSH 키 인증 실패
- 해결: `sudo -E` 또는 sudoers에서 `SSH_AUTH_SOCK` 유지 설정

**재부팅 후 SSH 키 미로드**
- launchd agent로 자동 로드 설정되어 있지만 실패할 수 있음
- 수동 로드: `ssh-add ~/.ssh/id_ed25519`

## 빠른 참조

### SSH 키 상태 확인

```bash
# 로드된 키 확인
ssh-add -l

# 키 로드
ssh-add ~/.ssh/id_ed25519

# 키 언로드
ssh-add -d ~/.ssh/id_ed25519
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
| `~/.ssh/config` | SSH 호스트 설정 |
| `~/.ssh/id_ed25519` | 개인 키 |
| `~/.ssh/id_ed25519.pub` | 공개 키 |
| `~/.ssh/authorized_keys` | 인증된 키 (서버) |

### authorizedKeys 추가 (NixOS)

```nix
# hosts/<hostname>/default.nix
users.users.<username>.openssh.authorizedKeys.keys = [
  "ssh-ed25519 AAAA... user@host"
];
```

## SSH 접속 시 tmux 자동 연결

NixOS 서버(MiniPC)에 SSH 접속하면 자동으로 tmux `main` 세션에 연결됩니다.

- **설정 파일**: `modules/shared/programs/shell/nixos.nix`의 `programs.zsh.initContent`
- **조건**: SSH 세션 + 대화형 + tmux 외부 + mosh 외부
- 기존 세션이 있으면 세션 목록을 출력한 후 attach
- 없으면 `main` 세션을 새로 생성
- `ssh minipc 'command'` 같은 비대화형 명령은 영향 없음
- mosh 세션은 자체 재연결이 있으므로 제외

## 자주 발생하는 문제

1. **SSH 키 invalid format**: 키 파일 끝에 개행 문자 필요
2. **GitHub SSH 접근 실패**: `ssh-add -l`로 키 로드 확인
3. **Tailscale 만료**: `tailscale up`으로 재인증
4. **sudo 인증 실패**: `sudo -E` 또는 SSH_AUTH_SOCK 유지

## 레퍼런스

- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
- Tailscale 설정: [references/tailscale.md](references/tailscale.md)
