#!/usr/bin/env bash
# 서비스 버전 체크 및 Pushover 알림 (공통)
# 매일 GitHub Releases API로 최신 버전을 확인하고, 새 버전 발견 시 알림 전송
# 이미지에 버전 레이블이 없으므로 GitHub latest 추적 방식 사용
#
# 환경변수:
#   DETECT_MAJOR_MISMATCH=true  - 이미지 태그 메이저 버전 불일치 감지 (선택적)
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
service_install_error_trap send_notification "$SERVICE_DISPLAY_NAME Version Check" "오류 발생: 스크립트 실패" 0

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

# ─── 2. 메이저 버전 불일치 감지 (선택적) ──────────────────────────
MAJOR_MISMATCH=false
if [ "${DETECT_MAJOR_MISMATCH:-false}" = "true" ]; then
  IMAGE_TAG="${CONTAINER_IMAGE##*:}"
  IMAGE_MAJOR="${IMAGE_TAG%%.*}"
  LATEST_MAJOR="${LATEST%%.*}"

  if [ "$IMAGE_MAJOR" != "$LATEST_MAJOR" ] 2>/dev/null; then
    MAJOR_MISMATCH=true
    echo "NOTE: Major version mismatch - image tag :${IMAGE_TAG} (${IMAGE_MAJOR}.x) vs GitHub latest v${LATEST} (${LATEST_MAJOR}.x)"
  fi
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

# 서비스 모듈이 소유한 실행 명령과 선행 절차를 안내한다. 문자열을 실행하지 않는다.
UPDATE_CMD="${UPDATE_COMMAND:-sudo ${CONTAINER_NAME}-update}"
UPDATE_GUIDANCE="업데이트: ${UPDATE_CMD}"
if $MAJOR_MISMATCH; then
  UPDATE_GUIDANCE="이미지 태그를 변경하고 nrs로 적용한 뒤: ${UPDATE_CMD}"
fi
if [ -n "${UPDATE_PREPARATION:-}" ]; then
  UPDATE_GUIDANCE="${UPDATE_PREPARATION}
확인 후: ${UPDATE_CMD}"
fi

# 메이저 버전 불일치 시 추가 안내
if $MAJOR_MISMATCH; then
  IMAGE_TAG="${CONTAINER_IMAGE##*:}"
  IMAGE_MAJOR="${IMAGE_TAG%%.*}"
  MESSAGE_HEADER="v${LATEST} 출시됨 (현재 이미지 태그 :${IMAGE_TAG}은 ${IMAGE_MAJOR}.x만 지원)"
else
  MESSAGE_HEADER="v${LATEST} 출시됨"
fi

# Pushover의 1024자 한도에서 헤더·안내·구분 개행 4자를 먼저 확보하고 본문만 줄인다.
# jq 안에서 20줄·코드포인트 제한을 함께 처리해 큰 본문의 SIGPIPE와 로케일 영향을 피한다(#1385).
MESSAGE=$(echo "$GITHUB_RESPONSE" | jq -r \
  --arg header "$MESSAGE_HEADER" --arg guidance "$UPDATE_GUIDANCE" '
  (($header | length) + ($guidance | length) + 4) as $fixed_length
  | if $fixed_length > 1024 then
      error("notification header and guidance exceed 1024 characters")
    else
      (.body // "릴리즈 노트 없음") | tostring | split("\n")[0:20] | join("\n")
      | .[0:(1024 - $fixed_length)]
      | $header + "\n\n" + . + "\n\n" + $guidance
    end')

send_notification "$SERVICE_DISPLAY_NAME 업데이트 알림" "$MESSAGE" 0

# 알림 완료 기록
echo "$LATEST" > "$LAST_NOTIFIED_FILE"
record_success "$STATE_DIR"
echo "Notification sent and version recorded"
