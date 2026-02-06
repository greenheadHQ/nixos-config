#!/bin/bash
# Immich 수동 업데이트 스크립트
# DB 백업 → 이미지 pull → 컨테이너 재시작 → 헬스체크 → 결과 알림
set -euo pipefail

# 환경변수 (systemd 또는 환경변수 파일에서 주입)
: "${IMMICH_URL:?IMMICH_URL is required}"
: "${API_KEY_FILE:?API_KEY_FILE is required}"
: "${PUSHOVER_CRED_FILE:?PUSHOVER_CRED_FILE is required}"
: "${BACKUP_DIR:?BACKUP_DIR is required}"

# API 키 로드 (IMMICH_API_KEY=... 형식)
# shellcheck disable=SC1090
source "$API_KEY_FILE"
API_KEY="$IMMICH_API_KEY"

# Pushover credentials 로드
# shellcheck disable=SC1090
source "$PUSHOVER_CRED_FILE"

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  echo "=== DRY RUN MODE ==="
fi

# Pushover 알림 전송 함수
send_notification() {
  local title="$1"
  local message="$2"
  local priority="${3:-"0"}"

  curl -sf --proto =https --max-time 10 \
    --form-string "token=${PUSHOVER_TOKEN}" \
    --form-string "user=${PUSHOVER_USER}" \
    --form-string "title=${title}" \
    --form-string "message=${message}" \
    --form-string "priority=${priority}" \
    https://api.pushover.net/1/messages.json > /dev/null 2>&1 || true
}

# 에러 발생 시 알림 전송
trap 'send_notification "Immich Update" "업데이트 실패: 스크립트 오류 발생" 1' ERR

# ─── 0. 현재 버전 확인 ──────────────────────────────────────────
echo "=== Immich Update ==="
CURRENT_RESPONSE=$(curl -sf --max-time 15 \
  -H "x-api-key: $API_KEY" \
  "$IMMICH_URL/api/server/version") || {
  echo "WARNING: Cannot get current version (Immich may be down)"
  CURRENT_RESPONSE=""
}

if [ -n "$CURRENT_RESPONSE" ]; then
  CURRENT_VERSION=$(echo "$CURRENT_RESPONSE" | jq -r '"\(.major).\(.minor).\(.patch)"')
  echo "Current version: v$CURRENT_VERSION"
else
  CURRENT_VERSION="unknown"
  echo "Current version: unknown"
fi

# ─── 1. postgres 컨테이너 상태 확인 ─────────────────────────────
echo ""
echo "Checking postgres container..."
if ! podman container inspect immich-postgres --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
  echo "ERROR: immich-postgres is not running"
  send_notification "Immich Update" "업데이트 실패: PostgreSQL 컨테이너가 실행되지 않음" 1
  exit 1
fi
echo "postgres: running"

if $DRY_RUN; then
  echo ""
  echo "=== Dry Run Summary ==="
  echo "Current version: v$CURRENT_VERSION"
  echo "Containers: immich-postgres (running)"
  echo ""
  echo "Would perform:"
  echo "  1. DB backup to $BACKUP_DIR/"
  echo "  2. Pull ghcr.io/immich-app/immich-server:release"
  echo "  3. Pull ghcr.io/immich-app/immich-machine-learning:release"
  echo "  4. Stop immich-server, immich-ml"
  echo "  5. Start immich-ml, immich-server"
  echo "  6. Health check (60 retries, 10s interval)"
  echo "  7. Notify via Pushover"
  echo ""
  echo "Run without --dry-run to execute."
  exit 0
fi

# ─── 2. DB 백업 ─────────────────────────────────────────────────
echo ""
echo "Backing up database..."
umask 077
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="$BACKUP_DIR/backup-${TIMESTAMP}.sql.gz"

podman exec immich-postgres pg_dump -U immich immich | gzip > "$BACKUP_FILE"

# 백업 무결성 검증
if ! gzip -t "$BACKUP_FILE" 2>/dev/null; then
  echo "ERROR: Backup file is corrupted"
  send_notification "Immich Update" "업데이트 중단: DB 백업 파일 손상" 1
  exit 1
fi

BACKUP_SIZE=$(stat -c%s "$BACKUP_FILE")
if [ "$BACKUP_SIZE" -eq 0 ]; then
  echo "ERROR: Backup file is empty"
  send_notification "Immich Update" "업데이트 중단: DB 백업이 비어있음" 1
  exit 1
fi

echo "Backup saved: $BACKUP_FILE ($(numfmt --to=iec "$BACKUP_SIZE"))"

# ─── 3. 이미지 pull ─────────────────────────────────────────────
echo ""
echo "Pulling latest images..."
podman pull ghcr.io/immich-app/immich-server:release
podman pull ghcr.io/immich-app/immich-machine-learning:release
echo "Images pulled"

# ─── 4. 컨테이너 재시작 (stop all → start ML → start Server) ────
echo ""
echo "Restarting containers..."
echo "Stopping immich-server..."
systemctl stop podman-immich-server.service
echo "Stopping immich-ml..."
systemctl stop podman-immich-ml.service

echo "Starting immich-ml..."
systemctl start podman-immich-ml.service
echo "Starting immich-server..."
systemctl start podman-immich-server.service
echo "Containers restarted"

# ─── 5. 헬스체크 ────────────────────────────────────────────────
echo ""
echo "Running health check..."
MAX_RETRIES=60
RETRY_INTERVAL=10
HEALTHY=false

for i in $(seq 1 $MAX_RETRIES); do
  if VERSION_RESPONSE=$(curl -sf --max-time 10 \
    -H "x-api-key: $API_KEY" \
    "$IMMICH_URL/api/server/version" 2>/dev/null); then
    NEW_VERSION=$(echo "$VERSION_RESPONSE" | jq -r '"\(.major).\(.minor).\(.patch)"')
    echo "Health check passed (attempt $i/$MAX_RETRIES) - version: v$NEW_VERSION"
    HEALTHY=true
    break
  fi
  echo "Waiting for Immich to start... ($i/$MAX_RETRIES)"
  sleep "$RETRY_INTERVAL"
done

# ─── 6. 결과 알림 ───────────────────────────────────────────────
echo ""
if $HEALTHY; then
  echo "=== Update completed successfully ==="
  echo "Version: v$CURRENT_VERSION → v$NEW_VERSION"
  send_notification "Immich Update" "업데이트 완료: v${CURRENT_VERSION} → v${NEW_VERSION}" 0
else
  echo "=== Health check failed ==="
  echo "Immich did not respond after $((MAX_RETRIES * RETRY_INTERVAL / 60)) minutes"
  echo "Check logs: journalctl -u podman-immich-server -f"
  send_notification "Immich Update" "헬스체크 실패: v${CURRENT_VERSION}에서 업데이트 후 응답 없음. 로그 확인 필요" 1
  exit 1
fi

# ─── 7. 오래된 백업 정리 ────────────────────────────────────────
echo ""
echo "Cleaning up old backups..."
DELETED_COUNT=0
while IFS= read -r old_backup; do
  if [ -n "$old_backup" ]; then
    rm -f "$old_backup"
    DELETED_COUNT=$((DELETED_COUNT + 1))
  fi
done < <(find "$BACKUP_DIR" -name "backup-*.sql.gz" -mtime +7 2>/dev/null)

if [ "$DELETED_COUNT" -gt 0 ]; then
  echo "Deleted $DELETED_COUNT old backup(s)"
else
  echo "No old backups to clean up"
fi
