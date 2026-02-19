# NixOS 특화 설정

MiniPC(greenhead-minipc)에서 사용되는 NixOS 전용 설정입니다.

## 목차

- [시스템 설정](#시스템-설정)
- [홈서버 서비스 활성화](#홈서버-서비스-활성화)
- [원격 복원력](#원격-복원력)
- [하드웨어 모니터링](#하드웨어-모니터링)
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


## 하드웨어 모니터링

### S.M.A.R.T. 디스크 건강 (smartd)

`modules/nixos/programs/smartd.nix` — NVMe + HDD 자동 감지, 디스크 장애 사전 감지 시 Pushover 알림.

### 온도 모니터링 (temp-monitor)

`modules/nixos/programs/temp-monitor/` — systemd timer (5분 주기)로 CPU/NVMe 온도 체크.

| 구성 요소 | 파일 |
|-----------|------|
| Nix 모듈 (서비스/타이머) | `temp-monitor/default.nix` |
| 체크 스크립트 | `temp-monitor/files/check-temp.sh` |
| 임계값 상수 | `libraries/constants.nix` → `tempMonitor` |
| Pushover 전송 | `modules/nixos/lib/service-lib.sh` → `send_notification_strict` |

**임계값**: CPU 경고 80°C / 위험 95°C, NVMe 경고 70°C / 위험 85°C
**쿨다운**: 경고 15분, 위험 5분 (단계별 차등)
**시크릿**: `pushover-system-monitor.age` (smartd와 공유, NixOS 모듈 시스템이 merge)

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

주요 검증 카테고리 (상세: `tests/eval-tests.nix` 참조):
- **Tailscale CGNAT**: IP 범위 독립 검증 (constants.nix oracle 무결성)
- **포트 충돌**: homeserver 서비스 간 포트 중복 방지
- **컨테이너 격리**: 127.0.0.1 바인딩 강제, publish 우회 방지, --network=host allowlist, host network listen address
- **Caddy 바인딩**: virtualHost Tailscale IP 전용, extraConfig/bind 디렉티브 우회 방지, default_bind 다중 주소/중복 방지
- **서비스 보안**: anki-sync 바인딩, openssh openFirewall/경화, vaultwarden 계정 생성 차단
- **방화벽 정책**: firewall.enable, TCP/UDP 포트, trustedInterfaces, 인터페이스별 포트, 수동 규칙 인젝션 방지
- **Tailscale 설정**: useRoutingFeatures 제한

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
| `nrh` | `sudo nix-env --list-generations --profile /nix/var/nix/profiles/system \| tail -10` | 최근 10개 세대 |
| `nrh-all` | `sudo nix-env --list-generations --profile /nix/var/nix/profiles/system` | 전체 세대 |

**Rebuild 스크립트 아키텍처:**

nrs/nrp 스크립트는 공통 함수를 `~/.local/lib/rebuild-common.sh`에서 source합니다.
각 스크립트는 `REBUILD_CMD` 변수를 설정한 후 공통 라이브러리를 로드합니다.

| 파일 | 역할 |
|------|------|
| `modules/shared/scripts/rebuild-common.sh` | 공통 라이브러리 (로깅, 인수 파싱, worktree 감지, 빌드 미리보기, 아티팩트 정리) |
| `modules/nixos/scripts/nrs.sh` | NixOS switch (exit code 4 핸들링) |
| `modules/nixos/scripts/nrp.sh` | NixOS 미리보기 전용 |

**Worktree 감지 (`detect_worktree()`):**

git worktree에서 nrs/nrp 실행 시 `git rev-parse --show-toplevel` + `--git-common-dir`로 worktree를 감지합니다. 감지 시 `FLAKE_PATH`를 worktree 경로로 오버라이드하고, `--impure` + `env NIXOS_CONFIG_PATH=...`를 통해 `flake.nix`의 `builtins.getEnv`에 worktree 경로를 전달합니다. 이를 통해 빌드와 `mkOutOfStoreSymlink` 심링크 모두 worktree를 가리킵니다.

Staleness 방지: `rebuild-common.sh`의 `@flakePath@`는 `nixosConfigDefaultPath`(항상 메인 레포)를 사용하여, worktree 빌드 후에도 다음 `nrs` 실행 시 올바른 기본 경로에서 시작합니다.

## macOS SSH 접속

`modules/nixos/programs/ssh-client/`에서 관리됩니다.

```bash
ssh mac              # 호스트명으로 접속
ssh green@100.65.50.98  # IP로 직접 접속
```
