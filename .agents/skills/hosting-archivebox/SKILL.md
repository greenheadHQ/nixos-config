---
name: hosting-archivebox
description: |
  Use this skill when the user asks about ArchiveBox web archiver,
  webpage archiving, bookmark archiving, or archive.greenhead.dev.
  Triggers: "ArchiveBox", "아카이브박스", "웹 아카이브", "web archive",
  "archive.greenhead.dev", "아카이빙", "SingleFile", "singlefile",
  "archivebox-backup", "아카이브 백업".
  For container management see running-containers.
  For Caddy HTTPS see running-containers.
---

# ArchiveBox 웹 아카이버

headless Chromium + SingleFile로 서버 사이드에서 완전한 단일 HTML 아카이브를 생성합니다.

## 아키텍처

```
archive.greenhead.dev (Caddy HTTPS)
  └─ localhost:8000 (ArchiveBox)
       ├─ Django 웹앱 (포트 8000)
       ├─ headless Chromium (SingleFile, screenshot, PDF)
       └─ SQLite DB (index.sqlite3)
```

- **이미지**: `archivebox/archivebox:0.7.3` (안정 태그 고정)
- **DB**: SQLite + FTS5 전문 검색 (PostgreSQL/Sonic 불필요)
- **접속**: `https://archive.greenhead.dev` (Tailscale VPN 전용)

## 파일 구조

| 파일 | 역할 |
|------|------|
| `modules/nixos/programs/docker/archivebox.nix` | 컨테이너 정의 |
| `modules/nixos/programs/docker/archivebox-backup.nix` | SQLite 매일 백업 |
| `modules/nixos/options/homeserver.nix` | mkOption 정의 |
| `libraries/constants.nix` | 포트(8000), 리소스 제한, 서브도메인 |
| `secrets/archivebox-admin-password.age` | 관리자 비밀번호 |
| `secrets/pushover-archivebox.age` | 백업 실패 Pushover 알림 |

## 스토리지 레이아웃

| 경로 | 디스크 | 용도 |
|------|--------|------|
| `/var/lib/docker-data/archivebox/data/` | SSD | SQLite DB, config |
| `/mnt/data/archivebox/archive/` | HDD | 아카이브 파일 (HTML, PDF 등) |
| `/mnt/data/backups/archivebox/` | HDD | 매일 SQLite 백업 (30일 보존) |

SSD의 `/data`와 HDD의 `/data/archive`를 Docker 볼륨 오버마운트로 분리.

## 환경변수

| 변수 | 값 | 설명 |
|------|-----|------|
| `SEARCH_BACKEND_ENGINE` | `sqlite` | SQLite FTS5 전문 검색 |
| `ADMIN_USERNAME` | `admin` | 관리자 계정 |
| `ADMIN_PASSWORD` | (agenix) | environmentFiles로 주입 |
| `PUBLIC_INDEX` | `False` | 비공개 |
| `SAVE_ARCHIVE_DOT_ORG` | `False` | archive.org 제출 비활성화 |
| `MEDIA_MAX_SIZE` | `750m` | yt-dlp 최대 파일 크기 |

## 빠른 참조

```bash
# 컨테이너 상태
systemctl status podman-archivebox
podman logs archivebox

# 수동 백업
sudo systemctl start archivebox-backup

# URL 아카이빙 (CLI)
podman exec -it archivebox archivebox add 'https://example.com'

# 관리자 접속
# https://archive.greenhead.dev/admin/
```

## 자주 발생하는 문제

1. **첫 배포 후 로그인 안 됨**: `ADMIN_USERNAME`/`ADMIN_PASSWORD` 환경변수로 자동 생성. 컨테이너 로그에서 superuser 생성 확인
2. **아카이브 품질 낮음**: SingleFile가 JS 실행 후 캡처하므로 대부분 해결됨. 특수 SPA는 `--timeout` 조정
3. **디스크 공간 부족**: archive/ 디렉토리(HDD) 확인. `df -h /mnt/data`
4. **컨테이너 OOM**: constants.nix의 `archiveBox.memory` (기본 3g) 조정
