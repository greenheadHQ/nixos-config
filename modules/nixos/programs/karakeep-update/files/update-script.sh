#!/bin/bash
# Karakeep 수동 업데이트 스크립트
# 이미지 pull → digest 비교 → 컨테이너 재시작 → 헬스체크 → 결과 알림
set -euo pipefail

# 환경변수 (래퍼에서 주입)
: "${PUSHOVER_CRED_FILE:?PUSHOVER_CRED_FILE is required}"
: "${SERVICE_LIB:?SERVICE_LIB is required}"
: "${STATE_DIR:?STATE_DIR is required}"
: "${CONTAINER_NAME:?CONTAINER_NAME is required}"
: "${CONTAINER_IMAGE:?CONTAINER_IMAGE is required}"
: "${SERVICE_UNIT:?SERVICE_UNIT is required}"
: "${HEALTH_URL:?HEALTH_URL is required}"
: "${GITHUB_REPO:?GITHUB_REPO is required}"
: "${SERVICE_DISPLAY_NAME:?SERVICE_DISPLAY_NAME is required}"

# 공통 라이브러리 로드
# shellcheck disable=SC1090
source "$SERVICE_LIB"

# Pushover credentials 로드
# shellcheck disable=SC1090
source "$PUSHOVER_CRED_FILE"

usage() {
  cat <<'EOF'
Usage: karakeep-update [--dry-run] [--ack-bridge-risk]

  --dry-run            수행 예정 단계만 출력
  --ack-bridge-risk    Karakeep 내부 동작/로그 형식 변경 시 브릿지 장애 위험을 인지하고 실행
EOF
}

print_bridge_risk_notice() {
  cat >&2 <<'EOF'
[Bridge Guardrail Notice]
Karakeep 업데이트는 아래 브릿지 체인을 깨뜨릴 수 있습니다.
  1) karakeep-log-monitor (로그 패턴 기반 실패 URL 추적)
  2) karakeep-fallback-sync (실패 URL 매칭 후 자동 재연결)
  3) karakeep-singlefile-bridge (fullPageArchive 직접 연결)

업데이트 후 필수 점검:
  - systemctl status karakeep-log-monitor karakeep-fallback-sync.timer karakeep-singlefile-bridge --no-pager
  - journalctl -u karakeep-log-monitor -n 50 --no-pager
  - journalctl -u karakeep-fallback-sync -n 50 --no-pager
  - journalctl -u karakeep-singlefile-bridge -n 50 --no-pager
EOF
}

check_bridge_guard_services() {
  local unit failed
  failed=0
  for unit in karakeep-log-monitor.service karakeep-fallback-sync.timer karakeep-singlefile-bridge.service; do
    if systemctl is-enabled --quiet "$unit" 2>/dev/null && ! systemctl is-active --quiet "$unit"; then
      echo "WARNING: $unit is enabled but not active"
      failed=1
    fi
  done
  return "$failed"
}

DRY_RUN=false
ACK_BRIDGE_RISK=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      ;;
    --ack-bridge-risk)
      ACK_BRIDGE_RISK=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown option: $1"
      usage
      exit 2
      ;;
  esac
  shift
done

if ! $DRY_RUN && ! $ACK_BRIDGE_RISK; then
  print_bridge_risk_notice
  echo "ERROR: karakeep-update requires --ack-bridge-risk"
  echo "Example: sudo karakeep-update --ack-bridge-risk"
  exit 2
fi

# 동시 실행 방지 (flock)
exec 200>"$STATE_DIR/.lock"
flock -n 200 || { echo "ERROR: Another karakeep-update is already running"; exit 1; }

if $DRY_RUN; then
  echo "=== DRY RUN MODE ==="
fi

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
  send_notification "$SERVICE_DISPLAY_NAME Update" "업데이트 실패: 스크립트 오류 발생.${recovery_msg}" 1
}
trap cleanup ERR

# ─── 0. 현재 이미지 digest 저장 ──────────────────────────────────
echo "=== $SERVICE_DISPLAY_NAME Update ==="
CURRENT_DIGEST=$(get_image_digest "$CONTAINER_NAME")
echo "Current image digest: ${CURRENT_DIGEST:0:20}..."

if $DRY_RUN; then
  echo ""
  echo "=== Dry Run Summary ==="
  echo "Container: $CONTAINER_NAME"
  echo "Image: $CONTAINER_IMAGE"
  echo ""
  echo "Would perform:"
  echo "  1. Pull $CONTAINER_IMAGE"
  echo "  2. Compare image digest (skip restart if unchanged)"
  echo "  3. Stop $SERVICE_UNIT"
  echo "  4. Start $SERVICE_UNIT"
  echo "  5. Health check ($HEALTH_URL/api/health)"
  echo "  6. Bridge guardrail service status check"
  echo "  7. Notify via Pushover"
  echo ""
  echo "Run without --dry-run to execute."
  echo "Real run command: sudo karakeep-update --ack-bridge-risk"
  exit 0
fi

# ─── 1. 이미지 pull (컨테이너 실행 중, 다운타임 없음) ────────────
echo ""
echo "Pulling latest image..."
podman pull "$CONTAINER_IMAGE"
echo "Image pulled"

# ─── 2. 새 이미지 digest 비교 ───────────────────────────────────
NEW_IMAGE_DIGEST=$(podman image inspect "$CONTAINER_IMAGE" --format '{{.Id}}' 2>/dev/null || echo "")
if [ -n "$CURRENT_DIGEST" ] && [ "$CURRENT_DIGEST" = "$NEW_IMAGE_DIGEST" ]; then
  echo "Image unchanged (already latest). Skipping restart."
  echo "=== No update needed ==="
  exit 0
fi
echo "New image detected, proceeding with update..."

# ─── 3. 컨테이너 재시작 ─────────────────────────────────────────
echo ""
echo "Stopping $SERVICE_UNIT..."
systemctl stop "$SERVICE_UNIT"
echo "Starting $SERVICE_UNIT..."
systemctl start "$SERVICE_UNIT"
echo "Container restarted"

# ─── 4. 헬스체크 ────────────────────────────────────────────────
echo ""
if ! http_health_check "$HEALTH_URL/api/health" 30 10; then
  echo "=== Health check failed ==="
  send_notification "$SERVICE_DISPLAY_NAME Update" "헬스체크 실패: 업데이트 후 응답 없음. 로그 확인 필요" 1
  exit 1
fi

# ─── 5. 결과 알림 ───────────────────────────────────────────────
echo ""
fetch_github_release "$GITHUB_REPO"
if [ -n "$GITHUB_LATEST_VERSION" ]; then
  VERSION_INFO="v${GITHUB_LATEST_VERSION}로"
else
  VERSION_INFO="최신 이미지로"
fi

print_bridge_risk_notice
BRIDGE_GUARD_WARN=false
if ! check_bridge_guard_services; then
  BRIDGE_GUARD_WARN=true
fi

echo "=== Update completed successfully ==="
if $BRIDGE_GUARD_WARN; then
  send_notification "$SERVICE_DISPLAY_NAME Update" "업데이트 완료(주의): ${VERSION_INFO} 업데이트됨. bridge 연계 서비스 상태 확인 필요" 0
else
  send_notification "$SERVICE_DISPLAY_NAME Update" "업데이트 완료: ${VERSION_INFO} 업데이트됨" 0
fi
