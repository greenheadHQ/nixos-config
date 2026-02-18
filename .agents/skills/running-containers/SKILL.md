---
name: running-containers
description: |
  Use this skill when the user asks about Podman/Docker containers,
  homeserver services (immich, uptime-kuma, copyparty, vaultwarden), container OOM,
  service updates, or database backups.
  Triggers: "update immich", "immich 업데이트", "immich-update",
  "check immich version", "immich 버전 확인", upgrading Immich server,
  "uptime-kuma-update", "copyparty-update", "서비스 업데이트",
  "service-lib", "version-check", unified service update system,
  container OOM, "Tailscale IP binding" timing, OCI backend config,
  "immich-db-backup", "DB 백업", "vaultwarden-backup", "백업 타이머",
  "컨테이너", Caddy reverse proxy.
  For Anki sync details use hosting-anki. For Vaultwarden details use hosting-vaultwarden.
---

# 컨테이너 관리 (Podman/홈서버)

Podman 컨테이너 및 홈서버 서비스 (immich, uptime-kuma, copyparty, vaultwarden) 가이드입니다.
Caddy HTTPS 리버스 프록시를 통해 `*.greenhead.dev` 도메인으로 접근합니다.

## 모듈 구조 (mkOption 기반)

홈서버 서비스는 `homeserver.*` 옵션으로 선언적 활성화:

```nix
# modules/nixos/configuration.nix
homeserver.immich.enable = true;              # 사진 백업
homeserver.uptimeKuma.enable = true;          # 모니터링
homeserver.immichCleanup.enable = true;       # Claude Code Temp 앨범 매일 삭제
homeserver.immichUpdate.enable = true;        # Immich 버전 체크 + 업데이트 (03:00)
homeserver.uptimeKumaUpdate.enable = true;    # Uptime Kuma 버전 체크 + 업데이트 (03:30)
homeserver.copypartyUpdate.enable = true;     # Copyparty 버전 체크 + 업데이트 (04:00)
homeserver.ankiSync.enable = true;            # Anki 자체 호스팅 동기화 서버
homeserver.copyparty.enable = true;           # 파일 서버
homeserver.vaultwarden.enable = true;         # 비밀번호 관리자
homeserver.archiveBox.enable = true;          # ArchiveBox 웹 아카이버 (headless Chromium + SingleFile)
homeserver.archiveBoxBackup.enable = true;    # ArchiveBox SQLite 매일 백업 (05:00)
homeserver.immichBackup.enable = true;        # Immich PostgreSQL 매일 백업 (05:30)
homeserver.reverseProxy.enable = true;        # Caddy HTTPS 리버스 프록시
```

### 파일 구조

| 파일 | 역할 |
|------|------|
| `modules/nixos/options/homeserver.nix` | mkOption 정의 + 서비스 모듈 import |
| `modules/nixos/programs/docker/runtime.nix` | Podman 런타임 공통 설정 |
| `modules/nixos/programs/docker/immich.nix` | Immich (mkIf cfg.enable 래핑) |
| `modules/nixos/programs/docker/uptime-kuma.nix` | Uptime Kuma (mkIf 래핑) |
| `modules/nixos/programs/docker/copyparty.nix` | Copyparty 파일 서버 (mkIf 래핑) |
| `modules/nixos/programs/docker/vaultwarden.nix` | Vaultwarden 비밀번호 관리자 (mkIf 래핑) |
| `modules/nixos/programs/docker/vaultwarden-backup.nix` | Vaultwarden SQLite 백업 (mkIf 래핑) |
| `modules/nixos/programs/docker/immich-backup.nix` | Immich PostgreSQL 매일 백업 (mkIf 래핑) |
| `modules/nixos/programs/caddy.nix` | Caddy HTTPS 리버스 프록시 (mkIf 래핑) |
| `modules/nixos/lib/tailscale-wait.nix` | Tailscale IP 대기 유틸리티 |
| `modules/nixos/lib/service-lib.sh` | 공통 셸 라이브러리 (send_notification, fetch_github_release 등) |
| `modules/nixos/lib/service-lib.nix` | service-lib.sh Nix wrapper |
| `modules/nixos/programs/immich-update/` | Immich 버전 체크 + 업데이트 |
| `modules/nixos/programs/uptime-kuma-update/` | Uptime Kuma 버전 체크 + 업데이트 |
| `modules/nixos/programs/copyparty-update/` | Copyparty 버전 체크 + 업데이트 |
| `modules/nixos/programs/anki-sync-server/` | Anki sync (NixOS 네이티브 모듈, 비컨테이너) |
| `modules/nixos/programs/docker/archivebox.nix` | ArchiveBox 웹 아카이버 (Podman 컨테이너) |
| `modules/nixos/programs/docker/archivebox-backup.nix` | ArchiveBox SQLite 매일 백업 |
| `libraries/constants.nix` | IP, 경로, 도메인, 리소스 제한, UID 상수 |

