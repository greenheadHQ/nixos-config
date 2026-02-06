---
name: running-containers
description: |
  This skill should be used when the user asks about Podman, Docker, immich,
  or encounters container OOM, "Tailscale IP binding" timing issues,
  OCI backend configuration. Covers photo backup services on NixOS,
  including "update immich", "immich 업데이트", "immich-update",
  "check immich version", "immich 버전 확인", and upgrading Immich server.
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

### 타임존 설정

모든 컨테이너는 시스템 타임존을 참조합니다:

```nix
# modules/nixos/programs/docker/immich.nix (예시)
environment = {
  TZ = config.time.timeZone;  # configuration.nix의 time.timeZone 참조
};
```

타임존 변경 시 `modules/nixos/configuration.nix`의 `time.timeZone`만 수정하면 모든 컨테이너에 자동 적용됩니다.

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

## Immich 버전 업데이트

새 버전 자동 알림 및 수동 업데이트를 지원합니다.

### 활성화

```nix
homeserver.immichUpdate.enable = true;
```

### 동작 방식

| 기능 | 설명 |
|------|------|
| 자동 버전 체크 | 매일 03:00 GitHub Releases API 확인 |
| Pushover 알림 | 새 버전 발견 시 버전 + 릴리즈노트 요약 전송 |
| 수동 업데이트 | `sudo immich-update` 명령으로 실행 |
| Dry Run | `sudo immich-update --dry-run`으로 사전 확인 |

### 업데이트 프로세스

1. postgres 컨테이너 상태 확인
2. DB 백업 (pg_dump + gzip + 무결성 검증)
3. 이미지 pull (server + ML)
4. 컨테이너 재시작 (stop all → start ML → start Server)
5. 헬스체크 (60회 재시도, 10분)
6. 결과 알림

### 명령어

```bash
sudo systemctl start immich-version-check  # 버전 체크 수동 실행
sudo immich-update                          # 업데이트 실행
sudo immich-update --dry-run                # 상태만 확인
journalctl -u immich-version-check -f       # 로그 확인
systemctl list-timers | grep immich         # 타이머 확인
```

### 파일 구조

| 파일 | 역할 |
|------|------|
| `modules/nixos/programs/immich-update/default.nix` | systemd 서비스/타이머 + 스크립트 정의 |
| `modules/nixos/programs/immich-update/files/version-check.sh` | 자동 버전 체크 스크립트 |
| `modules/nixos/programs/immich-update/files/update-script.sh` | 수동 업데이트 스크립트 |

상세 가이드: [references/immich-update.md](references/immich-update.md)

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

## 모바일 SSH에서 Claude Code로 이미지 전달

모바일 SSH 환경(Termius 등)에서 클립보드 이미지 붙여넣기가 불가능할 때 Immich를 활용하여 이미지를 전달하는 방법입니다.

### 핵심 원리

| 도구 | 실행 위치 | Tailscale IP 접근 |
|------|-----------|-------------------|
| WebFetch | Anthropic 서버 | ❌ 불가 |
| Read | MiniPC 로컬 | ✅ 파일 경로로 가능 |

WebFetch는 Anthropic 서버에서 실행되어 Tailscale 내부 IP에 접근 불가하지만, Read는 로컬에서 실행되어 **파일 경로**로 이미지를 읽을 수 있습니다.

### 워크플로우

```
[iPhone]
사진 공유 → Scriptable "Upload to Claude Code" → 경로 클립보드 복사

[MiniPC SSH]
경로 붙여넣기 → Claude Code Read 도구로 이미지 확인

[자동화]
매일 07:00 KST "Claude Code Temp" 앨범 전체 삭제 + Pushover 알림
```

### 경로 변환 (중요)

Immich API가 반환하는 `originalPath`:
```
/usr/src/app/upload/upload/UUID/xx/xx/file.png
```

호스트에서 접근 가능한 경로:
```
/var/lib/docker-data/immich/upload-cache/UUID/xx/xx/file.png
```

**변환 규칙**: `/usr/src/app/upload/upload/` → `/var/lib/docker-data/immich/upload-cache/`

### 상세 설정

- Scriptable 스크립트: [references/scriptable-immich-upload.md](references/scriptable-immich-upload.md)
- 자동 삭제 설정: `homeserver.immichCleanup.enable = true`

### macOS에서 immich 사진 확인

macOS 환경에서 immich 사진 경로를 받았을 때는 `viewing-immich-photo` 스킬 참조.
SSH로 MiniPC에서 파일을 가져와 로컬에서 Read 도구로 확인합니다.

## 레퍼런스

- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
- immich 설정: [references/immich-setup.md](references/immich-setup.md)
- Scriptable 업로드: [references/scriptable-immich-upload.md](references/scriptable-immich-upload.md)
- Immich 업데이트: [references/immich-update.md](references/immich-update.md)
