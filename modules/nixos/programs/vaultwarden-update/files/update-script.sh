#!/bin/bash
# Vaultwarden 수동 업데이트 스크립트
# pinned tag 이미지 pull → digest 비교 → 안전 백업 → 재시작 → 헬스체크 → 결과 알림
set -euo pipefail

# 환경변수 (래퍼에서 주입)
: "${PUSHOVER_CRED_FILE:?PUSHOVER_CRED_FILE is required}"
: "${SERVICE_LIB:?SERVICE_LIB is required}"
: "${STATE_DIR:?STATE_DIR is required}"
: "${CONTAINER_NAME:?CONTAINER_NAME is required}"
: "${CONTAINER_IMAGE:?CONTAINER_IMAGE is required}"
: "${SERVICE_UNIT:?SERVICE_UNIT is required}"
: "${HEALTH_URL:?HEALTH_URL is required}"
: "${BACKUP_SERVICE:?BACKUP_SERVICE is required}"
: "${GITHUB_REPO:?GITHUB_REPO is required}"
: "${SERVICE_DISPLAY_NAME:?SERVICE_DISPLAY_NAME is required}"

# 동시 실행 방지 (flock)
exec 200>"$STATE_DIR/.lock"
flock -n 200 || { echo "ERROR: Another vaultwarden-update is already running"; exit 1; }

# 공통 라이브러리 로드
# shellcheck disable=SC1090
source "$SERVICE_LIB"

# Pushover credentials 로드
# shellcheck disable=SC1090
source "$PUSHOVER_CRED_FILE"

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  echo "=== DRY RUN MODE ==="
elif [[ -n "${1:-}" ]]; then
  echo "ERROR: Unknown argument: $1"
  echo "Usage: vaultwarden-update [--dry-run]"
  exit 1
fi

FAILURE_NOTIFIED=false

# ERR trap — 컨테이너 자동 복구
cleanup() {
  local recovery_msg=""
  if ! podman container inspect "$CONTAINER_NAME" --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
    echo "Restarting container after failure..."
    if systemctl start "$SERVICE_UNIT" 2>/dev/null; then
      recovery_msg=" 컨테이너 자동 복구 완료."
    else
      recovery_msg=" 컨테이너 자동 복구 실패! 수동 확인 필요."
    fi
  fi
  if $FAILURE_NOTIFIED; then
    return 0
  fi

  send_notification "$SERVICE_DISPLAY_NAME Update" "업데이트 실패: 스크립트 오류 발생.${recovery_msg}" 1
}
trap cleanup ERR

# ─── 0. 현재 이미지 digest 저장 + 최신 버전 조회 ─────────────────
echo "=== $SERVICE_DISPLAY_NAME Update ==="
CURRENT_DIGEST=$(get_image_digest "$CONTAINER_NAME")
echo "Current image digest: ${CURRENT_DIGEST:0:20}..."

CURRENT_TAG="${CONTAINER_IMAGE##*:}"
fetch_github_release "$GITHUB_REPO"
LATEST_VERSION="${GITHUB_LATEST_VERSION:-}"

if $DRY_RUN; then
  echo ""
  echo "=== Dry Run Summary ==="
  echo "Container: $CONTAINER_NAME"
  echo "Image: $CONTAINER_IMAGE"
  if [ -n "$LATEST_VERSION" ]; then
    echo "GitHub latest: v$LATEST_VERSION"
  fi
  echo ""
  echo "Would perform:"
  echo "  1. Pull $CONTAINER_IMAGE"
  echo "  2. Compare image digest (skip restart if unchanged)"
  echo "  3. Start $BACKUP_SERVICE"
  echo "  4. Stop $SERVICE_UNIT"
  echo "  5. Start $SERVICE_UNIT"
  echo "  6. Health check ($HEALTH_URL)"
  echo "  7. Notify via Pushover"
  echo ""
  echo "Run without --dry-run to execute."
  exit 0
fi

