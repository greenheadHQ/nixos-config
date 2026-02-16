# NixOS 특화 설정

MiniPC(greenhead-minipc)에서 사용되는 NixOS 전용 설정입니다.

## 목차

- [시스템 설정](#시스템-설정)
- [홈서버 서비스 활성화](#홈서버-서비스-활성화)
- [원격 복원력](#원격-복원력)
- [네트워크/보안 설정](#네트워크보안-설정)
- [SSH 서버 설정](#ssh-서버-설정)
- [mosh 설정](#mosh-설정)
- [Tailscale 설정](#tailscale-설정)
- [호스트 설정](#호스트-설정)
- [NixOS Alias](#nixos-alias)

---

`modules/nixos/`에서 관리됩니다.

## 시스템 설정

| 설정 | 파일 | 설명 |
|------|------|------|
| sudo NOPASSWD | `configuration.nix` | wheel 그룹에 비밀번호 없이 sudo 허용 |
| nix-ld | `configuration.nix` | 동적 링크 바이너리 지원 (Claude Code 등) |
| Ghostty terminfo | `packages.nix` (nixosOnly) | Ghostty 터미널 호환성 |
| journald 용량 제한 | `configuration.nix` | SystemMaxUse=2G, 30일 보존 |

## 홈서버 서비스 활성화

`modules/nixos/configuration.nix`에서 `homeserver.*` 옵션으로 관리됩니다.

```nix
homeserver.immich.enable = true;
homeserver.uptimeKuma.enable = true;
homeserver.immichCleanup.enable = true;
homeserver.immichUpdate.enable = true;
homeserver.uptimeKumaUpdate.enable = true;
homeserver.copypartyUpdate.enable = true;
homeserver.ankiSync.enable = true;
homeserver.copyparty.enable = true;
homeserver.vaultwarden.enable = true;
homeserver.immichBackup.enable = true;
homeserver.reverseProxy.enable = true;
```

모든 옵션 정의와 모듈 import는 `modules/nixos/options/homeserver.nix`에 있습니다.

## 원격 복원력

여행 등 물리 접근 불가 시 시스템 가용성을 보장하는 설정입니다.

### 자동 복구 (modules/nixos/configuration.nix — 범용)

| 설정 | 값 | 동작 |
|------|-----|------|
| `boot.kernel.sysctl."kernel.panic"` | `10` | 커널 패닉 시 10초 후 자동 재부팅 |
| `systemd.settings.Manager.RuntimeWatchdogSec` | `"30s"` | systemd가 30초 내 ping 실패 시 hang 판정 |
| `systemd.settings.Manager.RebootWatchdogSec` | `"10min"` | hang 판정 후 10분 내 강제 재부팅 |

이 설정들은 하드웨어와 무관한 범용 설정이므로 `modules/nixos/configuration.nix`에 배치.

### Wake-on-LAN (hosts/greenhead-minipc/default.nix — 하드웨어 종속)

```nix
networking.interfaces.enp2s0.wakeOnLan.enable = true;
```

- NIC: Intel igc (PCI 0000:02:00.0), MAC: 84:47:09:5a:43:31
- systemd .link 파일로 매 부팅 시 `WakeOnLan=magic` 적용 (ethtool 불필요)
- `enp2s0`은 이 MiniPC PCI 토폴로지에 종속 → 호스트별 설정에 배치

**제한사항:**
- Layer 2 브로드캐스트라 **같은 LAN에서만 동작** (원격 불가)
- 원격 전원 투입이 필요하면 스마트 플러그 + BIOS "Restore on AC Power Loss" 사용

**확인 명령어:**

```bash
nix-shell -p ethtool --run "sudo ethtool enp2s0 | grep Wake"
# Wake-on: g  ← magic packet 활성화 확인
```


## 네트워크/보안 설정

| 모듈 | 파일 | 설명 |
|------|------|------|
| SSH 서버 | `programs/ssh.nix` | 공개키 인증, 비밀번호 비활성화, LAN 포트 미개방 |
| mosh | `programs/mosh.nix` | 모바일 쉘, LAN 포트 미개방 |
| Tailscale | `programs/tailscale.nix` | VPN (100.79.80.95), 유일한 접근 경로 |

**방화벽 정책 (tailscale.nix):**

```nix
networking.firewall = {
  enable = true;
  trustedInterfaces = [ "tailscale0" ];  # VPN 전체 허용
  allowedUDPPorts = [ config.services.tailscale.port ];  # 41641 (WireGuard)
};
```

LAN(enp2s0)에서의 SSH/HTTP 접근은 차단됨. Tailscale VPN만 허용.

**Pre-commit 보안 검증 (eval-tests):**

`tests/eval-tests.nix`에서 매 커밋 시 네트워크 노출 경계를 자동 검증합니다:

```bash
# 직접 실행 (~1.2초)
nix eval --impure --file tests/eval-tests.nix

# lefthook pre-commit으로 자동 실행
```

주요 검증 항목 (29개 테스트):
- **Test 0**: Tailscale CGNAT IP 범위 독립 검증 (constants.nix oracle 무결성)
- **Test 1**: 포트 충돌 없음 (homeserver 서비스 간)
- **Test 2a-2e**: 컨테이너 포트 127.0.0.1 바인딩 강제, extraOptions publish 우회 방지, --network=host allowlist (현재: uptime-kuma만), host network 컨테이너 listen address 127.0.0.1 강제
- **Test 3a-3b**: Caddy virtualHost Tailscale IP 전용 바인딩 (vacuous truth 방지 포함)
- **Test 4a-4b**: Caddy globalConfig default_bind 존재 + 중복 방지 (builtins.split 기반, newline-safe)
- **Test 5a-5g**: 서비스 보안 — anki-sync address/openFirewall, openssh/mosh openFirewall, SSH 경화 (PermitRootLogin, PasswordAuthentication), vaultwarden SIGNUPS_ALLOWED
- **Test 6a-6j**: 방화벽 정책 — firewall.enable, allowedTCPPorts=[], 포트 범위 없음, trustedInterfaces=[tailscale0], UDP는 Tailscale 포트만, 인터페이스별 포트 없음, 수동 nftables 규칙 없음, NAT enable/forwardPorts 방지

새 서비스 추가 시: 컨테이너가 `127.0.0.1:` 접두사로 포트 매핑하면 자동으로 검증됨. --network=host가 필요하면 `tests/eval-tests.nix`의 `hostNetworkAllowlist`에 추가 필요.

## SSH 서버 설정

```nix
services.openssh = {
  enable = true;
  openFirewall = false;  # trustedInterfaces(tailscale0)에서 이미 허용. LAN 노출 방지
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
  useRoutingFeatures = "server";  # subnet router만 허용 (exit node 비활성화)
};
```

## 호스트 설정

`hosts/greenhead-minipc/`에서 관리됩니다. 하드웨어 종속 설정만 포함.

| 파일 | 내용 |
|------|------|
| `default.nix` | SSH 키, WoL(enp2s0), HDD 마운트(UUID) |
| `disko.nix` | NVMe 파티션 설정 (ESP 512M + swap 8G + root) |
| `hardware-configuration.nix` | 하드웨어 자동 감지 (커널 모듈, CPU 마이크로코드) |

## NixOS Alias

| Alias | 명령어 | 설명 |
|-------|--------|------|
| `nrs` | `~/.local/bin/nrs.sh` | rebuild (미리보기 + 확인 + 적용) |
| `nrs-offline` | `~/.local/bin/nrs.sh --offline` | 오프라인 rebuild |
| `nrp` | `~/.local/bin/nrp.sh` | 미리보기만 |
| `nrp-offline` | `~/.local/bin/nrp.sh --offline` | 오프라인 미리보기 |
| `nrh` | `sudo nix-env --list-generations --profile /nix/var/nix/profiles/system` (tail 10) | 최근 10개 세대 |
| `nrh-all` | `sudo nix-env --list-generations --profile /nix/var/nix/profiles/system` | 전체 세대 |

## macOS SSH 접속

`modules/nixos/programs/ssh-client/`에서 관리됩니다.

```bash
ssh mac              # 호스트명으로 접속
ssh green@100.65.50.98  # IP로 직접 접속
```
