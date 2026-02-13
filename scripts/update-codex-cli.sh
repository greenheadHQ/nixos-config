#!/usr/bin/env bash
# scripts/update-codex-cli.sh
# Codex CLI 패키지 자동 업데이트 (최신 GitHub 릴리스 → Nix derivation)
#
# 안전장치:
# - curl/nix-prefetch-url 타임아웃으로 네트워크 지연 시 무한 대기 방지
# - 파일 수정 전 백업, 실패/중단 시 자동 복원 (원자적 업데이트)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_FILE="$SCRIPT_DIR/../libraries/packages/codex-cli.nix"

sed_inplace() {
  local expr="$1"
  local file="$2"

  if sed --version >/dev/null 2>&1; then
    sed -i "$expr" "$file"
  else
    sed -i '' "$expr" "$file"
  fi
}

# 현재 버전 확인
current="$(grep 'version = ' "$PKG_FILE" | head -1 | sed 's/.*"\(.*\)".*/\1/')"
echo "현재 버전: $current"

# GitHub latest 릴리스 태그 가져오기 (타임아웃: 접속 5초, 전체 10초)
tag="$(curl -sI --connect-timeout 5 --max-time 10 \
  "https://github.com/openai/codex/releases/latest" \
  | grep -i '^location:' | sed 's|.*/tag/||; s/\r//')"

if [ -z "$tag" ]; then
  echo "❌ GitHub 릴리스 태그를 가져올 수 없습니다"
  exit 1
fi

latest="${tag#rust-v}"

# 태그 컨벤션 변경 감지 (semver 형식이 아니면 중단)
if ! [[ "$latest" =~ ^[0-9]+\.[0-9]+ ]]; then
  echo "❌ 예상치 못한 버전 형식: '$latest' (태그: $tag)"
  exit 1
fi

echo "최신 버전: $latest"

if [ "$current" = "$latest" ]; then
  echo "✅ 이미 최신 버전입니다"
  exit 0
fi

echo "⬆️  $current → $latest 업데이트 중..."

# 해시 계산 (파일 수정 전에 완료)
echo "해시 계산 중 (aarch64-darwin)..."
hash_darwin="$(nix-prefetch-url \
  "https://github.com/openai/codex/releases/download/rust-v${latest}/codex-aarch64-apple-darwin.tar.gz" \
  2>/dev/null)"
sri_darwin="$(nix hash convert --hash-algo sha256 --to sri "$hash_darwin")"

echo "해시 계산 중 (x86_64-linux)..."
hash_linux="$(nix-prefetch-url \
  "https://github.com/openai/codex/releases/download/rust-v${latest}/codex-x86_64-unknown-linux-musl.tar.gz" \
  2>/dev/null)"
sri_linux="$(nix hash convert --hash-algo sha256 --to sri "$hash_linux")"

# 원자적 파일 업데이트: 백업 생성 → 수정 → 성공 시 백업 삭제
# 실패/중단(Ctrl+C) 시 EXIT trap이 백업에서 자동 복원
cp "$PKG_FILE" "$PKG_FILE.bak"
cleanup() {
  if [[ -f "$PKG_FILE.bak" ]]; then
    mv "$PKG_FILE.bak" "$PKG_FILE"
    echo "❌ 업데이트 중단, 원본 복원됨"
  fi
}
trap cleanup EXIT

# codex-cli.nix 업데이트 (version → darwin hash → linux hash)
sed_inplace "s|version = \"$current\"|version = \"$latest\"|" "$PKG_FILE"

old_darwin="$(grep -A3 'aarch64-darwin' "$PKG_FILE" | grep 'hash =' | sed 's/.*"\(.*\)".*/\1/')"
sed_inplace "s|$old_darwin|$sri_darwin|" "$PKG_FILE"

old_linux="$(grep -A3 'x86_64-linux' "$PKG_FILE" | grep 'hash =' | sed 's/.*"\(.*\)".*/\1/')"
sed_inplace "s|$old_linux|$sri_linux|" "$PKG_FILE"

# 모든 수정 성공 — 백업 삭제 (trap이 복원하지 않도록)
rm -f "$PKG_FILE.bak"
trap - EXIT

echo ""
echo "✅ 업데이트 완료: $current → $latest"
echo ""
echo "변경사항:"
(cd "$SCRIPT_DIR/.." && git diff libraries/packages/codex-cli.nix)
