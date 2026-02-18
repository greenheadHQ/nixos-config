---
name: managing-minipc
description: |
  Use this skill when the user asks about NixOS MiniPC management,
  nixos-rebuild, disko, hardware-configuration.nix, generation rollback,
  config placement ("설정 배치", "어디에 넣어야", "configuration.nix에 넣을까 host에 넣을까"),
  or NixOS boot/rebuild errors.
  Triggers: "MiniPC", "미니PC", "nixos-rebuild", "disko",
  "hardware-configuration.nix", "rollback", "WoL", "Wake-on-LAN", "watchdog",
  "호스트 설정", "하드웨어 설정", "설정 배치", "어디에 넣어야", "boot failure",
  "smartd", "SMART", "디스크 건강", "lm-sensors", "sensors", "온도 모니터링".
  For nix-darwin use managing-macos. For flake issues use understanding-nix.
---

# NixOS MiniPC 관리

NixOS MiniPC 설치, 설정, 유지보수, 설정 배치 가이드입니다. (NixOS 전용)

## 설정 배치 규칙

새 NixOS 설정을 추가할 때 반드시 아래 기준에 따라 배치 위치를 결정할 것.

### 판단 기준: "다른 NixOS 호스트에서도 동일하게 적용할 수 있는가?"

| 배치 위치 | 기준 | 예시 |
|-----------|------|------|
| `hosts/<hostname>/default.nix` | 특정 하드웨어에 종속된 설정 | 인터페이스명(`enp2s0`), 디스크 UUID, WoL, PCI 장치 |
| `hosts/<hostname>/disko.nix` | 디스크 파티셔닝 | NVMe 파티션 레이아웃 |
| `hosts/<hostname>/hardware-configuration.nix` | 자동 생성 하드웨어 감지 | 커널 모듈, CPU 마이크로코드 |
| `modules/nixos/configuration.nix` | 모든 NixOS 호스트에 공통 적용 | watchdog, kernel.panic, sudo, nix-ld |
| `modules/nixos/programs/*.nix` | 공통 서비스/프로그램 모듈 | Tailscale, SSH 서버, Caddy |
| `libraries/constants.nix` | 여러 모듈에서 참조하는 값 | IP, 포트, 경로, SSH 키, UID |

### 하드웨어 종속 설정 판별 체크리스트

다음 중 하나라도 해당하면 `hosts/<hostname>/`에 배치:

- 네트워크 인터페이스명 포함 (`enp2s0`, `wlp1s0`, `eno1` 등)
- 디스크 장치 경로 또는 UUID 포함 (`/dev/nvme0n1`, `by-uuid/...`)
- PCI 버스/슬롯 주소 참조 (`0000:02:00.0`)
- 특정 하드웨어 모델/드라이버에 의존
- `fileSystems.*` 마운트 포인트 (disko가 관리하지 않는 추가 디스크)

### 현재 hosts/greenhead-minipc/default.nix 구성

```nix
# 하드웨어 종속 설정만 포함
users.users.${username}.openssh.authorizedKeys.keys = [ ... ];  # 이 호스트의 SSH 접근 허용키
networking.interfaces.enp2s0.wakeOnLan.enable = true;           # NIC 종속 (Intel igc, PCI 02:00.0)
fileSystems."/mnt/data" = { device = "by-uuid/..."; };          # HDD UUID 종속
```

## 빠른 참조

> **환경 확인**: Environment 섹션의 `Platform` 값을 확인할 것.
> - `linux` → 현재 MiniPC. 모든 명령어를 로컬에서 직접 실행. SSH 불필요.
> - `darwin` → Mac에서 실행 중. MiniPC 명령은 `ssh minipc`로 접속 후 실행.

### Rebuild 명령어

```bash
nrs             # 설정 적용 (미리보기 + 적용)
nrs --offline   # 오프라인 rebuild (캐시만 사용)
nrp             # 미리보기만
```

> nrs/nrp 스크립트는 `~/.local/lib/rebuild-common.sh`를 source하여 공통 함수(로깅, 인수 파싱, 외부 패키지 갱신, 빌드 미리보기, 아티팩트 정리)를 사용합니다.
> 소스: `modules/shared/scripts/rebuild-common.sh`, 플랫폼별: `modules/nixos/scripts/{nrs,nrp}.sh`

### MiniPC 접속 (Mac에서만 필요)

Platform이 `darwin`(Mac)일 때만 SSH 접속 필요:
```bash
ssh minipc      # ~/.ssh/config에 정의됨 (macOS 전용)
```
Platform이 `linux`이면 이미 MiniPC — SSH 금지. 명령어를 직접 실행할 것.

