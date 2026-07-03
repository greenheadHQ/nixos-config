#!/usr/bin/env bash
# Immich 임시 앨범 자동 정리 스크립트
# "Claude Code Temp" 앨범의 모든 이미지를 삭제
set -euo pipefail

# 환경변수 (systemd에서 주입)
: "${IMMICH_URL:?IMMICH_URL is required}"
: "${API_KEY_FILE:?API_KEY_FILE is required}"
: "${ALBUM_NAME:?ALBUM_NAME is required}"
: "${PUSHOVER_CRED_FILE:?PUSHOVER_CRED_FILE is required}"
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
trap 'send_notification "Immich Cleanup" "오류 발생: 스크립트 실패" 0' ERR

PAGE_SIZE=1000
UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
CURL_CONNECT_TIMEOUT=10
CURL_MAX_TIME=60

fetch_album_asset_ids() {
  local album_id="$1"
  local page=1
  local search_body search_response next_page asset_id
  ASSET_IDS=()

  while true; do
    search_body=$(
      jq -n \
        --arg albumId "$album_id" \
        --argjson page "$page" \
        --argjson size "$PAGE_SIZE" \
        '{albumIds: [$albumId], page: $page, size: $size, withDeleted: false}'
    )

    search_response=$(curl -sf \
      --connect-timeout "$CURL_CONNECT_TIMEOUT" \
      --max-time "$CURL_MAX_TIME" \
      -X POST -H "x-api-key: $API_KEY" \
      -H "Content-Type: application/json" \
      -d "$search_body" \
      "$IMMICH_URL/api/search/metadata") || {
      echo "Failed to search album assets"
      send_notification "Immich Cleanup" "앨범 asset 조회 실패" 0
      exit 1
    }

    if ! echo "$search_response" | jq -e '.assets.items | type == "array"' > /dev/null; then
      echo "Unexpected search response: .assets.items is not an array"
      send_notification "Immich Cleanup" "앨범 asset 응답 형식 오류" 0
      exit 1
    fi

    if ! echo "$search_response" | jq -e --arg uuid "$UUID_RE" 'all(.assets.items[]?; (.id | type == "string" and test($uuid)))' > /dev/null; then
      echo "Unexpected search response: asset id is not a UUID string"
      send_notification "Immich Cleanup" "앨범 asset ID 응답 형식 오류" 0
      exit 1
    fi

    while IFS= read -r asset_id; do
      ASSET_IDS+=("$asset_id")
    done < <(echo "$search_response" | jq -r '.assets.items[].id')

    if ! echo "$search_response" | jq -e '(.assets | has("nextPage")) and (.assets.nextPage == null or (.assets.nextPage | type == "string"))' > /dev/null; then
      echo "Unexpected search response: .assets.nextPage is not null or a string"
      send_notification "Immich Cleanup" "앨범 asset 페이지 응답 형식 오류" 0
      exit 1
    fi

    if echo "$search_response" | jq -e '.assets.nextPage == null' > /dev/null; then
      break
    fi
    next_page=$(echo "$search_response" | jq -r '.assets.nextPage')
    if [[ ! "$next_page" =~ ^[1-9][0-9]*$ ]]; then
      echo "Unexpected search response: .assets.nextPage is not a positive integer string"
      send_notification "Immich Cleanup" "앨범 asset 페이지 응답 형식 오류" 0
      exit 1
    fi
    page="$next_page"
  done
}

# 앨범 ID 조회
echo "Looking for album: $ALBUM_NAME"
ALBUMS_RESPONSE=$(curl -sf \
  --connect-timeout "$CURL_CONNECT_TIMEOUT" \
  --max-time "$CURL_MAX_TIME" \
  -H "x-api-key: $API_KEY" \
  "$IMMICH_URL/api/albums") || {
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

fetch_album_asset_ids "$ALBUM_ID"

if [ "${#ASSET_IDS[@]}" -eq 0 ]; then
  echo "No assets in album. Nothing to cleanup."
  send_notification "Immich Cleanup" "삭제할 이미지가 없습니다"
  exit 0
fi

TOTAL_COUNT="${#ASSET_IDS[@]}"
echo "Found $TOTAL_COUNT assets to delete"

# 각 asset 삭제 (force=true로 휴지통 우회)
SUCCESS_COUNT=0
FAIL_COUNT=0

for ASSET_ID in "${ASSET_IDS[@]}"; do
  if [ -n "$ASSET_ID" ]; then
    echo "Deleting asset: $ASSET_ID"
    DELETE_BODY=$(jq -n --arg id "$ASSET_ID" '{ids: [$id], force: true}')
    if curl -sf \
      --connect-timeout "$CURL_CONNECT_TIMEOUT" \
      --max-time "$CURL_MAX_TIME" \
      -X DELETE -H "x-api-key: $API_KEY" \
      -H "Content-Type: application/json" \
      -d "$DELETE_BODY" \
      "$IMMICH_URL/api/assets" > /dev/null; then
      SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
      echo "Failed to delete asset: $ASSET_ID"
      FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
  fi
done

echo "Cleanup completed. Success: $SUCCESS_COUNT, Failed: $FAIL_COUNT"

# 결과 알림
if [ "$FAIL_COUNT" -eq 0 ]; then
  send_notification "Immich Cleanup" "${SUCCESS_COUNT}개 이미지 삭제됨"
else
  send_notification "Immich Cleanup" "${SUCCESS_COUNT}개 삭제, ${FAIL_COUNT}개 실패" 0
fi
