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

# 릴리즈 노트 추출: 줄 수(20)·문자 수(1024) 제한을 모두 jq 안에서 처리한다.
# 예전에는 jq 출력을 `head -20`으로 끊었는데, 본문이 크면 head가 파이프를 먼저 닫아
# jq가 SIGPIPE(141)로 죽고 pipefail 때문에 스크립트 전체가 실패했다(#1385, 새 버전을
# 찾았는데도 알림이 만들어지지 않고 그 버전이 계속 미전달로 남음). jq가 입력을 끝까지
# 읽고 나서 자체적으로 줄이므로 이 문제가 없다. jq의 문자열 슬라이스는 유니코드
# 코드포인트 단위로 동작해 실행 환경 로케일과 무관하게 일정하므로, 이어서 bash에서
# 다시 바이트/로케일에 좌우되는 ${var:0:1024} 절단을 할 필요가 없다. tostring은
# GitHub 스키마상 .body가 항상 문자열이거나 null이라 거의 걸리지 않지만, 혹시라도
# 문자열이 아닌 값(숫자 등)이 오면 split 단계에서 jq가 새로 에러를 내는 대신
# 예전처럼 그 값을 문자열로 바꿔 그대로 내보낸다.
RELEASE_BODY=$(echo "$GITHUB_RESPONSE" | jq -r '(.body // "릴리즈 노트 없음") | tostring | split("\n")[0:20] | join("\n") | .[0:1024]')

# 업데이트 명령 (서비스명 기반)
UPDATE_CMD="sudo ${CONTAINER_NAME}-update"

# 메이저 버전 불일치 시 추가 안내
if $MAJOR_MISMATCH; then
  IMAGE_TAG="${CONTAINER_IMAGE##*:}"
  IMAGE_MAJOR="${IMAGE_TAG%%.*}"
  MESSAGE="v${LATEST} 출시됨 (현재 이미지 태그 :${IMAGE_TAG}은 ${IMAGE_MAJOR}.x만 지원)

${RELEASE_BODY}

이미지 태그 변경 후: ${UPDATE_CMD}"
else
  MESSAGE="v${LATEST} 출시됨

${RELEASE_BODY}

업데이트: ${UPDATE_CMD}"
fi

send_notification "$SERVICE_DISPLAY_NAME 업데이트 알림" "$MESSAGE" 0

# 알림 완료 기록
echo "$LATEST" > "$LAST_NOTIFIED_FILE"
record_success "$STATE_DIR"
echo "Notification sent and version recorded"