### 상수 참조

Docker 서비스에서 사용하는 상수 (`libraries/constants.nix`):
- `constants.network.minipcTailscaleIP` - Tailscale IP
- `constants.paths.dockerData` / `mediaData` - 데이터 경로
- `constants.containers.immich.*` - Immich 리소스 제한
- `constants.ids.render` - render 그룹 GID (하드웨어 가속)
- `constants.domain.base` / `subdomains` - 커스텀 도메인 (`greenhead.dev`)

### HTTPS 접근 (Caddy 리버스 프록시)

| 서비스 | 도메인 | localhost |
|--------|--------|-----------|
| Immich | `https://immich.greenhead.dev` | `127.0.0.1:2283` |
| Uptime Kuma | `https://uptime-kuma.greenhead.dev` | `127.0.0.1:3002` |
| Copyparty | `https://copyparty.greenhead.dev` | `127.0.0.1:3923` |
| Vaultwarden | `https://vaultwarden.greenhead.dev` | `127.0.0.1:8222` |
| ArchiveBox | `https://archive.greenhead.dev` | `127.0.0.1:8000` |
| Anki Sync | (Caddy 미경유) | `100.79.80.95:27701` |

Caddy가 Cloudflare DNS-01 ACME로 Let's Encrypt 인증서를 자동 발급합니다.
Tailscale IP (`100.79.80.95:443`)에만 바인딩되어 VPN 내부 전용입니다.

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
- 예외: Immich/Copyparty/Uptime Kuma는 `127.0.0.1` 바인딩 (Caddy가 프록시)

**Uptime Kuma `--network=host` 모드**
- localhost 서비스 (Immich, Copyparty 등) 모니터링을 위해 호스트 네트워크 사용
- 기본 Podman 브릿지에서는 `127.0.0.1` 바인딩된 서비스에 접근 불가
- `UPTIME_KUMA_HOST=127.0.0.1` + `UPTIME_KUMA_PORT`로 리스닝 주소 지정
- `ports` 옵션 불필요 (`--network=host`가 직접 호스트 포트 사용)

**Caddy HTTPS 리버스 프록시**
- `modules/nixos/programs/caddy.nix`에서 Cloudflare DNS-01 ACME 사용
- `caddy.withPlugins`로 Cloudflare 플러그인 빌드 (SRI 해시 필요)
- Tailscale IP에만 바인딩 (외부 노출 안 됨)
- `caddy-env` oneshot 서비스가 시작 전 Cloudflare API 토큰 환경변수 생성
- agenix secret: `secrets/cloudflare-dns-api-token.age`
- 인증서 만료 감지: Uptime Kuma HTTPS 모니터 (`https://immich.greenhead.dev`)로 모니터링

**방화벽 보안 모델**
- `trustedInterfaces = [ "tailscale0" ]`가 Tailscale 네트워크 전체 트래픽 허용
- 따라서 per-interface 방화벽 룰은 불필요 (no-op) — 서비스별 방화벽 룰 없음
- 보안은 **서비스 바인딩 주소**에 의존: localhost 서비스는 Caddy만 접근, Tailscale IP 서비스는 VPN 내부만 접근

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

### 통합 서비스 업데이트 시스템

