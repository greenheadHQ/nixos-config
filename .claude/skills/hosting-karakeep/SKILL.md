---
name: hosting-karakeep
description: |
  Karakeep web archiver/bookmark manager: 3-container setup, SingleFile integration, webhooks.
  Triggers: "Karakeep", "웹 아카이브", "archive.greenhead.dev", "북마크", "아카이빙".
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
| `sudo karakeep-update` | 수동 업데이트 |
| `journalctl -u karakeep-webhook-bridge -f` | 웹훅 브리지 로그 확인 |

## Architecture

3컨테이너 Podman 구성 (`karakeep-network`):

| 컨테이너 | 이미지 | 역할 | 리소스 |
|-----------|--------|------|--------|
| `karakeep` | `ghcr.io/karakeep-app/karakeep:release` | Next.js 앱 (포트 3000) | 1.5GB / 1 CPU |
| `karakeep-chrome` | `gcr.io/zenika-hub/alpine-chrome:124` | 헤드리스 Chrome (스크린샷) | 1GB / 1 CPU |
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
| `modules/nixos/programs/docker/karakeep-notify.nix` | 웹훅→Pushover 브리지 (socat) |
| `modules/nixos/programs/karakeep-update/` | 버전 체크 + 수동 업데이트 |
| `modules/nixos/programs/caddy.nix` | HTTPS 리버스 프록시 (CSP 제거 포함) |

### Secrets (agenix)

| 시크릿 | 용도 |
|--------|------|
| `karakeep-nextauth-secret.age` | JWT 서명 키 (NEXTAUTH_SECRET) |
| `karakeep-meili-master-key.age` | Meilisearch 인증 키 |
| `karakeep-openai-key.age` | OpenAI API 키 (OPENAI_API_KEY) |
| `pushover-karakeep.age` | Pushover 알림 자격증명 |

## SingleFile Integration

브라우저 SingleFile 확장으로 페이지를 Karakeep에 push:

1. SingleFile 확장 → Destinations → "Upload to a REST Form API"
2. URL: `https://archive.greenhead.dev/api/v1/bookmarks/singlefile`
3. Token: Karakeep UI → User Settings → API Keys에서 발급
4. **archive data field name**: `file` (필수 — 누락 시 ZodError)
5. **archive URL field name**: `url` (필수 — 누락 시 ZodError)

## 핵심 절차

1. `karakeep.nix`로 3컨테이너/네트워크를 적용한다.
2. SingleFile 확장에서 REST Form API와 필수 field name(`file`, `url`)을 설정한다.
3. 웹훅 브리지와 `CRAWLER_ALLOWED_INTERNAL_HOSTNAMES` 설정을 검증한다.
4. 백업 타이머와 업데이트 체크 타이머 상태를 확인한다.

## AI Tagging + Summarization (OpenAI)

OpenAI 키가 있으면 Karakeep inference worker가 자동 태깅/요약을 수행한다.

- 필수 시크릿 파일: `secrets/karakeep-openai-key.age`
- 시크릿 내용 형식:
  ```text
  OPENAI_API_KEY=sk-...
  ```
- 현재 운영 기본값:
  - `INFERENCE_LANG=korean`
  - `INFERENCE_ENABLE_AUTO_SUMMARIZATION=true`
  - `INFERENCE_TEXT_MODEL`/`INFERENCE_IMAGE_MODEL`은 Karakeep 기본값 사용

적용 및 확인:

```bash
# 설정 적용
nrs

# 컨테이너/환경 파일 재기동
sudo systemctl restart karakeep-env.service karakeep-openai-env.service podman-karakeep.service

# 서비스 상태 확인
sudo systemctl status karakeep-env.service karakeep-openai-env.service podman-karakeep.service --no-pager

# OPENAI_API_KEY 주입 확인 (값 노출 없이 키 존재만 체크)
sudo podman exec karakeep /bin/sh -lc 'printenv OPENAI_API_KEY >/dev/null && echo OPENAI_API_KEY=loaded'
```

기능 검증:

1. Karakeep에 새 북마크 저장
2. 태그가 한국어로 자동 생성되는지 확인
3. 요약(summary)이 자동 생성되는지 확인

## Webhook Notification

