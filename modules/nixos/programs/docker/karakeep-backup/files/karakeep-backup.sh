#!/usr/bin/env bash
# shellcheck shell=bash

# service-lib.sh 로드 (send_notification 사용)
# shellcheck source=/dev/null
source "$PUSHOVER_CRED_FILE"
# shellcheck source=/dev/null
source "$SERVICE_LIB"

# 에러 핸들러: 실패 시 Pushover 알림
cleanup_on_error() {
  local exit_code=$?
  if [ $exit_code -ne 0 ]; then
    send_notification "Karakeep Backup" \
      "백업 실패 (exit $exit_code). journalctl -u karakeep-backup 확인 필요." 1
  fi
}
trap cleanup_on_error EXIT

echo "=== Karakeep backup start: $(date -Iseconds) ==="

# 소스 DB 확인
DB_FILE="$SRC_DIR/db.db"
QUEUE_DB_FILE="$SRC_DIR/queue.db"
if [ ! -f "$DB_FILE" ]; then
  echo "ERROR: Database not found at $DB_FILE" >&2
  exit 1
fi

# 날짜별 백업 디렉토리
DATED_DIR="$BACKUP_DIR/$(date +%Y-%m-%d)"
mkdir -p "$DATED_DIR"

# SQLite DB 안전 백업 (.backup 명령은 WAL 모드에서도 일관성 보장)
sqlite3 "$DB_FILE" ".backup '$DATED_DIR/db.db.tmp'"
mv "$DATED_DIR/db.db.tmp" "$DATED_DIR/db.db"
gzip -f "$DATED_DIR/db.db"

# 무결성 검증
if ! gunzip -t "$DATED_DIR/db.db.gz"; then
  echo "ERROR: db.db backup integrity check failed" >&2
  exit 1
fi
echo "Main DB backup completed: $DATED_DIR/db.db.gz"

# queue.db 백업 (존재하는 경우에만)
if [ -f "$QUEUE_DB_FILE" ]; then
  sqlite3 "$QUEUE_DB_FILE" ".backup '$DATED_DIR/queue.db.tmp'"
  mv "$DATED_DIR/queue.db.tmp" "$DATED_DIR/queue.db"
  gzip -f "$DATED_DIR/queue.db"
  if ! gunzip -t "$DATED_DIR/queue.db.gz"; then
    echo "ERROR: queue.db backup integrity check failed" >&2
    exit 1
  fi
  echo "Queue DB backup completed: $DATED_DIR/queue.db.gz"
fi

# 보관 정리 (retentionDays 초과 백업 삭제)
DELETED=$(find "$BACKUP_DIR" -maxdepth 1 -type d -name "20*" -mtime +"$RETENTION_DAYS" -print | wc -l)
find "$BACKUP_DIR" -maxdepth 1 -type d -name "20*" -mtime +"$RETENTION_DAYS" -exec rm -rf {} +
if [ "$DELETED" -gt 0 ]; then
  echo "Cleaned up $DELETED old backups (>${RETENTION_DAYS} days)"
fi

echo "=== Karakeep backup completed: $(date -Iseconds) ==="
