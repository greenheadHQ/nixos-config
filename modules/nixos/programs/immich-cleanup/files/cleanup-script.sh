#!/bin/bash
# Immich 임시 앨범 자동 정리 스크립트
# "Claude Code Temp" 앨범에서 retention days가 지난 이미지를 삭제
set -euo pipefail

# 환경변수 (systemd에서 주입)
: "${IMMICH_URL:?IMMICH_URL is required}"
: "${API_KEY_FILE:?API_KEY_FILE is required}"
: "${ALBUM_NAME:?ALBUM_NAME is required}"
: "${RETENTION_DAYS:?RETENTION_DAYS is required}"

# API 키 로드
API_KEY=$(cat "$API_KEY_FILE")

# 앨범 ID 조회
echo "Looking for album: $ALBUM_NAME"
ALBUM_ID=$(curl -sf -H "x-api-key: $API_KEY" \
  "$IMMICH_URL/api/albums" | \
  jq -r --arg name "$ALBUM_NAME" '.[] | select(.albumName==$name) | .id')

if [ -z "$ALBUM_ID" ] || [ "$ALBUM_ID" = "null" ]; then
  echo "Album '$ALBUM_NAME' not found. Nothing to cleanup."
  exit 0
fi

echo "Found album ID: $ALBUM_ID"

# 앨범 내 asset 목록 조회
ALBUM_DATA=$(curl -sf -H "x-api-key: $API_KEY" "$IMMICH_URL/api/albums/$ALBUM_ID")
ASSET_COUNT=$(echo "$ALBUM_DATA" | jq '.assets | length')
echo "Total assets in album: $ASSET_COUNT"

if [ "$ASSET_COUNT" -eq 0 ]; then
  echo "No assets in album. Nothing to cleanup."
  exit 0
fi

# 기준 날짜 계산 (retention days 이전)
CUTOFF=$(date -d "-${RETENTION_DAYS} days" -Iseconds)
echo "Cutoff date: $CUTOFF (assets older than this will be deleted)"

# 삭제 대상 asset ID 추출
DELETE_IDS=$(echo "$ALBUM_DATA" | jq -r --arg cutoff "$CUTOFF" \
  '.assets[] | select(.createdAt < $cutoff) | .id')

if [ -z "$DELETE_IDS" ]; then
  echo "No assets older than $RETENTION_DAYS days. Nothing to cleanup."
  exit 0
fi

DELETE_COUNT=$(echo "$DELETE_IDS" | wc -l)
echo "Found $DELETE_COUNT assets to delete"

# 각 asset 삭제 (force=true로 휴지통 우회)
while IFS= read -r ASSET_ID; do
  if [ -n "$ASSET_ID" ]; then
    echo "Deleting asset: $ASSET_ID"
    curl -sf -X DELETE -H "x-api-key: $API_KEY" \
      -H "Content-Type: application/json" \
      -d "{\"ids\":[\"$ASSET_ID\"],\"force\":true}" \
      "$IMMICH_URL/api/assets" > /dev/null
  fi
done <<< "$DELETE_IDS"

echo "Cleanup completed. Deleted $DELETE_COUNT assets."
