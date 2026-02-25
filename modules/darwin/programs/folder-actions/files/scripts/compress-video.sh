#!/bin/bash
# Folder Action: 비디오 H.265 압축
# 감시 폴더: ~/FolderActions/compress-video/
# 결과물: ~/Downloads/<타임스탬프>.mp4

set -euo pipefail

WATCH_DIR="$HOME/FolderActions/compress-video"
DEST_DIR="$HOME/Downloads"
LOCK_FILE="/tmp/compress-video.lock"

# 중복 실행 방지
if [ -f "$LOCK_FILE" ]; then
    exit 0
fi
touch "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# PATH 설정 (ffmpeg 위치)
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# 감시 폴더 내 비디오 파일 처리
find "$WATCH_DIR" -type f -maxdepth 1 \( -iname "*.mp4" -o -iname "*.mov" -o -iname "*.avi" -o -iname "*.mkv" -o -iname "*.wmv" \) | while read -r f; do
    [ -f "$f" ] || continue

    filename=$(basename "$f")
    timestamp=$(date +"%Y%m%dT%H%M%S%3N")
    output_path="${DEST_DIR}/${timestamp}.mp4"

    echo "[$(date)] 압축 시작: $filename"

    # H.265 압축 (hvc1 태그로 Apple 호환성 확보)
    if ffmpeg -nostdin -i "$f" \
        -c:v libx265 -preset fast -crf 28 -tag:v hvc1 \
        -c:a eac3 -b:a 224k \
        -y "$output_path" 2>/dev/null; then

        # 원본 삭제
        rm -f "$f"
        echo "[$(date)] 압축 완료: $filename -> ${timestamp}.mp4"
    else
        echo "[$(date)] 압축 실패: $filename" >&2
    fi
done
