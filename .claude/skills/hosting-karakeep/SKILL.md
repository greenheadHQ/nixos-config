---
name: hosting-karakeep
description: |
  This skill should be used when the user needs to manage Karakeep web archiver/bookmark manager:
  3-container setup, SingleFile integration, webhooks, backup, log monitoring, fallback sync.
  Triggers: "Karakeep", "카라킵", "웹 아카이브", "web archive",
  "archive.greenhead.dev", "북마크", "아카이빙", "bookmark manager",
  "SingleFile push", "singlefile-bridge", "karakeep-update",
  "karakeep 백업", "karakeep 로그", "karakeep OOM",
  "fallback sync", "crawl failure", "Meilisearch".
  For container-level operations (OOM, Podman, update system), use running-containers instead.
---

# Hosting Karakeep

## Purpose

Karakeep 웹 아카이버/북마크 관리 서비스 운영 스킬.
`https://archive.greenhead.dev`에서 Tailscale VPN 전용으로 제공.

## 빠른 참조

| 명령어 | 설명 |
|--------|------|
| `sudo systemctl start podman-karakeep.service` | Karakeep 앱 시작 |
| `sudo systemctl stop podman-karakeep.service` | Karakeep 앱 중지 |
| `sudo systemctl start karakeep-backup` | 수동 백업 실행 |
| `sudo karakeep-update --ack-bridge-risk` | 수동 업데이트 (브릿지 리스크 인지 필수) |
| `journalctl -u karakeep-webhook-bridge -f` | 웹훅 브리지 로그 확인 |
| `journalctl -u karakeep-log-monitor -f` | 실패 URL 감시 로그 확인 |
| `journalctl -u karakeep-singlefile-bridge -f` | SingleFile 대용량 분기 브리지 로그 확인 |
| `sudo systemctl start karakeep-fallback-sync` | fallback HTML 자동 재연결 1회 실행 |

## Architecture

3컨테이너 Podman 구성 (`karakeep-network`):

| 컨테이너 | 이미지 | 역할 | 리소스 |
|-----------|--------|------|--------|
| `karakeep` | `ghcr.io/karakeep-app/karakeep:release` | Next.js 앱 (포트 3000) | 2GB / 1 CPU |
| `karakeep-chrome` | `gcr.io/zenika-hub/alpine-chrome:124` | 헤드리스 Chrome (스크린샷) | 2GB / 1 CPU |
| `karakeep-meilisearch` | `getmeili/meilisearch:v1.13.3` | 전문 검색 | 1GB / 0.5 CPU |

### Data Path

```text
/mnt/data/karakeep/         # HDD (모든 데이터)
├── db.db                   # 메인 SQLite DB
├── queue.db                # 작업 큐 DB
├── assets/                 # 스크린샷, 아카이브 HTML
└── meilisearch/            # 검색 인덱스

/mnt/data/backups/karakeep/ # SQLite 백업 (매일 05:00, 30일 보관)
```

### Key Files

| 파일 | 역할 |
|------|------|
| `modules/nixos/programs/docker/karakeep.nix` | 메인 모듈 (3컨테이너 + 네트워크 + env) |
| `modules/nixos/programs/docker/karakeep-backup.nix` | SQLite 백업 (db.db + queue.db) |
| `modules/nixos/programs/docker/karakeep-notify.nix` | 웹훅->Pushover 브리지 (socat) |
| `modules/nixos/programs/docker/karakeep-log-monitor.nix` | OOM/크롤 실패 로그 감시 + 실패 URL 큐 적재 |
| `modules/nixos/programs/docker/karakeep-fallback-sync.nix` | fallback HTML -> Karakeep API 자동 재연결 |
| `modules/nixos/programs/docker/karakeep-singlefile-bridge.nix` | SingleFile API 분기 라우터 (크기 기준) |
| `modules/nixos/programs/karakeep-update/` | 버전 체크 + 수동 업데이트 |
| `modules/nixos/programs/caddy.nix` | HTTPS 리버스 프록시 (CSP 제거 포함) |

### 서비스 활성화/비활성화

