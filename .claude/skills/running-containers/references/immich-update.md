# Immich 버전 체크 및 업데이트 가이드

## 개요

`homeserver.immichUpdate.enable = true`로 활성화되는 자동화 시스템:
- 매일 03:00 GitHub Releases API로 최신 버전 체크 → 새 버전 시 Pushover 알림
- `sudo immich-update` 명령으로 안전한 수동 업데이트

## 파일 구조

| 파일 | 역할 |
|------|------|
| `modules/nixos/programs/immich-update/default.nix` | NixOS 모듈 (systemd 서비스/타이머) |
| `modules/nixos/programs/immich-update/files/version-check.sh` | Immich 전용 버전 체크 (Immich API 사용) |
| `modules/nixos/programs/immich-update/files/update-script.sh` | 수동 업데이트 |
| `modules/nixos/lib/service-lib.sh` | 공통 함수 (send_notification, fetch_github_release 등) |
| `modules/nixos/lib/service-lib.nix` | service-lib.sh Nix wrapper |
| `modules/nixos/lib/mk-update-module.nix` | 업데이트 모듈 생성 헬퍼 (copyparty, uptime-kuma, archivebox용) |

> Immich는 API로 현재 버전을 확인하는 고유 로직이 있어 `mk-update-module.nix`를 사용하지 않고 독자 구현.
> Copyparty, Uptime Kuma, ArchiveBox는 `mk-update-module.nix` + `generic-version-check.sh` 사용.
> 통합 시스템 상세: [service-update-system.md](service-update-system.md)

## API 접근 URL

버전 체크 및 업데이트 스크립트는 `http://127.0.0.1:2283`으로 Immich API에 접근합니다.
Immich 서버가 `127.0.0.1`에만 바인딩되어 있으므로, Tailscale IP로는 직접 접근할 수 없습니다.
외부(macOS 등)에서 접근할 때는 Caddy 리버스 프록시(`https://immich.greenhead.dev`)를 사용합니다.

## 버전 체크 스크립트 동작

### API 호출

1. **현재 버전**: Immich API `/api/server/version` → `{"major":2,"minor":5,"patch":5}` → `"2.5.5"` 변환
2. **최신 버전**: GitHub `repos/immich-app/immich/releases/latest` → `"tag_name": "v2.5.5"` → `"2.5.5"` 변환

### 상태 관리

- `/var/lib/immich-update/last-notified-version`: 마지막 알림 버전 기록
- `/var/lib/immich-update/last-success`: 마지막 성공 시각 (Unix timestamp) — 워치독용
- 초기 실행 시: 현재 버전을 기록하고 종료 (불필요한 알림 방지)
- 이미 알린 버전은 재알림하지 않음
- 3일 이상 성공 없으면 Pushover 경고 알림 (장기 실패 워치독)

### 에러 처리

- GitHub API rate limit (429) / 타임아웃 → `exit 0` (다음 실행에 재시도)
- Immich API 연결 실패 → `exit 0`
- Pushover 전송 실패 → 무시 (알림은 best-effort)

## 업데이트 스크립트 플로우

```
[동시 실행 방지] flock으로 lockfile 확보
    ↓
[상태 확인] postgres 컨테이너 running 여부
    ↓
[DB 백업] pg_dump | gzip → /var/lib/immich-update/backups/
    ↓
[무결성 검증] gzip -t + 최소 크기(1KB) 확인
    ↓
[이미지 Pull] immich-server:release + immich-ml:release
    ↓
[재시작] stop server → stop ml → start ml → start server
    ↓
[헬스체크] /api/server/version (60회, 10초 간격 = 최대 10분)
    ↓
[ML 상태 확인] immich-ml 컨테이너 running 여부 (경고 알림)
    ↓
[알림] 성공/실패 Pushover 전송
    ↓
[정리] 7일 이상 된 백업 삭제
```

### --dry-run 모드

`sudo immich-update --dry-run`으로 실제 변경 없이 상태 확인:
- 현재 버전 출력
- postgres 컨테이너 상태 확인
- 수행할 작업 목록 출력

## DB 백업/복원

### 백업 위치

```
/var/lib/immich-update/backups/
├── backup-20260206-030000.sql.gz
├── backup-20260207-030000.sql.gz
└── ...
```

### 수동 복원

```bash
# 1. Immich 서비스 중지
sudo systemctl stop podman-immich-server.service

# 2. 백업 복원
gunzip -c /var/lib/immich-update/backups/backup-YYYYMMDD-HHMMSS.sql.gz | \
  sudo podman exec -i immich-postgres psql -U immich -d immich

# 3. 서비스 재시작
sudo systemctl start podman-immich-server.service
```

## 트러블슈팅

### GitHub API rate limit

**증상**: 버전 체크가 조용히 실패 (로그에 "GitHub API request failed")

**원인**: 비인증 요청 60회/시간 제한

**해결**: 1일 1회 체크이므로 일반적으로 문제 없음. 다른 서비스가 같은 IP에서 GitHub API를 대량 호출하는지 확인

### 헬스체크 실패

**증상**: "Immich did not respond after 10 minutes"

**원인**:
- DB 마이그레이션이 10분 이상 소요 (대규모 업데이트)
- 컨테이너 시작 실패

**해결**:
```bash
# 로그 확인
sudo podman logs immich-server
sudo podman logs immich-ml
journalctl -u podman-immich-server -f

# 수동 재시작
sudo systemctl restart podman-immich-server.service
```

### Pushover 알림 미전송

**증상**: 새 버전이 있지만 알림이 오지 않음

**확인**:
```bash
# 수동 실행하여 로그 확인
sudo systemctl start immich-version-check
journalctl -u immich-version-check --no-pager

# 시크릿 파일 존재 확인
ls -la /run/agenix/immich-api-key /run/agenix/pushover-immich
```

### 초기 실행 후 알림 없음

**원인**: 정상 동작. 첫 실행 시 현재 버전을 기록만 하고 알림을 보내지 않음.

**확인**:
```bash
cat /var/lib/immich-update/last-notified-version
```

### 워치독 경고 수신

**증상**: "버전 체크가 N일간 성공하지 못했습니다" Pushover 알림

**원인**:
- Immich 서비스가 장기간 다운
- GitHub API가 지속적으로 실패
- 네트워크 문제

**확인**:
```bash
# 마지막 성공 시각 확인
sudo cat /var/lib/immich-update/last-success
# → Unix timestamp (예: 1770373041)

# 수동 실행하여 원인 확인
sudo systemctl start immich-version-check
journalctl -u immich-version-check --no-pager
```

### 동시 실행 차단

**증상**: "Another immich-update is already running"

**원인**: `sudo immich-update`가 이미 다른 터미널에서 실행 중

**해결**: 기존 프로세스 완료 대기 또는 `ps aux | grep immich-update`로 확인

### 타이머 미동작

```bash
# 타이머 상태 확인
systemctl list-timers | grep immich-version-check

# 타이머 활성화 확인
systemctl status immich-version-check.timer

# 수동 트리거
sudo systemctl start immich-version-check
```
