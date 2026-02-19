#!/bin/bash
# Vaultwarden 수동 업데이트 안내
# Vaultwarden은 pinned tag 전략을 사용하므로 자동 업데이트를 하지 않습니다.
# 이미지 태그를 변경한 뒤 nrs로 적용하세요.
set -euo pipefail

: "${CONTAINER_IMAGE:?CONTAINER_IMAGE is required}"
: "${GITHUB_REPO:?GITHUB_REPO is required}"
: "${SERVICE_DISPLAY_NAME:?SERVICE_DISPLAY_NAME is required}"

IMAGE_TAG="${CONTAINER_IMAGE##*:}"

echo "=== $SERVICE_DISPLAY_NAME Manual Update ==="
echo ""
echo "현재 이미지: $CONTAINER_IMAGE"
echo "GitHub: https://github.com/$GITHUB_REPO/releases/latest"
echo ""
echo "업데이트 방법:"
echo "  1. modules/nixos/programs/docker/vaultwarden.nix 에서 이미지 태그 변경"
echo "     현재: $IMAGE_TAG → 새 버전 태그로 수정"
echo "  2. nrs 실행"
echo ""
echo "자동 업데이트는 지원하지 않습니다 (pinned tag 전략)."
