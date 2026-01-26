# SSH 키 및 Tailscale 설정

SSH 키 자동 로드 및 Tailscale VPN 설정입니다.

## 목차

- [SSH 키 자동 로드](#ssh-키-자동-로드)
- [Tailscale 설정 (macOS)](#tailscale-설정-macos)
- [Tailscale 설정 (NixOS)](#tailscale-설정-nixos)

---

`modules/darwin/programs/ssh/`에서 관리됩니다.

## SSH 키 자동 로드

GitHub SSH 작업을 위해 SSH 키가 `ssh-agent`에 로드되어 있어야 합니다. 이 설정은 재부팅 후에도 자동으로 키를 로드합니다.

**아키텍처:**

```
macOS 로그인
    │
    ├──▶ com.green.ssh-add-keys (launchd agent)
    │       └──▶ ssh-add ~/.ssh/id_ed25519
    │
    └──▶ 터미널에서 nrs 실행
            └──▶ ensure_ssh_key_loaded() (키 로드 확인)
                    └──▶ darwin-rebuild switch
```

**컴포넌트:**

| 컴포넌트 | 역할 |
| -------- | ---- |
| `programs.ssh` | `~/.ssh/config` 생성 (AddKeysToAgent, IdentityFile) |
| `launchd.agents.ssh-add-keys` | 로그인 시 SSH 키 자동 로드 |
| `nrs.sh` | darwin-rebuild 전 키 로드 확인 |

**생성되는 `~/.ssh/config`:**

```
Host *
  IdentityFile /Users/glen/.ssh/id_ed25519
  AddKeysToAgent yes
```

**확인 방법:**

```bash
# SSH agent에 키 로드 확인
ssh-add -l

# launchd agent 상태 확인
launchctl list | grep ssh-add

# 로그 확인
cat ~/Library/Logs/ssh-add-keys.log
```

> **참고**: 자세한 트러블슈팅은 TROUBLESHOOTING.md의 SSH 키 관련 섹션을 참고하세요.

## Tailscale 설정 (macOS)

Tailscale은 Homebrew Cask로 설치되며, VPN 연결을 통해 다른 기기와 안전하게 통신합니다.

**설치:**

`modules/darwin/programs/homebrew.nix`에서 Homebrew Cask로 관리:

```nix
casks = [
  "tailscale"
];
```

**사용법:**

```bash
# 연결 상태 확인
tailscale status

# IP 확인
tailscale ip -4
```

## Tailscale 설정 (NixOS)

MiniPC(greenhead-minipc)에서 사용되는 NixOS 전용 Tailscale 설정입니다.

`modules/nixos/programs/tailscale.nix`에서 관리됩니다.

**설정:**

```nix
services.tailscale = {
  enable = true;
  useRoutingFeatures = "both";  # Funnel/Serve 지원
};

# 개발 서버 포트 (Tailscale 네트워크 내에서만)
networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 3000 3001 5173 8080 ];
```

**기능:**

| 기능 | 설명 |
|------|------|
| VPN 접속 | 100.79.80.95 (MiniPC IP) |
| Funnel/Serve | `useRoutingFeatures = "both"`로 활성화 |
| 개발 포트 | 3000, 3001, 5173, 8080 (Tailscale 네트워크 내) |

**사용 시나리오:**

```bash
# Mac에서 MiniPC로 SSH 접속
ssh minipc
# 또는
ssh greenhead@100.79.80.95

# MiniPC에서 Mac으로 SSH 접속
ssh mac
# 또는
ssh green@100.65.50.98

# Mac에서 MiniPC의 개발 서버 접근
curl http://100.79.80.95:3000

# mosh 연결 (불안정한 네트워크 대응)
mosh greenhead@100.79.80.95 -- tmux attach -t main
```

**양방향 SSH 요약:**

| 방향 | 명령어 | 설정 파일 |
|------|--------|----------|
| macOS → MiniPC | `ssh minipc` | `modules/darwin/programs/ssh/default.nix` |
| MiniPC → macOS | `ssh mac` | `modules/nixos/programs/ssh-client/default.nix` |
