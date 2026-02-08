#!/bin/bash
# Uptime Kuma 버전 체크 및 Pushover 알림
# 매일 GitHub Releases API로 최신 버전을 확인하고, 새 버전 발견 시 알림 전송
# 이미지에 버전 레이블이 없으므로 GitHub latest 추적 방식 사용
set -euo pipefail

# 환경변수 (systemd에서 주입)
: "${PUSHOVER_CRED_FILE:?PUSHOVER_CRED_FILE is required}"
: "${SERVICE_LIB:?SERVICE_LIB is required}"
: "${STATE_DIR:?STATE_DIR is required}"
: "${CONTAINER_NAME:?CONTAINER_NAME is required}"
: "${CONTAINER_IMAGE:?CONTAINER_IMAGE is required}"
: "${GITHUB_REPO:?GITHUB_REPO is required}"
: "${SERVICE_DISPLAY_NAME:?SERVICE_DISPLAY_NAME is required}"

# 공통 라이브러리 로드
# shellcheck disable=SC1090
source "$SERVICE_LIB"

# Pushover credentials 로드
# shellcheck disable=SC1090
source "$PUSHOVER_CRED_FILE"

# 에러 발생 시 알림 전송
trap 'send_notification "$SERVICE_DISPLAY_NAME Version Check" "오류 발생: 스크립트 실패" 0' ERR

LAST_NOTIFIED_FILE="$STATE_DIR/last-notified-version"

# ─── 0. 워치독: 장기 실패 감지 ───────────────────────────────────
check_watchdog "$STATE_DIR" "$SERVICE_DISPLAY_NAME"

# ─── 1. 최신 버전 조회 (GitHub Releases API) ────────────────────
echo "Checking latest version from GitHub ($GITHUB_REPO)..."
fetch_github_release "$GITHUB_REPO"
if [ -z "$GITHUB_LATEST_VERSION" ]; then
  echo "Failed to get latest version from GitHub"
  exit 0
fi
LATEST="$GITHUB_LATEST_VERSION"
echo "Latest version: $LATEST"

# ─── 2. 메이저 버전 불일치 감지 ──────────────────────────────────
# 이미지 태그 :1은 1.x만 제공하지만 GitHub latest가 2.x일 수 있음
IMAGE_TAG="${CONTAINER_IMAGE##*:}"
IMAGE_MAJOR="${IMAGE_TAG%%.*}"
LATEST_MAJOR="${LATEST%%.*}"
MAJOR_MISMATCH=false

if [ "$IMAGE_MAJOR" != "$LATEST_MAJOR" ] 2>/dev/null; then
  MAJOR_MISMATCH=true
  echo "NOTE: Major version mismatch - image tag :${IMAGE_TAG} (${IMAGE_MAJOR}.x) vs GitHub latest v${LATEST} (${LATEST_MAJOR}.x)"
fi

# ─── 3. 초기 실행 처리 ──────────────────────────────────────────
if check_initial_run "$STATE_DIR" "$LATEST"; then
  exit 0
fi

# ─── 4. 버전 비교 ───────────────────────────────────────────────
LAST_NOTIFIED=$(cat "$LAST_NOTIFIED_FILE")

if [ "$LATEST" = "$LAST_NOTIFIED" ]; then
  echo "Already notified about version $LATEST"
  record_success "$STATE_DIR"
  exit 0
fi

# ─── 5. 새 버전 발견 → 알림 전송 ────────────────────────────────
echo "New version available: v$LATEST"

# 릴리즈 노트 추출
RELEASE_BODY=$(echo "$GITHUB_RESPONSE" | jq -r '.body // "릴리즈 노트 없음"' | head -20)
RELEASE_BODY="${RELEASE_BODY:0:1024}"

# 메이저 버전 불일치 시 추가 안내
if $MAJOR_MISMATCH; then
  MESSAGE="v${LATEST} 출시됨 (현재 이미지 태그 :${IMAGE_TAG}은 ${IMAGE_MAJOR}.x만 지원)

${RELEASE_BODY}

이미지 태그 변경 후: sudo uptime-kuma-update"
else
  MESSAGE="v${LATEST} 출시됨

${RELEASE_BODY}

업데이트: sudo uptime-kuma-update"
fi

send_notification "$SERVICE_DISPLAY_NAME 업데이트 알림" "$MESSAGE" 0

# 알림 완료 기록
echo "$LATEST" > "$LAST_NOTIFIED_FILE"
record_success "$STATE_DIR"
echo "Notification sent and version recorded"
