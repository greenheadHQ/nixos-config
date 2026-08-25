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

macOS는 로컬 `id_ed25519`를 `ssh-add`로 자동 로드하지 않고, 1Password SSH agent를 `IdentityAgent`로 사용합니다. 현행 구성은 `modules/darwin/programs/ssh/default.nix`와 `libraries/constants.nix`가 단일 소스입니다.

interactive 아키텍처:

```
macOS 로그인
    │
    └──▶ launchd.agents.onepassword-autostart
            └──▶ 1Password 데스크탑 기동
                    └──▶ 1Password SSH agent socket
                            └──▶ Ghostty ssh minipc → mac-ssh 키로 인증
```

personal Claude/Codex automation child는 이 경로와 분리된다. launcher/background 신호가 있는
child와 Claude shell snapshot은 `~/.local/share/nixos-config/headless-ssh/bin/ssh` dispatcher를
우선 사용하고, `minipc-headless` dedicated key(`IdentityAgent none`)로 인증한다. 따라서 이 경로의
실패나 팝업은 1Password 잠금 문제가 아니다.

컴포넌트:

| 컴포넌트 | 역할 |
| -------- | ---- |
| `programs.ssh.settings."*".IdentityAgent` | 1Password agent socket 사용 (`constants.onePassword.agentSocketRelPath`) |
| `programs.ssh.settings."minipc"` | Tailscale IP, `User = "greenhead"`, `IdentityFile = ~/.ssh/mac-ssh.pub`, `IdentitiesOnly = yes` |
| `programs.ssh.settings."minipc-emergency"` | 1Password 우회 fallback (`IdentityAgent = none`, `~/.ssh/emergency_ed25519`) |
| `~/.local/share/nixos-config/headless-ssh/bin/ssh` | personal automation의 MiniPC 전용 dispatcher; 다른 SSH 목적지는 raw OpenSSH로 전달 |
| `~/.ssh/minipc-headless` | dispatcher 전용 agenix materialization (`IdentityAgent none`, mode 0400) |
| `home.file.".config/1Password/ssh/agent.toml"` | SSH vault를 1Password agent에 노출 (`constants.onePassword.vaults.ssh`) |
| `home.file.".ssh/mac-ssh.pub"` | `constants.sshDeviceKeys.macSsh` 공개키 배포 |
| `launchd.agents.onepassword-autostart` | 로그인 시 1Password 백그라운드 기동 |

생성되는 `~/.ssh/config`:

```text
Host *
  AddKeysToAgent yes
  IdentityAgent <home>/<constants.onePassword.agentSocketRelPath>

Host minipc
  HostName <constants.network.minipcTailscaleIP>
  User greenhead
  IdentityFile ~/.ssh/mac-ssh.pub
  IdentitiesOnly yes

Host minipc-emergency
  HostName <constants.network.minipcTailscaleIP>
  User greenhead
  IdentityFile ~/.ssh/emergency_ed25519
  IdentityAgent none
  IdentitiesOnly yes
```

확인 방법:

```bash
ssh minipc
ssh minipc-emergency
```

interactive Ghostty의 `ssh minipc`에서 1Password agent가 `mac-ssh` 키를 제공하지 못하면 shell의 `ssh()` preflight가 1Password 기동과 잠금 해제를 안내한다. 상세 진단은 `references/troubleshooting.md`의 "Mac에서 `ssh minipc`가 1Password preflight로 차단됨" 섹션을 따른다. automation child는 상위 `SKILL.md`의 runtime binding 절차에서 `command -v ssh`와 snapshot recovery marker부터 확인한다.

이력: 과거 `com.green.ssh-add-keys` launchd agent가 `ssh-add ~/.ssh/id_ed25519`를 실행하던 구성은 1Password SSH agent 전환 후 제거/archived 되었다.

## SSH 키 자동 로드 (NixOS)

NixOS는 launchd가 없으므로 Home Manager에서 `ssh-agent + keychain` 조합을 사용합니다.

설정:

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

설정:

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

핵심 포인트:

| 항목 | 설명 |
|------|------|
| VPN 접근 | MiniPC는 `constants.network.minipcTailscaleIP`로 접근 |
| Routing 기능 | `useRoutingFeatures = "server"` |
| 방화벽 | `tailscale0` 전체 신뢰 + Tailscale UDP 포트 허용 |
| TCP 포트 개방 | per-interface `allowedTCPPorts` 규칙은 사용하지 않음 |

## 사용 시나리오

```bash
# macOS → MiniPC
ssh minipc
# 또는
ssh greenhead@<minipc Tailscale IP>

# MiniPC → macOS
ssh mac
# 또는
ssh greenhead@<macbook Tailscale IP>

# 불안정한 네트워크에서 mosh
mosh greenhead@<minipc Tailscale IP> -- tmux attach -t main
```

양방향 SSH 요약:

| 방향 | 명령어 | 설정 파일 |
|------|--------|----------|
| macOS → MiniPC | `ssh minipc` | `modules/darwin/programs/ssh/default.nix` |
| MiniPC → macOS | `ssh mac` | `modules/nixos/programs/ssh-client/default.nix` |