```nix
# modules/nixos/configuration.nix
homeserver.karakeep.enable = true;                # 3컨테이너 앱 (포트 3000)
homeserver.karakeepBackup.enable = true;          # SQLite 매일 백업 (05:00)
homeserver.karakeepUpdate.enable = true;          # 버전 체크 + 업데이트 알림 (06:00)
homeserver.karakeepNotify.enable = true;          # 웹훅->Pushover 브리지
homeserver.karakeepLogMonitor.enable = true;      # OOM/크롤 실패 로그 감시
homeserver.karakeepFallbackSync.enable = true;    # fallback HTML 자동 재연결
homeserver.karakeepSinglefileBridge.enable = true; # SingleFile 대용량 분기 브리지
```

### Secrets (agenix)

| 시크릿 | 용도 |
|--------|------|
| `karakeep-nextauth-secret.age` | JWT 서명 키 (NEXTAUTH_SECRET) |
| `karakeep-meili-master-key.age` | Meilisearch 인증 키 |
| `karakeep-openai-key.age` | OpenAI API 키 (OPENAI_API_KEY) |
| `pushover-karakeep.age` | Pushover 알림 자격증명 |

## 핵심 절차

1. `karakeep.nix`로 3컨테이너/네트워크를 적용한다.
2. SingleFile 확장에서 REST Form API와 필수 field name(`file`, `url`)을 설정한다.
3. `karakeep-singlefile-bridge` 서비스가 active인지 확인한다.
4. 웹훅 브리지와 `CRAWLER_ALLOWED_INTERNAL_HOSTNAMES` 설정을 검증한다.
5. 백업 타이머와 업데이트 체크 타이머 상태를 확인한다.

### SingleFile Integration

브라우저 SingleFile 확장으로 페이지를 Karakeep에 push:

1. SingleFile 확장 -> Destinations -> "Upload to a REST Form API"
2. URL: `https://archive.greenhead.dev/api/v1/bookmarks/singlefile`
3. Token: Karakeep UI -> User Settings -> API Keys에서 발급
4. **archive data field name**: `file` (필수 -- 누락 시 ZodError)
5. **archive URL field name**: `url` (필수 -- 누락 시 ZodError)

Caddy가 `/api/v1/bookmarks/singlefile`만 `karakeep-singlefile-bridge`로 우회:
- **50MB 이하**: 기존 Karakeep SingleFile API로 그대로 전달
- **50MB 초과**: Karakeep `/api/v1/assets` 업로드 후 DB에 `fullPageArchive`로 직접 연결

### Webhook Notification

`karakeep-webhook-bridge.service` (socat TCP:9999):
- 웹훅은 Karakeep UI에서 사용자별로 설정 (Settings -> Webhooks)
- URL: `http://host.containers.internal:9999`, Events: crawled 등
- `CRAWLER_ALLOWED_INTERNAL_HOSTNAMES` 필수 (v0.30.0+ 내부 IP SSRF 차단)

### Fallback Auto Relink

`karakeep-log-monitor`가 실패 URL을 큐(`failed-urls.queue`)에 적재하면
`karakeep-fallback-sync` 타이머가 `/mnt/data/archive-fallback`의 HTML을 검사해
원본 URL을 추출하고 Karakeep SingleFile API로 자동 재연결한다.

### AI Tagging (OpenAI)

OpenAI 키가 있으면 inference worker가 자동 태깅/요약을 수행한다.
`INFERENCE_LANG=korean`, `INFERENCE_ENABLE_AUTO_SUMMARIZATION=true`.

## 자주 발생하는 문제

1. **CSS 렌더링 깨짐**: Caddy CSP 제거로 해결. 상세: [references/troubleshooting.md](references/troubleshooting.md) 항목 1
2. **SingleFile ZodError**: `file`, `url` field name 확인. 상세: [references/troubleshooting.md](references/troubleshooting.md) 항목 3
3. **컨테이너 OOM**: Meilisearch 최소 1GB 확보 필요. 상세: [references/troubleshooting.md](references/troubleshooting.md) 항목 4
4. **업데이트 후 로그 모니터 패턴 깨짐**: [references/update-guide.md](references/update-guide.md) 참조

## 참조

- 트러블슈팅 상세: [references/troubleshooting.md](references/troubleshooting.md)
- 업데이트 가이드: [references/update-guide.md](references/update-guide.md)
- CSS 이슈: https://github.com/karakeep-app/karakeep/issues/1977
