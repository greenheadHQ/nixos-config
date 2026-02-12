#!/usr/bin/env bash
# scripts/update-codex-cli.sh
# Codex CLI 패키지 자동 업데이트 (최신 GitHub 릴리스 → Nix derivation)
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

# GitHub latest 릴리스 태그 가져오기
tag="$(curl -sI "https://github.com/openai/codex/releases/latest" \
  | grep -i '^location:' | sed 's|.*/tag/||; s/\r//')"

if [ -z "$tag" ]; then
  echo "❌ GitHub 릴리스 태그를 가져올 수 없습니다"
  exit 1
fi

latest="${tag#rust-v}"
echo "최신 버전: $latest"

if [ "$current" = "$latest" ]; then
  echo "✅ 이미 최신 버전입니다"
  exit 0
fi

echo "⬆️  $current → $latest 업데이트 중..."

# 해시 계산 (두 플랫폼 병렬)
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

# codex-cli.nix 업데이트
sed_inplace "s|version = \"$current\"|version = \"$latest\"|" "$PKG_FILE"

# aarch64-darwin 해시 교체 (해당 블록 내 hash 라인)
old_darwin="$(grep -A3 'aarch64-darwin' "$PKG_FILE" | grep 'hash =' | sed 's/.*"\(.*\)".*/\1/')"
sed_inplace "s|$old_darwin|$sri_darwin|" "$PKG_FILE"

# x86_64-linux 해시 교체
old_linux="$(grep -A3 'x86_64-linux' "$PKG_FILE" | grep 'hash =' | sed 's/.*"\(.*\)".*/\1/')"
sed_inplace "s|$old_linux|$sri_linux|" "$PKG_FILE"

echo ""
echo "✅ 업데이트 완료: $current → $latest"
echo ""
echo "변경사항:"
(cd "$SCRIPT_DIR/.." && git diff libraries/packages/codex-cli.nix)