# ─── 1. 이미지 pull (컨테이너 실행 중, 다운타임 없음) ────────────
echo ""
echo "Pulling configured image tag..."
podman pull "$CONTAINER_IMAGE"
echo "Image pulled"

# ─── 2. 새 이미지 digest 비교 ───────────────────────────────────
NEW_IMAGE_DIGEST=$(podman image inspect "$CONTAINER_IMAGE" --format '{{.Id}}' 2>/dev/null || echo "")
if [ -n "$CURRENT_DIGEST" ] && [ "$CURRENT_DIGEST" = "$NEW_IMAGE_DIGEST" ]; then
  echo "Image unchanged (already up-to-date for pinned tag :$CURRENT_TAG)."
  if [ -n "$LATEST_VERSION" ] && [ "$CURRENT_TAG" != "$LATEST_VERSION" ]; then
    echo "NOTE: GitHub latest is v$LATEST_VERSION. Current pinned tag is :$CURRENT_TAG."
    echo "Update modules/nixos/programs/docker/vaultwarden.nix tag, then run nrs."
  fi
  echo "=== No update needed ==="
  exit 0
fi
echo "New image detected, proceeding with update..."

# ─── 3. 안전 백업 실행 ──────────────────────────────────────────
echo ""
echo "Running backup service: $BACKUP_SERVICE"
if ! systemctl start "$BACKUP_SERVICE"; then
  # oneshot 백업이 이미 실행 중인 경우 start가 비정상 종료될 수 있음
  if systemctl is-active --quiet "$BACKUP_SERVICE"; then
    echo "Backup service is already running; waiting for completion..."
    WAIT_RETRIES=90   # 최대 15분(90*10초)
    WAIT_INTERVAL=10
    BACKUP_DONE=false
    for _ in $(seq 1 "$WAIT_RETRIES"); do
      if ! systemctl is-active --quiet "$BACKUP_SERVICE"; then
        BACKUP_DONE=true
        break
      fi
      sleep "$WAIT_INTERVAL"
    done

    if ! $BACKUP_DONE; then
      echo "ERROR: Backup service did not finish within timeout"
      FAILURE_NOTIFIED=true
      send_notification "$SERVICE_DISPLAY_NAME Update" "업데이트 중단: 백업 서비스 대기 시간 초과 (15분)" 1
      exit 1
    fi
    echo "Backup service completed; proceeding."
  else
    echo "ERROR: Backup service failed"
    FAILURE_NOTIFIED=true
    send_notification "$SERVICE_DISPLAY_NAME Update" "업데이트 중단: 백업 서비스 실행 실패" 1
    exit 1
  fi
fi

# ─── 4. 컨테이너 재시작 ─────────────────────────────────────────
echo ""
echo "Stopping $SERVICE_UNIT..."
systemctl stop "$SERVICE_UNIT"
echo "Starting $SERVICE_UNIT..."
systemctl start "$SERVICE_UNIT"
echo "Container restarted"

# ─── 5. 헬스체크 ────────────────────────────────────────────────
echo ""
if ! http_health_check "$HEALTH_URL" 30 10; then
  echo "=== Health check failed ==="
  FAILURE_NOTIFIED=true
  send_notification "$SERVICE_DISPLAY_NAME Update" "헬스체크 실패: 업데이트 후 응답 없음. 로그 확인 필요" 1
  exit 1
fi

# ─── 6. 결과 알림 ───────────────────────────────────────────────
echo ""
VERSION_INFO="pinned tag :${CURRENT_TAG}"
if [ -n "$LATEST_VERSION" ] && [ "$CURRENT_TAG" != "$LATEST_VERSION" ]; then
  VERSION_INFO="${VERSION_INFO} (GitHub latest: v${LATEST_VERSION})"
fi
echo "=== Update completed successfully ==="
send_notification "$SERVICE_DISPLAY_NAME Update" "업데이트 완료: ${VERSION_INFO} 적용됨" 0
