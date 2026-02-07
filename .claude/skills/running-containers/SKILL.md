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

Podman 컨테이너 및 홈서버 서비스 (immich, uptime-kuma) 가이드입니다.

## 모듈 구조 (mkOption 기반)

홈서버 서비스는 `homeserver.*` 옵션으로 선언적 활성화:

```nix
# modules/nixos/configuration.nix
homeserver.immich.enable = true;      # 사진 백업
homeserver.uptimeKuma.enable = true;  # 모니터링
```

### 파일 구조

| 파일 | 역할 |
|------|------|
| `modules/nixos/options/homeserver.nix` | mkOption 정의 + 서비스 모듈 import |
| `modules/nixos/programs/docker/runtime.nix` | Podman 런타임 공통 설정 |
| `modules/nixos/programs/docker/immich.nix` | Immich (mkIf cfg.enable 래핑) |
| `modules/nixos/programs/docker/uptime-kuma.nix` | Uptime Kuma (mkIf 래핑) |
| `modules/nixos/lib/tailscale-wait.nix` | Tailscale IP 대기 유틸리티 |
| `modules/nixos/programs/anki-sync-server/` | Anki sync (NixOS 네이티브 모듈, 비컨테이너) |
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
podman ps -a                              # 컨테이너 목록
podman logs <container-name>              # 로그 확인
podman restart <container-name>           # 컨테이너 재시작
systemctl status podman-<container-name>  # systemd 서비스 상태
```

### 서비스 활성화/비활성화

```nix
# modules/nixos/configuration.nix에서 변경 후 nrs 실행
```

### Immich 업데이트

`homeserver.immichUpdate.enable = true`로 활성화. `sudo immich-update` 명령으로 수동 업데이트. 상세: [references/immich-update.md](references/immich-update.md)

### FolderAction 자동 업로드

macOS에서 `~/FolderActions/upload-immich/`에 파일을 넣으면 Immich에 자동 업로드. 상세: [references/folder-action.md](references/folder-action.md)

### 모바일 SSH 이미지 전달

모바일 SSH 환경에서 Immich를 활용하여 Claude Code에 이미지 전달. 상세: [references/mobile-ssh-image.md](references/mobile-ssh-image.md)

## 자주 발생하는 문제

1. **OCI 백엔드 미설정**: `runtime.nix`의 `backend = "podman"` 확인
2. **ML OOM**: CPU 버전 이미지로 변경
3. **IP 바인딩 실패**: `tailscale-wait.nix`가 올바르게 import 되었는지 확인
4. **DB 비밀번호 오류**: `secrets/immich-db-password.age` 존재 확인, `agenix -r` 재암호화

## 레퍼런스

- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
- Immich 설정: [references/immich-setup.md](references/immich-setup.md)
- Scriptable 업로드: [references/scriptable-immich-upload.md](references/scriptable-immich-upload.md)
- Immich 업데이트: [references/immich-update.md](references/immich-update.md)
- FolderAction 자동 업로드: [references/folder-action.md](references/folder-action.md)
- 모바일 SSH 이미지 전달: [references/mobile-ssh-image.md](references/mobile-ssh-image.md)
