# NixOS 특화 설정

MiniPC(greenhead-minipc)에서 사용되는 NixOS 전용 설정입니다.

## 목차

- [시스템 설정](#시스템-설정)
- [네트워크/보안 설정](#네트워크보안-설정)
- [SSH 서버 설정](#ssh-서버-설정)
- [mosh 설정](#mosh-설정)
- [Tailscale 설정](#tailscale-설정)
- [fail2ban 설정](#fail2ban-설정)
- [호스트 설정](#호스트-설정)
- [NixOS Alias](#nixos-alias)

---

`modules/nixos/`에서 관리됩니다.

## 시스템 설정

| 설정 | 파일 | 설명 |
|------|------|------|
| sudo NOPASSWD | `configuration.nix` | wheel 그룹에 비밀번호 없이 sudo 허용 |
| nix-ld | `configuration.nix` | 동적 링크 바이너리 지원 (Claude Code 등) |
| Ghostty terminfo | `configuration.nix` | Ghostty 터미널 호환성 |

## 네트워크/보안 설정

| 모듈 | 파일 | 설명 |
|------|------|------|
| SSH 서버 | `programs/ssh.nix` | 공개키 인증, 비밀번호 비활성화 |
| mosh | `programs/mosh.nix` | UDP 60000-61000 포트 오픈 |
| Tailscale | `programs/tailscale.nix` | VPN 접속 (100.79.80.95) |
| fail2ban | `programs/fail2ban.nix` | SSH 무차별 대입 방지 (3회 실패 시 24시간 차단) |

## SSH 서버 설정

```nix
services.openssh = {
  enable = true;
  settings = {
    PermitRootLogin = "no";
    PasswordAuthentication = false;
    PubkeyAuthentication = true;
    ClientAliveInterval = 60;
    ClientAliveCountMax = 3;
  };
};
```

## mosh 설정

불안정한 네트워크(모바일 등)에서 연결 유지를 위한 mosh 서버입니다.

```bash
# 클라이언트(Mac/iPhone)에서 접속
mosh greenhead@100.79.80.95

# 또는 tmux와 함께
mosh greenhead@100.79.80.95 -- tmux attach -t main
```

## Tailscale 설정

```nix
services.tailscale = {
  enable = true;
  useRoutingFeatures = "both";  # Funnel/Serve 지원
};

# 개발 서버 포트 (Tailscale 네트워크 내에서만)
networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 3000 3001 5173 8080 ];
```

## fail2ban 설정

SSH 무차별 대입 공격 방지:

```nix
services.fail2ban.jails.sshd.settings = {
  enabled = true;
  maxretry = 3;      # 3회 실패 시
  findtime = "10m";  # 10분 내
  bantime = "24h";   # 24시간 차단
};
```

## 호스트 설정

`hosts/greenhead-minipc/`에서 관리됩니다.

| 파일 | 내용 |
|------|------|
| `default.nix` | 호스트 진입점, SSH 키, HDD 마운트 |
| `disko.nix` | NVMe 디스크 파티션 설정 |
| `hardware-configuration.nix` | 하드웨어 자동 감지 설정 |

## NixOS Alias

MiniPC에서 사용하는 rebuild 관련 alias입니다.

| Alias | 명령어 | 설명 |
|-------|--------|------|
| `nrs` | `~/.local/bin/nrs.sh` | rebuild (미리보기 + 확인 + 적용) |
| `nrs-offline` | `nrs.sh --offline` | 오프라인 rebuild |
| `nrp` | `~/.local/bin/nrp.sh` | 미리보기만 |
| `nrh` | `sudo nix-env --list-generations ...` | 세대 히스토리 |

## macOS SSH 접속

`modules/nixos/programs/ssh-client/`에서 관리됩니다.

MiniPC에서 macOS로 Tailscale VPN을 통해 SSH 접속할 수 있습니다.

**사용법:**

```bash
ssh mac              # 호스트명으로 접속
ssh green@100.65.50.98  # IP로 직접 접속
```

**SSH config 설정:**

```
Host mac
  HostName 100.65.50.98
  User green
  IdentityFile ~/.ssh/id_ed25519
```

> **참고**: MiniPC 설정 및 설치 상세 내용은 [MINIPC_PLAN_V3.md](../../../../../../../nixos-config/docs/MINIPC_PLAN_V3.md)를 참고하세요.
