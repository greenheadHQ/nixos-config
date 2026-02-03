#!/bin/bash
# Immich 임시 앨범 자동 정리 스크립트
# "Claude Code Temp" 앨범의 모든 이미지를 삭제
set -euo pipefail

# 환경변수 (systemd에서 주입)
: "${IMMICH_URL:?IMMICH_URL is required}"
: "${API_KEY_FILE:?API_KEY_FILE is required}"
: "${ALBUM_NAME:?ALBUM_NAME is required}"
: "${PUSHOVER_CRED_FILE:?PUSHOVER_CRED_FILE is required}"

# API 키 로드
API_KEY=$(cat "$API_KEY_FILE")

# Pushover credentials 로드
# shellcheck disable=SC1090
source "$PUSHOVER_CRED_FILE"

# Pushover 알림 전송 함수
send_notification() {
  local title="$1"
  local message="$2"
  local priority="${3:-"-1"}"

  curl -sf --max-time 10 \
    --form-string "token=${PUSHOVER_TOKEN}" \
    --form-string "user=${PUSHOVER_USER}" \
    --form-string "title=${title}" \
    --form-string "message=${message}" \
    --form-string "priority=${priority}" \
    https://api.pushover.net/1/messages.json > /dev/null 2>&1 || true
}

# 에러 발생 시 알림 전송
trap 'send_notification "Immich Cleanup" "오류 발생: 스크립트 실패" 0' ERR

# 앨범 ID 조회
echo "Looking for album: $ALBUM_NAME"
ALBUMS_RESPONSE=$(curl -sf -H "x-api-key: $API_KEY" "$IMMICH_URL/api/albums") || {
  echo "Failed to fetch albums from Immich API"
  send_notification "Immich Cleanup" "Immich API 연결 실패" 0
  exit 1
}

ALBUM_ID=$(echo "$ALBUMS_RESPONSE" | jq -r --arg name "$ALBUM_NAME" '.[] | select(.albumName==$name) | .id')

if [ -z "$ALBUM_ID" ] || [ "$ALBUM_ID" = "null" ]; then
  echo "Album '$ALBUM_NAME' not found."
  send_notification "Immich Cleanup" "'$ALBUM_NAME' 앨범이 없습니다. 설정 확인 필요" 0
  exit 1
fi

echo "Found album ID: $ALBUM_ID"

# 앨범 내 asset ID 목록 조회
ALBUM_RESPONSE=$(curl -sf -H "x-api-key: $API_KEY" "$IMMICH_URL/api/albums/$ALBUM_ID") || {
  echo "Failed to fetch album details"
  send_notification "Immich Cleanup" "앨범 상세 조회 실패" 0
  exit 1
}

ASSET_IDS=$(echo "$ALBUM_RESPONSE" | jq -r '.assets[].id')

if [ -z "$ASSET_IDS" ]; then
  echo "No assets in album. Nothing to cleanup."
  send_notification "Immich Cleanup" "삭제할 이미지가 없습니다"
  exit 0
fi

TOTAL_COUNT=$(echo "$ASSET_IDS" | wc -l)
echo "Found $TOTAL_COUNT assets to delete"

# 각 asset 삭제 (force=true로 휴지통 우회)
SUCCESS_COUNT=0
FAIL_COUNT=0

while IFS= read -r ASSET_ID; do
  if [ -n "$ASSET_ID" ]; then
    echo "Deleting asset: $ASSET_ID"
    if curl -sf -X DELETE -H "x-api-key: $API_KEY" \
      -H "Content-Type: application/json" \
      -d "{\"ids\":[\"$ASSET_ID\"],\"force\":true}" \
      "$IMMICH_URL/api/assets" > /dev/null; then
      SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
      echo "Failed to delete asset: $ASSET_ID"
      FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
  fi
done <<< "$ASSET_IDS"

echo "Cleanup completed. Success: $SUCCESS_COUNT, Failed: $FAIL_COUNT"

# 결과 알림
if [ "$FAIL_COUNT" -eq 0 ]; then
  send_notification "Immich Cleanup" "${SUCCESS_COUNT}개 이미지 삭제됨"
else
  send_notification "Immich Cleanup" "${SUCCESS_COUNT}개 삭제, ${FAIL_COUNT}개 실패" 0
fi
