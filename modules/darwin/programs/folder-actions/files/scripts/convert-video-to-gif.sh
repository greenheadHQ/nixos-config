#!/bin/bash
# Folder Action: 비디오를 GIF로 변환
# 감시 폴더: ~/FolderActions/convert-video-to-gif/
# 결과물: ~/Downloads/<타임스탬프>.gif

set -euo pipefail

WATCH_DIR="$HOME/FolderActions/convert-video-to-gif"
DEST_DIR="$HOME/Downloads"
LOCK_FILE="/tmp/convert-video-to-gif.lock"

# 기본 설정
FPS=15
WIDTH=480

# 중복 실행 방지
if [ -f "$LOCK_FILE" ]; then
    exit 0
fi
touch "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# PATH 설정 (ffmpeg 위치)
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

# 감시 폴더 내 비디오 파일 처리
find "$WATCH_DIR" -type f -maxdepth 1 \( -iname "*.mp4" -o -iname "*.mov" -o -iname "*.avi" -o -iname "*.mkv" -o -iname "*.webm" \) | while read -r f; do
    [ -f "$f" ] || continue

    filename=$(basename "$f")
    timestamp=$(date +"%Y%m%dT%H%M%S%3N")
    output_path="${DEST_DIR}/${timestamp}.gif"

    echo "[$(date)] GIF 변환 시작: $filename (${FPS}fps, ${WIDTH}px)"

    # GIF 변환
    if ffmpeg -nostdin -hide_banner -loglevel error -y \
        -i "$f" \
        -vf "fps=${FPS},scale=${WIDTH}:-1:flags=lanczos" \
        -c:v gif -f gif "$output_path" 2>/dev/null; then

        # 원본 삭제
        rm -f "$f"
        echo "[$(date)] GIF 변환 완료: $filename -> ${timestamp}.gif"
    else
        echo "[$(date)] GIF 변환 실패: $filename" >&2
    fi
done
