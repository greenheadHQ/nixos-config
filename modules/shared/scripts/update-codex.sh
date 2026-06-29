#!/usr/bin/env bash
# update-codex — Codex CLI을 OpenAI 공식 최신 릴리스로 핀 갱신 + 적용 (#890)
#
# codex는 declarative nix overlay(modules/shared/programs/codex/package.nix)로 설치되며 버전은
# codex-pin.json에 핀된다. 이 스크립트는 OpenAI GitHub 릴리스에서 최신 stable(rust-vX.Y.Z)을
# 찾아 핀된 플랫폼들의 CLI asset 해시와, 선언된 경우 Codex App remote-control standalone package
# 해시를 함께 prefetch해 핀을 갱신하고 nrs로 적용한다. nixpkgs lag·제3자 flake 없이 "한 줄로
# 최신"을 받기 위한 경로.
#
# 사용법:
#   update-codex            # 최신 stable로 핀 갱신 + nrs
#   update-codex --pre      # alpha/prerelease 포함 최신
#   update-codex --no-build # 핀만 갱신(nrs 생략)
#   update-codex --force    # 동일 버전이어도 해시 재계산
#   update-codex --help     # 이 도움말 출력
#
# mise/codex/node를 일절 호출하지 않는다(#890 fork 폭주 회피).
set -euo pipefail

FLAKE_PATH="@flakePath@"
PIN_REL="modules/shared/programs/codex/codex-pin.json"
PIN="$FLAKE_PATH/$PIN_REL"
REPO="openai/codex"
NRS_BIN="$HOME/.local/bin/nrs"

include_pre=0
do_build=1
force=0
for arg in "$@"; do
  case "$arg" in
    --pre) include_pre=1 ;;
    --no-build) do_build=0 ;;
    --force) force=1 ;;
    -h | --help)
      # 선행 주석 블록(shebang 다음 ~ 첫 non-# 라인 전)만 출력한다. 고정 라인범위 대신
      # 첫 non-# 라인에서 멈춰 도구 코드나 치환된 flake 경로가 새지 않게 한다.
      awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"
      exit 0
      ;;
    *)
      echo "update-codex: 알 수 없는 인자 '$arg' (--pre/--no-build/--force/--help)" >&2
      exit 2
      ;;
  esac
done

for tool in gh jq nix; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "update-codex: '$tool' 필요" >&2
    exit 1
  }
done
[ -f "$PIN" ] || {
  echo "update-codex: 핀 파일 없음: $PIN" >&2
  exit 1
}

# 최신 태그 resolve. releases는 newest-first; --paginate로 전 페이지를 순회하며 full-semver
# (stable은 alpha 제외) + non-draft를 필터해 첫 매치를 취한다(head가 파이프를 닫아 보통 첫 페이지에서
# 종료). codex repo는 rust-v 외 다른 시리즈도 릴리스하므로 releases/latest 대신 명시적 필터를 쓴다.
if [ "$include_pre" = 1 ]; then
  jq_filter='.[] | select(.draft==false) | .tag_name'
  tag_re='^rust-v[0-9]+\.[0-9]+\.[0-9]+(-.*)?$'
else
  jq_filter='.[] | select(.prerelease==false and .draft==false) | .tag_name'
  tag_re='^rust-v[0-9]+\.[0-9]+\.[0-9]+$'
fi
tag="$(gh api --paginate "repos/$REPO/releases?per_page=100" --jq "$jq_filter" 2>/dev/null \
  | grep -E "$tag_re" | head -n1 || true)"
[ -n "$tag" ] || {
  echo "update-codex: 최신 릴리스 태그 조회 실패 (gh auth/network 확인)" >&2
  exit 1
}
ver="${tag#rust-v}"
current="$(jq -r '.version' "$PIN")"

if [ "$ver" = "$current" ] && [ "$force" = 0 ]; then
  echo "이미 최신: codex $current ($tag) — 변경 없음"
  exit 0
fi

echo "codex $current → $ver ($tag) 갱신 중..."
base="https://github.com/$REPO/releases/download/$tag"

# 핀과 같은 디렉토리에 임시 파일을 만들어 최종 mv가 same-fs atomic rename이 되게 하고,
# trap으로 중단 시 잔재를 정리한다(핀 디렉토리는 git 추적 대상이라 누수 시 working tree 오염).
tmp="$(mktemp "$(dirname "$PIN")/.codex-pin.XXXXXX")"
# "$tmp".2는 아래 jq write-then-rename의 scratch sibling. trap이 둘 다 정리한다(아직 없으면 no-op).
trap 'rm -f "$tmp" "$tmp".2' EXIT
cp "$PIN" "$tmp"
for plat in $(jq -r '.platforms | keys[]' "$PIN"); do
  asset="$(jq -r --arg p "$plat" '.platforms[$p].asset' "$PIN")"
  printf '  prefetch %-44s' "$asset" # 44 = 현행 asset 이름 최장(~39자) 정렬용 cosmetic 폭
  h="$(nix store prefetch-file --json "$base/$asset" 2>/dev/null | jq -r '.hash')" || {
    echo "FAIL"
    echo "update-codex: $asset prefetch 실패 — 릴리스에 해당 asset이 없거나 네트워크 오류" >&2
    exit 1
  }
  echo "$h"
  jq --arg p "$plat" --arg h "$h" '.platforms[$p].hash=$h' "$tmp" >"$tmp".2 && mv "$tmp".2 "$tmp"

  standalone_asset="$(jq -r --arg p "$plat" '.platforms[$p].standalonePackage.asset // empty' "$PIN")"
  if [ -n "$standalone_asset" ]; then
    printf '  prefetch %-44s' "$standalone_asset"
    standalone_hash="$(nix store prefetch-file --json "$base/$standalone_asset" 2>/dev/null | jq -r '.hash')" || {
      echo "FAIL"
      echo "update-codex: $standalone_asset prefetch 실패 — 릴리스에 standalone package asset이 없거나 네트워크 오류" >&2
      exit 1
    }
    echo "$standalone_hash"
    jq --arg p "$plat" --arg h "$standalone_hash" \
      '.platforms[$p].standalonePackage.hash=$h' "$tmp" >"$tmp".2 && mv "$tmp".2 "$tmp"
  fi
done
jq --arg v "$ver" --arg t "$tag" '.version=$v | .tag=$t' "$tmp" >"$tmp".2 && mv "$tmp".2 "$tmp"
mv "$tmp" "$PIN"
trap - EXIT
echo "✅ 핀 갱신 완료: codex $ver ($PIN)"

if [ "$do_build" = 1 ]; then
  if [ -x "$NRS_BIN" ]; then
    echo "▶ nrs 실행 (sudo 필요)..."
    (cd "$FLAKE_PATH" && "$NRS_BIN")
    echo ""
    echo "ℹ️  codex-pin.json 변경을 커밋하세요:"
    echo "    git -C \"$FLAKE_PATH\" add $PIN_REL && git commit -m \"chore(codex): bump to $ver\""
  else
    echo "⚠️  nrs 미발견($NRS_BIN) — 핀만 갱신됨. 'nrs' 실행 후 codex-pin.json을 커밋하세요." >&2
  fi
else
  echo "ℹ️  --no-build: nrs 생략. 적용하려면 'nrs' 후 codex-pin.json을 커밋하세요."
fi
