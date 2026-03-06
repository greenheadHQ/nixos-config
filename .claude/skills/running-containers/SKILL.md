---
name: running-containers
description: |
  This skill should be used when the user asks about Podman/Docker containers,
  homeserver services (immich, uptime-kuma, copyparty, vaultwarden, karakeep), container OOM,
  service updates, or database backups.
  Triggers: "update immich", "immich 업데이트", "immich-update",
  "check immich version", "immich 버전 확인", upgrading Immich server,
  "uptime-kuma-update",
  "서비스 업데이트", "service-lib", "version-check", unified service update system,
  container OOM, "Tailscale IP binding" timing, OCI backend config,
  "immich-db-backup", "DB 백업", "백업 타이머",
  "컨테이너", Caddy reverse proxy.
  For service-specific workflows use hosting-anki, hosting-copyparty, hosting-vaultwarden, hosting-karakeep.
---

# 컨테이너 관리 (Podman/홈서버)

Podman 컨테이너 및 홈서버 서비스 (immich, uptime-kuma, copyparty, vaultwarden, karakeep) 운영 가이드.
Caddy HTTPS 리버스 프록시를 통해 `*.greenhead.dev` 도메인으로 접근한다.

## 모듈 구조 (mkOption 기반)

홈서버 서비스는 `homeserver.*` 옵션으로 선언적 활성화한다:

```nix
# modules/nixos/configuration.nix — 주요 서비스만 발췌
homeserver.immich.enable = true;              # 사진 백업
homeserver.uptimeKuma.enable = true;          # 모니터링
homeserver.copyparty.enable = true;           # 파일 서버
homeserver.vaultwarden.enable = true;         # 비밀번호 관리자
homeserver.karakeep.enable = true;            # 웹 아카이버
homeserver.reverseProxy.enable = true;        # Caddy HTTPS 리버스 프록시
# 부가 서비스: *Update, *Backup, *Cleanup, *Notify 등도 동일 패턴
```

### 파일 구조

| 경로 패턴 | 역할 |
|-----------|------|
| `modules/nixos/options/homeserver.nix` | mkOption 정의 + 서비스 모듈 import |
| `modules/nixos/programs/docker/runtime.nix` | Podman 런타임 공통 설정 |
| `modules/nixos/programs/docker/<서비스>.nix` | 개별 컨테이너 정의 (immich, uptime-kuma, copyparty, vaultwarden, karakeep 등) |
| `modules/nixos/programs/<서비스>-update/` | 버전 체크 + 업데이트 (immich, uptime-kuma, copyparty, vaultwarden, karakeep) |
| `modules/nixos/programs/caddy.nix` | Caddy HTTPS 리버스 프록시 |
| `modules/nixos/lib/service-lib.sh` / `.nix` | 공통 셸 라이브러리 + Nix wrapper |
| `modules/nixos/lib/mk-update-module.nix` | 업데이트 모듈 생성 헬퍼 |
| `modules/nixos/lib/tailscale-wait.nix` | Tailscale IP 대기 유틸리티 |
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
| Karakeep | `https://archive.greenhead.dev` | `127.0.0.1:3000` |
| Anki Sync | (Caddy 미경유) | `100.79.80.95:27701` |

Caddy가 Cloudflare DNS-01 ACME로 Let's Encrypt 인증서를 자동 발급한다.
Tailscale IP (`100.79.80.95:443`)에만 바인딩되어 VPN 내부 전용이다.

모든 컨테이너는 `config.time.timeZone`을 참조하며, `configuration.nix`의 `time.timeZone`만 수정하면 자동 적용된다.

## Known Issues

- **OCI 백엔드 명시 필수**: `runtime.nix`의 `backend = "podman"` 누락 시 Docker fallback 에러
- **immich ML OOM**: CPU 버전 이미지 사용 (`release`, openvino 아님)
- **Tailscale IP 바인딩**: `tailscale-wait.nix`로 60초 대기. Immich/Copyparty/Uptime Kuma/Vaultwarden은 `127.0.0.1` 바인딩 (Caddy 프록시)
- **Uptime Kuma `--network=host`**: localhost 서비스 모니터링을 위해 호스트 네트워크 필수
- **Caddy HTTPS**: Cloudflare DNS-01 ACME, Tailscale IP 전용 바인딩, `secrets/cloudflare-dns-api-token.age`
- **방화벽**: `trustedInterfaces = [ "tailscale0" ]` — 보안은 서비스 바인딩 주소에 의존
- **Immich DB 비밀번호**: agenix `secrets/immich-db-password.age`, `POSTGRES_PASSWORD_FILE` 볼륨 마운트

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

5개 컨테이너 서비스가 `service-lib.sh` 공통 라이브러리를 공유하는 업데이트 인프라:

| 서비스 | 버전 체크 (자동) | 수동 업데이트 | 타이머 |
|--------|-----------------|--------------|--------|
| Immich | `immich-version-check` | `sudo immich-update` | 03:00 |
| Uptime Kuma | `uptime-kuma-version-check` | `sudo uptime-kuma-update` | 03:30 |
| Copyparty | `copyparty-version-check` | `sudo copyparty-update` | 04:00 |
| Karakeep | `karakeep-version-check` | `sudo karakeep-update --ack-bridge-risk` | 06:00 |
| Vaultwarden | `vaultwarden-version-check` | `sudo vaultwarden-update` | 06:30 |

**백업 타이머**:

| 서비스 | systemd 서비스 | 타이머 | 백업 위치 |
|--------|---------------|--------|-----------|
| Anki Sync | `anki-sync-backup` | 04:00 | HDD |
| Vaultwarden | `vaultwarden-backup` | 04:30 | HDD (`/mnt/data/backups/vaultwarden`) |
| Karakeep | `karakeep-backup` | 05:00 | HDD (`/mnt/data/backups/karakeep`) |
| Immich DB | `immich-db-backup` | 05:30 | HDD (`/mnt/data/backups/immich`) |

공통 라이브러리 함수: `send_notification`, `fetch_github_release`, `get_image_digest`, `check_watchdog`, `check_initial_run`, `record_success`, `http_health_check`

서비스별 Pushover 토큰 독립 운영 (agenix: `pushover-immich`, `pushover-uptime-kuma`, `pushover-copyparty`, `pushover-karakeep`, `pushover-vaultwarden`).

**Immich**: API 버전 조회 가능 → "현재 v2.5.5 → 최신 v2.6.0" 형태 알림. 상세: [references/immich-update.md](references/immich-update.md)

**Immich DB 백업**: `immich-db-backup` 서비스가 매일 05:30에 `podman exec immich-postgres pg_dump -Fc`로 커스텀 포맷 백업 생성. 디스크 공간 검사, pg_restore --list 무결성 검증, 원자적 파일 이동, 30일 보관. 실패 시 Pushover 알림 (`pushover-immich` 재사용). `sudo systemctl start immich-db-backup`으로 수동 실행.

**Uptime Kuma/Copyparty/Karakeep**: 이미지에 버전 레이블 없음 → GitHub latest 추적 + 이미지 digest 비교 방식. 상세: [references/service-update-system.md](references/service-update-system.md)
Karakeep 수동 업데이트는 `--ack-bridge-risk` 플래그가 필수다 (브릿지/로그 의존성 인지 강제).

**Karakeep 이벤트 알림**: `karakeep-notify`가 웹훅→Pushover 브리지(socat)로 아카이빙 성공/실패 알림을 전송한다.

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
