#!/bin/bash
# Immich 버전 체크 및 Pushover 알림
# 매일 GitHub Releases API로 최신 버전을 확인하고, 새 버전 발견 시 알림 전송
set -euo pipefail

# 환경변수 (systemd에서 주입)
: "${IMMICH_URL:?IMMICH_URL is required}"
: "${API_KEY_FILE:?API_KEY_FILE is required}"
: "${PUSHOVER_CRED_FILE:?PUSHOVER_CRED_FILE is required}"
: "${STATE_DIR:?STATE_DIR is required}"
: "${SERVICE_LIB:?SERVICE_LIB is required}"

# 공통 라이브러리 로드
# shellcheck disable=SC1090
source "$SERVICE_LIB"

# API 키 로드 (IMMICH_API_KEY=... 형식)
# shellcheck disable=SC1090
source "$API_KEY_FILE"
API_KEY="$IMMICH_API_KEY"

# Pushover credentials 로드
# shellcheck disable=SC1090
source "$PUSHOVER_CRED_FILE"

# 에러 발생 시 알림 전송
trap 'send_notification "Immich Version Check" "오류 발생: 스크립트 실패" 0' ERR

LAST_NOTIFIED_FILE="$STATE_DIR/last-notified-version"

# ─── 0. 워치독: 장기 실패 감지 ───────────────────────────────────
check_watchdog "$STATE_DIR" "Immich"

# ─── 1. 현재 버전 조회 (Immich API) ─────────────────────────────
echo "Checking current Immich version..."
CURRENT_RESPONSE=$(curl -sf --max-time 15 \
  -H "x-api-key: $API_KEY" \
  "$IMMICH_URL/api/server/version") || {
  echo "Failed to connect to Immich API"
  exit 0  # 다음 실행 때 재시도
}

CURRENT=$(echo "$CURRENT_RESPONSE" | jq -r '"\(.major).\(.minor).\(.patch)"')
if [ -z "$CURRENT" ] || [ "$CURRENT" = "null" ]; then
  echo "Failed to parse current version"
  exit 0
fi
echo "Current version: $CURRENT"

# ─── 2. 최신 버전 조회 (GitHub Releases API) ────────────────────
echo "Checking latest version from GitHub..."
fetch_github_release "immich-app/immich"
if [ -z "$GITHUB_LATEST_VERSION" ]; then
  echo "Failed to get latest version from GitHub"
  exit 0
fi
LATEST="$GITHUB_LATEST_VERSION"
echo "Latest version: $LATEST"

# ─── 3. 초기 실행 처리 ──────────────────────────────────────────
if check_initial_run "$STATE_DIR" "$CURRENT"; then
  exit 0
fi

# ─── 4. 버전 비교 ───────────────────────────────────────────────
LAST_NOTIFIED=$(cat "$LAST_NOTIFIED_FILE")

if [ "$CURRENT" = "$LATEST" ]; then
  echo "Already on latest version ($CURRENT)"
  record_success "$STATE_DIR"
  exit 0
fi

if [ "$LATEST" = "$LAST_NOTIFIED" ]; then
  echo "Already notified about version $LATEST"
  record_success "$STATE_DIR"
  exit 0
fi

# ─── 5. 새 버전 발견 → 알림 전송 ────────────────────────────────
echo "New version available: $CURRENT → $LATEST"

# 릴리즈 노트 추출 (jq로 안전하게)
RELEASE_BODY=$(echo "$GITHUB_RESPONSE" | jq -r '.body // "릴리즈 노트 없음"' | head -20)
# 1024자 제한 (Pushover 메시지 제한)
RELEASE_BODY="${RELEASE_BODY:0:1024}"

# 알림 메시지 구성
MESSAGE="현재: v${CURRENT} → 최신: v${LATEST}

${RELEASE_BODY}

업데이트: sudo immich-update"

send_notification "Immich 업데이트 알림" "$MESSAGE" 0

# 알림 완료 기록
echo "$LATEST" > "$LAST_NOTIFIED_FILE"
record_success "$STATE_DIR"
echo "Notification sent and version recorded"
