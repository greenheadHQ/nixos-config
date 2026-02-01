---
name: running-containers
description: |
  This skill should be used when the user asks about Podman, Docker, immich,
  or encounters container OOM, "Tailscale IP binding" timing issues,
  OCI backend configuration. Covers photo backup services on NixOS.
---

# 컨테이너 관리 (Podman/홈서버)

Podman 컨테이너 및 홈서버 서비스 (immich, uptime-kuma, plex) 가이드입니다.

## 모듈 구조 (mkOption 기반)

홈서버 서비스는 `homeserver.*` 옵션으로 선언적 활성화:

```nix
# modules/nixos/configuration.nix
homeserver.immich.enable = true;      # 사진 백업
homeserver.uptimeKuma.enable = true;  # 모니터링
homeserver.plex.enable = false;       # 미디어 스트리밍 (비활성)
```

### 파일 구조

| 파일 | 역할 |
|------|------|
| `modules/nixos/options/homeserver.nix` | mkOption 정의 + 서비스 모듈 import |
| `modules/nixos/programs/docker/runtime.nix` | Podman 런타임 공통 설정 |
| `modules/nixos/programs/docker/immich.nix` | Immich (mkIf cfg.enable 래핑) |
| `modules/nixos/programs/docker/uptime-kuma.nix` | Uptime Kuma (mkIf 래핑) |
| `modules/nixos/programs/docker/plex.nix` | Plex (mkIf 래핑) |
| `modules/nixos/lib/tailscale-wait.nix` | Tailscale IP 대기 유틸리티 |
| `libraries/constants.nix` | IP, 경로, 리소스 제한, UID 상수 |

### 상수 참조

Docker 서비스에서 사용하는 상수 (`libraries/constants.nix`):
- `constants.network.minipcTailscaleIP` - Tailscale IP
- `constants.paths.dockerData` / `mediaData` - 데이터 경로
- `constants.containers.immich.*` - Immich 리소스 제한
- `constants.ids.render` - render 그룹 GID (하드웨어 가속)

## Known Issues

**OCI 백엔드 명시 필수**
- `virtualisation.oci-containers.backend = "podman";` (`runtime.nix`에서 설정)
- 누락 시 Docker 백엔드로 fallback되어 에러 발생

**immich ML 컨테이너 OOM**
- GPU 없는 환경에서 기본 ML 컨테이너가 메모리 부족
- 해결: CPU 버전 컨테이너 사용 (`ghcr.io/immich-app/immich-machine-learning:release`)

**Tailscale IP 바인딩 타이밍**
- 부팅 시 Tailscale IP 할당 전에 서비스 시작하면 바인딩 실패
- 해결: `tailscale-wait.nix` 공통 모듈로 60초 대기

**Immich DB 비밀번호**
- agenix로 관리 (`secrets/immich-db-password.age`)
- `POSTGRES_PASSWORD_FILE` / `DB_PASSWORD_FILE` 볼륨 마운트 방식
- 시크릿 파일 경로: `config.age.secrets.immich-db-password.path`

## 빠른 참조

### Podman 명령어

```bash
# 컨테이너 목록
podman ps -a

# 로그 확인
podman logs <container-name>

# 컨테이너 재시작
podman restart <container-name>

# systemd 서비스로 관리
systemctl status podman-<container-name>
```

### 서비스 활성화/비활성화

```nix
# modules/nixos/configuration.nix에서 변경 후 nrs 실행
homeserver.plex.enable = true;   # 활성화
homeserver.plex.port = 32400;    # 포트 커스터마이징 (기본값은 constants.nix)
```

## Immich FolderAction 자동 업로드 (macOS)

`~/FolderActions/upload-immich/`에 미디어 파일을 넣으면 Immich 서버에 자동 업로드.

### 파일 구조

| 파일 | 역할 |
|------|------|
| `modules/darwin/programs/folder-actions/default.nix` | launchd agent + script 배포 |
| `modules/darwin/programs/folder-actions/files/scripts/upload-immich.sh` | 업로드 스크립트 |
| `secrets/immich-api-key.age` | Immich API 키 (agenix) |
| `secrets/pushover-immich.age` | Pushover 자격증명 (agenix) |

### 동작 플로우

파일 감지 → 안정화 대기 (5분 타임아웃) → 서버 ping → `bunx @immich/cli upload` → Pushover 알림 → 원본 삭제

### 핵심 설계

- **`--delete` 버그 대응**: CLI는 중복 파일을 삭제하지 않음. 사전 기록한 미디어 목록 기반으로 수동 삭제
- **데이터 손실 방지**: 업로드 전에 파일 목록을 배열에 기록, 완료 후 해당 파일만 삭제
- **launchd TimeOut 1800초**: `bunx` 업로드 무한 대기 방지. PID 기반 stale lock으로 강제 종료 후 자동 복구
- **`IMMICH_INSTANCE_URL`**: `constants.nix`에서 IP/포트 자동 구성 (launchd EnvironmentVariables)
- **비미디어 파일**: 미디어 없이 비미디어만 있으면 무시 (알림 스팸 방지)

### 디버깅

```bash
# 로그 확인
tail -f ~/Library/Logs/folder-actions/upload-immich.log

# agent 상태
launchctl list | grep upload-immich

# 수동 실행 테스트
~/.local/bin/upload-immich.sh
```

## 자주 발생하는 문제

1. **OCI 백엔드 미설정**: `runtime.nix`의 `backend = "podman"` 확인
2. **ML OOM**: CPU 버전 이미지로 변경
3. **IP 바인딩 실패**: `tailscale-wait.nix`가 올바르게 import 되었는지 확인
4. **DB 비밀번호 오류**: `secrets/immich-db-password.age` 존재 확인, `agenix -r` 재암호화

## 레퍼런스

- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
- immich 설정: [references/immich-setup.md](references/immich-setup.md)
