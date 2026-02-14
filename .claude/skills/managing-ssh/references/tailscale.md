# SSH 키 및 Tailscale 설정

SSH 키 자동 로드와 Tailscale VPN 관련 설정입니다.

## 목차

- [SSH 키 자동 로드 (macOS)](#ssh-키-자동-로드-macos)
- [SSH 키 자동 로드 (NixOS)](#ssh-키-자동-로드-nixos)
- [Tailscale 설정 (macOS)](#tailscale-설정-macos)
- [Tailscale 설정 (NixOS)](#tailscale-설정-nixos)
- [사용 시나리오](#사용-시나리오)

---

`modules/darwin/programs/ssh/default.nix`, `modules/nixos/programs/ssh-client/default.nix`, `modules/nixos/programs/tailscale.nix`, `modules/nixos/home.nix`에서 관리됩니다.

## SSH 키 자동 로드 (macOS)

macOS는 launchd agent로 로그인 시 SSH 키를 자동 로드합니다.

**아키텍처:**

```
macOS 로그인
    │
    └──▶ com.green.ssh-add-keys (launchd agent)
            └──▶ ssh-add ~/.ssh/id_ed25519
```

**컴포넌트:**

| 컴포넌트 | 역할 |
| -------- | ---- |
| `programs.ssh` | `~/.ssh/config` 생성 (`AddKeysToAgent=yes`, `IdentityFile`) |
| `launchd.agents.ssh-add-keys` | 로그인 시 SSH 키 자동 로드 |

**생성되는 `~/.ssh/config`:**

```text
Host *
  IdentityFile /Users/<user>/.ssh/id_ed25519
  AddKeysToAgent yes
```

**확인 방법:**

```bash
ssh-add -l
launchctl list | grep ssh-add
cat ~/Library/Logs/ssh-add-keys.log
```

## SSH 키 자동 로드 (NixOS)

NixOS는 launchd가 없으므로 Home Manager에서 `ssh-agent + keychain` 조합을 사용합니다.

**설정:**

```nix
# modules/nixos/home.nix
services.ssh-agent.enable = true;
programs.keychain = {
  enable = true;
  keys = [ "id_ed25519" ];
  enableZshIntegration = true;
};
```

로그인 셸이 시작되면 keychain이 `id_ed25519`를 `ssh-agent`에 등록합니다.

## Tailscale 설정 (macOS)

이 저장소는 macOS의 Tailscale 앱 설치를 선언적으로 관리하지 않습니다.
macOS에서는 Tailscale 앱 또는 CLI로 로그인 상태를 유지하면 됩니다.

```bash
tailscale status
tailscale ip -4
```

## Tailscale 설정 (NixOS)

MiniPC(greenhead-minipc)에서는 NixOS 모듈로 Tailscale을 관리합니다.

**설정:**

```nix
services.tailscale = {
  enable = true;
  useRoutingFeatures = "server";  # subnet router만 허용
};

networking.firewall = {
  enable = true;
  trustedInterfaces = [ "tailscale0" ];
  allowedUDPPorts = [ config.services.tailscale.port ];
};
```

**핵심 포인트:**

| 항목 | 설명 |
|------|------|
| VPN 접근 | MiniPC는 Tailscale IP(`100.79.80.95`)로 접근 |
| Routing 기능 | `useRoutingFeatures = "server"` |
| 방화벽 | `tailscale0` 전체 신뢰 + Tailscale UDP 포트 허용 |
| TCP 포트 개방 | per-interface `allowedTCPPorts` 규칙은 사용하지 않음 |

## 사용 시나리오

```bash
# macOS → MiniPC
ssh minipc
# 또는
ssh greenhead@100.79.80.95

# MiniPC → macOS
ssh mac
# 또는
ssh green@100.65.50.98

# 불안정한 네트워크에서 mosh
mosh greenhead@100.79.80.95 -- tmux attach -t main
```

**양방향 SSH 요약:**

| 방향 | 명령어 | 설정 파일 |
|------|--------|----------|
| macOS → MiniPC | `ssh minipc` | `modules/darwin/programs/ssh/default.nix` |
| MiniPC → macOS | `ssh mac` | `modules/nixos/programs/ssh-client/default.nix` |