`karakeep-webhook-bridge.service` (socat TCP:9999):
- **웹훅은 Karakeep UI에서 사용자별로 설정** (Settings → Webhooks)
  - URL: `http://host.containers.internal:9999`
  - Events: 원하는 이벤트 선택 (crawled 등)
- `crawled` 이벤트만 Pushover로 전달
- `CRAWLER_ALLOWED_INTERNAL_HOSTNAMES` 필수 (v0.30.0+ 내부 IP SSRF 차단)
- NixOS 방화벽: `podman+` 인터페이스에서 웹훅 포트 허용 필요 (`karakeep-notify.nix`)

## Backup & Update

- **백업**: `sudo systemctl start karakeep-backup` (매일 05:00 자동)
- **업데이트**: `sudo karakeep-update` (수동), `karakeep-version-check` (매일 06:00 자동)

### Restore

```bash
# 1. 서비스 중지
sudo systemctl stop podman-karakeep.service

# 2. 백업에서 DB 복원
sudo gunzip -k /mnt/data/backups/karakeep/YYYY-MM-DD/db.db.gz
sudo cp /mnt/data/backups/karakeep/YYYY-MM-DD/db.db /mnt/data/karakeep/db.db
sudo gunzip -k /mnt/data/backups/karakeep/YYYY-MM-DD/queue.db.gz
sudo cp /mnt/data/backups/karakeep/YYYY-MM-DD/queue.db /mnt/data/karakeep/queue.db

# 3. 서비스 재시작
sudo systemctl start podman-karakeep.service
```

## 트러블슈팅

### CSS 렌더링 깨짐 (아카이브 인라인 뷰)

Karakeep의 CSP 헤더가 iframe 내 CSS를 차단하는 알려진 버그.
Caddy에서 CSP 제거로 해결 (`caddy.nix` — `header -Content-Security-Policy`).
Tailscale VPN 전용이므로 XSS 위험 무시 가능.
ref: https://github.com/karakeep-app/karakeep/issues/1977

### 웹훅 전달 실패

v0.30.0+에서 내부 IP 웹훅 기본 차단.
`CRAWLER_ALLOWED_INTERNAL_HOSTNAMES=host.containers.internal` 확인.
```bash
journalctl -u karakeep-webhook-bridge -f
```

### SingleFile ZodError (field name 누락)

SingleFile 확장에서 push 시 아래 에러 발생:
```
{"success":false,"error":{"issues":[{"code":"invalid_type","expected":"string","received":"undefined","path":["url"],"message":"Required"},{"code":"custom","message":"Input not instance of File","fatal":true,"path":["file"]}],"name":"ZodError"}}
```
**원인**: SingleFile 확장 설정에서 `archive data field name`, `archive URL field name` 필드가 비어있음.
**해결**: 각각 `file`, `url`을 입력. 이 필드들은 SingleFile 확장이 기본값을 제공하지 않으므로 반드시 수동 입력 필요.

### 컨테이너 OOM

리소스 제한: `libraries/constants.nix` → `constants.containers.karakeep`
```bash
podman stats --no-stream karakeep karakeep-chrome karakeep-meilisearch
```

**Meilisearch 메모리 기준**: 안정 시 ~365MB 사용.
512MB 제한에서 OOM 크래시 루프 발생 (98% 점유로 반복 kill).
**최소 1GB 확보 필요** — Meilisearch가 죽으면 Karakeep 앱도 의존성 실패로 502 발생.

### AI 태깅/요약 미동작

점검 순서:

1. `karakeep-openai-key.age`가 실제 키로 갱신되었는지 확인 (placeholder 금지)
2. `karakeep-env.service`, `karakeep-openai-env.service` 실행 성공 여부 확인
3. Karakeep 컨테이너 로그에서 OpenAI 요청 오류(401/429/timeout) 확인

```bash
sudo systemctl status karakeep-env.service karakeep-openai-env.service --no-pager
sudo podman logs --tail=200 karakeep
journalctl -u podman-karakeep.service -n 200 --no-pager
```

### 모바일 앱 (iOS/Android)

- App Store: "Karakeep" 검색
- 서버 URL: `https://archive.greenhead.dev`
- 인라인 아카이브 뷰에서 CSS 깨짐은 웹과 동일 (CSP 제거로 해결)

## 참조

- CSS 이슈: https://github.com/karakeep-app/karakeep/issues/1977