3개 컨테이너 서비스가 `service-lib.sh` 공통 라이브러리를 공유하는 업데이트 인프라:

| 서비스 | 버전 체크 (자동) | 수동 업데이트 | 타이머 |
|--------|-----------------|--------------|--------|
| Immich | `immich-version-check` | `sudo immich-update` | 03:00 |
| Uptime Kuma | `uptime-kuma-version-check` | `sudo uptime-kuma-update` | 03:30 |
| Copyparty | `copyparty-version-check` | `sudo copyparty-update` | 04:00 |

**백업 타이머**:

| 서비스 | systemd 서비스 | 타이머 | 백업 위치 |
|--------|---------------|--------|-----------|
| Anki Sync | `anki-sync-backup` | 04:00 | HDD |
| Vaultwarden | `vaultwarden-backup` | 04:30 | HDD (`/mnt/data/backups/vaultwarden`) |
| ArchiveBox | `archivebox-backup` | 05:00 | HDD (`/mnt/data/backups/archivebox`) |
| Immich DB | `immich-db-backup` | 05:30 | HDD (`/mnt/data/backups/immich`) |

공통 라이브러리 함수: `send_notification`, `fetch_github_release`, `get_image_digest`, `check_watchdog`, `check_initial_run`, `record_success`, `http_health_check`

서비스별 Pushover 토큰 독립 운영 (agenix: `pushover-immich`, `pushover-uptime-kuma`, `pushover-copyparty`).

**Immich**: API 버전 조회 가능 → "현재 v2.5.5 → 최신 v2.6.0" 형태 알림. 상세: [references/immich-update.md](references/immich-update.md)

**Immich DB 백업**: `immich-db-backup` 서비스가 매일 05:30에 `podman exec immich-postgres pg_dump -Fc`로 커스텀 포맷 백업 생성. 디스크 공간 검사, pg_restore --list 무결성 검증, 원자적 파일 이동, 30일 보관. 실패 시 Pushover 알림 (`pushover-immich` 재사용). `sudo systemctl start immich-db-backup`으로 수동 실행.

**Uptime Kuma/Copyparty**: 이미지에 버전 레이블 없음 → GitHub latest 추적 + 이미지 digest 비교 방식. 상세: [references/service-update-system.md](references/service-update-system.md)

### FolderAction 자동 업로드

macOS에서 `~/FolderActions/upload-immich/`에 파일을 넣으면 Immich에 자동 업로드. 상세: [references/folder-action.md](references/folder-action.md)

### 모바일 SSH 이미지 전달

모바일 SSH 환경에서 Immich를 활용하여 Claude Code에 이미지 전달. 상세: [references/mobile-ssh-image.md](references/mobile-ssh-image.md)

## 자주 발생하는 문제

1. **OCI 백엔드 미설정**: `runtime.nix`의 `backend = "podman"` 확인
2. **ML OOM**: CPU 버전 이미지로 변경
3. **IP 바인딩 실패**: `tailscale-wait.nix`가 올바르게 import 되었는지 확인
4. **DB 비밀번호 오류**: `secrets/immich-db-password.age` 존재 확인, `agenix -r` 재암호화
5. **Uptime Kuma에서 localhost 서비스 모니터링 불가**: `--network=host` 필수 (기본 브릿지에서는 `127.0.0.1` 접근 불가)
6. **Caddy HTTPS 인증서 발급 실패**: Cloudflare API 토큰 확인 (`sudo cat /run/caddy/env`), `systemctl status caddy-env`

## 레퍼런스

- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
- Immich 설정: [references/immich-setup.md](references/immich-setup.md)
- Scriptable 업로드: [references/scriptable-immich-upload.md](references/scriptable-immich-upload.md)
- Immich 업데이트: [references/immich-update.md](references/immich-update.md)
- 통합 서비스 업데이트: [references/service-update-system.md](references/service-update-system.md)
- FolderAction 자동 업로드: [references/folder-action.md](references/folder-action.md)
- 모바일 SSH 이미지 전달: [references/mobile-ssh-image.md](references/mobile-ssh-image.md)
