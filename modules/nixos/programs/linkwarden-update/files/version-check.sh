#!/bin/bash
# Linkwarden 버전 체크 및 Pushover 알림
# NixOS 네이티브 서비스 패턴: pkgs.linkwarden.version vs GitHub latest
# 업데이트는 nix flake update + nrs (수동)
set -euo pipefail

# 환경변수 (systemd에서 주입)
: "${PUSHOVER_CRED_FILE:?PUSHOVER_CRED_FILE is required}"
: "${SERVICE_LIB:?SERVICE_LIB is required}"
: "${STATE_DIR:?STATE_DIR is required}"
: "${GITHUB_REPO:?GITHUB_REPO is required}"
: "${SERVICE_DISPLAY_NAME:?SERVICE_DISPLAY_NAME is required}"
: "${CURRENT_VERSION:?CURRENT_VERSION is required}"

# 공통 라이브러리 로드
# shellcheck disable=SC1090
source "$SERVICE_LIB"

# Pushover credentials 로드
# shellcheck disable=SC1090
source "$PUSHOVER_CRED_FILE"

# 에러 발생 시 알림 전송
trap 'send_notification "$SERVICE_DISPLAY_NAME Version Check" "오류 발생: 스크립트 실패" 0' ERR

# ─── 0. 워치독: 장기 실패 감지 ───────────────────────────────────
check_watchdog "$STATE_DIR" "$SERVICE_DISPLAY_NAME"

# ─── 1. 현재 버전 (빌드 시 고정) ──────────────────────────────────
echo "Current installed version: $CURRENT_VERSION"

# ─── 2. 최신 버전 조회 (GitHub Releases API) ────────────────────
echo "Checking latest version from GitHub ($GITHUB_REPO)..."
fetch_github_release "$GITHUB_REPO"
if [ -z "$GITHUB_LATEST_VERSION" ]; then
  echo "Failed to get latest version from GitHub"
  exit 0
fi
LATEST="$GITHUB_LATEST_VERSION"
echo "Latest version: $LATEST"

# ─── 3. 초기 실행 처리 ──────────────────────────────────────────
if check_initial_run "$STATE_DIR" "$CURRENT_VERSION"; then
  record_success "$STATE_DIR"
  exit 0
fi

# ─── 4. 버전 비교 ───────────────────────────────────────────────
LAST_NOTIFIED=$(cat "$STATE_DIR/last-notified-version")

if [ "$CURRENT_VERSION" = "$LATEST" ]; then
  echo "Already on latest version ($CURRENT_VERSION)"
  record_success "$STATE_DIR"
  exit 0
fi

if [ "$LATEST" = "$LAST_NOTIFIED" ]; then
  echo "Already notified about version $LATEST"
  record_success "$STATE_DIR"
  exit 0
fi

# ─── 5. 새 버전 발견 → 알림 전송 ────────────────────────────────
echo "New version available: $CURRENT_VERSION → $LATEST"

RELEASE_URL=$(echo "$GITHUB_RESPONSE" | jq -r '.html_url // ""')

MESSAGE="현재: v${CURRENT_VERSION} → 최신: v${LATEST}

업데이트: nix flake update + nrs"

if [ -n "$RELEASE_URL" ]; then
  MESSAGE="${MESSAGE}
${RELEASE_URL}"
fi

send_notification "$SERVICE_DISPLAY_NAME 업데이트 알림" "$MESSAGE" 0

# 알림 완료 기록
echo "$LATEST" > "$STATE_DIR/last-notified-version"
record_success "$STATE_DIR"
echo "Notification sent and version recorded"