### 주요 파일 위치

| 파일 | 용도 |
|------|------|
| `hosts/greenhead-minipc/default.nix` | 호스트별 하드웨어 종속 설정 |
| `hosts/greenhead-minipc/disko.nix` | 디스크 파티셔닝 |
| `hosts/greenhead-minipc/hardware-configuration.nix` | 하드웨어 설정 (자동 생성) |
| `modules/nixos/configuration.nix` | NixOS 공통 설정 + 홈서버 서비스 활성화 |
| `modules/nixos/options/homeserver.nix` | mkOption 기반 서비스 정의 |
| `modules/nixos/programs/` | 공통 서비스 모듈 (Tailscale, SSH, Caddy 등) |
| `modules/nixos/programs/docker/archivebox.nix` | ArchiveBox 웹 아카이버 (Podman 컨테이너) |
| `modules/nixos/programs/smartd.nix` | S.M.A.R.T. 디스크 건강 모니터링 + Pushover 알림 |
| `modules/nixos/programs/temp-monitor/` | lm-sensors 온도 모니터링 + Pushover 알림 (5분 주기) |
| `modules/nixos/home.nix` | Home Manager (NixOS) |
| `modules/shared/scripts/rebuild-common.sh` | nrs/nrp 공통 함수 라이브러리 → `~/.local/lib/` |
| `libraries/constants.nix` | 전역 상수 (IP, 경로, SSH 키 등) |

## 시스템 복구

`nixos-rebuild switch --rollback` 또는 systemd-boot 메뉴에서 이전 세대 선택.
상세 내용: [references/installation.md](references/installation.md)

## 원격 복원력

커널 패닉 자동 재부팅(10초), systemd watchdog(30초 hang 감지 → 10분 후 강제 재부팅), WoL(같은 LAN 전용).
상세 내용: [references/features.md](references/features.md)

## 하드웨어 모니터링

### S.M.A.R.T. 디스크 건강 모니터링 (smartd)

`modules/nixos/programs/smartd.nix`에서 NixOS `services.smartd` 모듈 활용.
NVMe + HDD 자동 감지, 디스크 장애 사전 감지 시 Pushover 알림 전송.

- **온도 임계값**: 5도 변화 로그 / 50도 경고 / 60도 위험 (`-W 5,50,60`)
- **알림 우선순위**: PreFailure/CurrentPendingSector/OfflineUncorrectable → 긴급(1), 기타 → 일반(0)
- **시크릿**: `pushover-system-monitor.age` (smartd + temp-monitor 공유, NixOS 모듈 시스템이 merge)

```bash
systemctl status smartd            # 서비스 상태
sudo smartctl -a /dev/nvme0n1      # NVMe SMART 데이터
sudo smartctl -a /dev/sda          # HDD SMART 데이터
```

### 온도 모니터링 (temp-monitor)

`modules/nixos/programs/temp-monitor/`에서 systemd timer로 5분마다 CPU/NVMe 온도를 체크.
임계값 초과 시 단계별(경고/위험) Pushover 알림 발송. 임계값은 `libraries/constants.nix`의 `tempMonitor`에서 관리.

| 센서 | 경고 (priority 0) | 위험 (priority 1) | 하드웨어 crit |
|------|-------------------|-------------------|--------------|
| CPU Package | 80°C | 95°C | 105°C |
| NVMe Composite | 70°C | 85°C | 94.8°C |

- **쿨다운**: 경고 15분, 위험 5분 (단계별 차등)
- **시크릿**: `pushover-system-monitor.age` (smartd와 공유)
- **센서 식별**: 칩 타입 접두사(`coretemp-`/`nvme-`)로 동적 탐색

```bash
sensors                                        # 수동 온도 확인
sensors -j                                     # JSON 출력 (스크립트가 사용하는 형식)
systemctl status temp-monitor.service          # 서비스 상태
systemctl list-timers | grep temp-monitor      # 타이머 확인
journalctl -u temp-monitor.service -n 20       # 최근 로그
ls -la /var/lib/temp-monitor/                  # 상태 파일 (쿨다운 기록)
```

## 자주 발생하는 문제

1. **nixos-install 시 flake 캐시 문제**: `--refresh` 옵션 사용
2. **hardware-configuration.nix 충돌**: disko와 fileSystems 중복 확인
3. **부팅 불가**: systemd-boot에서 이전 세대 선택 후 롤백

## 레퍼런스

- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
- 설치 가이드: [references/installation.md](references/installation.md)
- 기능 목록: [references/features.md](references/features.md)
