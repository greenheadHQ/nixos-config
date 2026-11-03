#!/usr/bin/env bash
# update-codex — Codex CLI을 OpenAI 공식 최신 릴리스로 핀 갱신 + 적용 (#890)
#
# codex는 declarative nix overlay(modules/shared/programs/codex/package.nix)로 설치되며 버전은
# codex-pin.json에 핀된다. 이 스크립트는 OpenAI GitHub 릴리스에서 최신 stable(rust-vX.Y.Z)을
# 찾아 핀된 플랫폼들의 codex-package 통합 tarball(#1219 — codex + code-mode host 사이드카 +
# 번들 rg/zsh를 upstream이 조립해 발행; NixOS remote-control standalone payload도 같은 asset
# 공유) 해시를 prefetch해 핀을 갱신하고 nrs로 적용한다. nixpkgs lag·제3자 flake 없이
# "한 줄로 최신"을 받기 위한 경로.
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

# 최신 태그 resolve. codex repo는 rust-v 외 다른 시리즈도 릴리스하므로 releases/latest 대신
# 명시적 필터를 쓴다: 릴리스 목록 순서(newest-first)에서 full-semver(stable은 alpha 제외) + non-draft
# 첫 매치를 취하고, 한 페이지에 매치가 없으면 cursor로 다음 페이지를 이어 본다.
# REST releases 목록은 쓰지 않는다 — 릴리스마다 asset 수백 개를 함께 직렬화해 per_page=100 응답이
# GitHub 응답 시간 한도를 넘겨 HTTP 504로 실패했다(2026-11, 릴리스당 asset 최대 354개). GraphQL로
# 태그 이름·prerelease·draft만 받으면 응답 크기가 asset 수와 무관하다.
# orderBy는 지정하지 않는다 — 기본 순서가 REST 목록 순서와 같고(2026-11 최근 50건 일치),
# CREATED_AT DESC는 rust-v0.165.0과 rust-v0.166.0-alpha.4의 앞뒤가 REST와 달라 --pre 첫 매치가 바뀐다.
if [ "$include_pre" = 1 ]; then
  tag_re='^rust-v[0-9]+\.[0-9]+\.[0-9]+(-.*)?$'
else
  tag_re='^rust-v[0-9]+\.[0-9]+\.[0-9]+$'
fi
# shellcheck disable=SC2016  # $owner 등은 GraphQL 변수다(셸 확장 대상 아님).
release_query='query($owner: String!, $name: String!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    releases(first: 100, after: $cursor) {
      pageInfo { hasNextPage endCursor }
      nodes { tagName isPrerelease isDraft }
    }
  }
}'

# gh stderr는 버리지 않는다 — 파일로 받아 실패 시 그대로 보여 주고, 성공 시에도 경고가 있으면 전달한다.
# HTTP 상태는 stderr가 아니라 `gh api -i`의 상태 줄에서 읽는다: gh는 본문에 `message`가 있을 때만
# stderr에 "(HTTP nnn)"을 붙이고, GraphQL `errors`만 있는 본문이면 5xx여도 상태를 빼기 때문이다.
gh_err="$(mktemp "${TMPDIR:-/tmp}/update-codex-gh.XXXXXX")"
trap 'rm -f "$gh_err"' EXIT

# lookup_fail <사유> <안내> [상세]
# 조회 실패 헤드라인을 출력하고, 상세와 아직 출력하지 않은 gh stderr를 들여써 붙인 뒤 종료한다.
lookup_fail() {
  echo "update-codex: 최신 릴리스 태그 조회 실패 ($1) — $2" >&2
  [ -z "${3:-}" ] || printf '%s\n' "$3" | sed 's/^/  /' >&2
  [ ! -s "$gh_err" ] || sed 's/^/  /' "$gh_err" >&2
  exit 1
}

# report_gh_failure <http_status> <body>
# gh 실패를 HTTP 상태(예: "504 Gateway Timeout", 응답이 없으면 빈 값)와 GraphQL errors로 분류해 보고한다.
report_gh_failure() {
  local status="$1" body="$2" gql reason hint
  gql="$(printf '%s' "$body" | jq -r '
    if ((.errors? // []) | length) == 0 then ""
    else ([.errors[] | .type? // empty] | unique | join(",")) as $t
      | "GraphQL 오류" + (if $t == "" then "" else ": " + $t end)
    end' 2>/dev/null || true)"
  if [ -z "$status" ]; then
    reason="HTTP 응답 없음"
  else
    reason="HTTP $status${gql:+, $gql}"
  fi
  case "${status%% *}:$gql" in
    :*) hint="네트워크·프록시·gh 설정 확인" ;;
    401:*) hint="인증 실패, gh auth status로 확인" ;;
    403:* | 429:* | *RATE_LIMITED*) hint="권한 부족 또는 rate limit, gh api rate_limit로 확인" ;;
    5*) hint="GitHub 서버 측 오류·시간 초과, 잠시 후 재시도" ;;
    *NOT_FOUND* | *FORBIDDEN*) hint="조회 대상 저장소·권한 확인" ;;
    2*:) hint="응답 본문 수신 실패, 잠시 후 재시도" ;;
    *) hint="아래 gh 오류 확인" ;;
  esac
  lookup_fail "$reason" "$hint"
}

tag=""
cursor=""
while :; do
  gh_args=(api -i graphql -f query="$release_query" -f owner="${REPO%%/*}" -f name="${REPO#*/}")
  [ -z "$cursor" ] || gh_args+=(-f cursor="$cursor")
  gh_rc=0
  raw="$(gh "${gh_args[@]}" 2>"$gh_err")" || gh_rc=$?
  # -i 출력: "HTTP/2.0 504 Gateway Timeout\n" + 헤더("K: V\r\n")… + "\r\n" + 본문.
  # 응답 자체가 없으면(네트워크·프록시 오류) 비어 있다. 본문이 비면(예: 헤더 수신 뒤 스트림이
  # 끊긴 실측 "stream error: … CANCEL") $(...)가 끝 줄바꿈을 지워 구분자가 "\r\n\r"로 남으므로,
  # 상태 줄은 구분자와 무관하게 읽고 구분자가 없으면 본문을 빈 값으로 둔다.
  http_status=""
  body="$raw"
  case "$raw" in
    HTTP/*)
      http_status="${raw%%$'\n'*}"
      http_status="${http_status%$'\r'}"
      http_status="${http_status#* }"
      case "$raw" in
        *$'\r\n\r\n'*) body="${raw#*$'\r\n\r\n'}" ;;
        *) body="" ;;
      esac
      ;;
  esac
  [ "$gh_rc" = 0 ] || report_gh_failure "$http_status" "$body"
  if [ -s "$gh_err" ]; then
    cat "$gh_err" >&2
    : >"$gh_err"
  fi
  # 형식 검증과 추출을 jq 한 번으로 한다. 필드 구분자는 공백류가 아닌 \x1f라 빈 필드도 보존된다.
  # -e: 본문이 비어 jq가 아무것도 출력하지 않으면(exit 4) "매치 없음"이 아니라 형식 이상으로 잡는다.
  if ! parsed="$(printf '%s' "$body" | jq -er --arg re "$tag_re" --argjson pre "$include_pre" '
    .data.repository.releases
    | if (.nodes | type) == "array" and (.pageInfo.hasNextPage | type) == "boolean" then .
      else error("unexpected shape") end
    | [ (.pageInfo.hasNextPage | tostring),
        (.pageInfo.endCursor // ""),
        (first(.nodes[]
               | select(.isDraft == false and ($pre == 1 or .isPrerelease == false))
               | .tagName | select(test($re))) // "") ]
    | join("\u001f")' 2>/dev/null)"; then
    lookup_fail "응답 형식 이상" "data.repository.releases의 nodes·pageInfo가 없다" "$(printf '%.300s' "${body:-<빈 본문>}")"
  fi
  IFS=$'\x1f' read -r has_next next_cursor tag <<<"$parsed"
  [ -z "$tag" ] || break
  [ "$has_next" = true ] || break
  # 다음 페이지가 있다면서 cursor가 비었거나 제자리면 같은 페이지를 무한히 다시 받는다.
  if [ -z "$next_cursor" ] || [ "$next_cursor" = "$cursor" ]; then
    lookup_fail "응답 형식 이상" "hasNextPage=true인데 endCursor가 비었거나 진행하지 않는다"
  fi
  cursor="$next_cursor"
done
[ -n "$tag" ] || lookup_fail "매치 없음" "$REPO 릴리스 전체에 '$tag_re'와 맞는 태그가 없다"
rm -f "$gh_err"
trap - EXIT
ver="${tag#rust-v}"
current="$(jq -r '.version' "$PIN")"

# ensure_asset_decl <plat>
# 핀 선언을 조회해 asset 이름을 출력한다. 미선언이면 pin 경로를 안내하고 실패한다.
# 같은 버전 fast path 전의 완결성 검사와 prefetch_asset이 이 검사 하나를 공유한다.
ensure_asset_decl() {
  local plat="$1" asset
  asset="$(jq -r --arg p "$plat" '.platforms[$p].asset? // empty' "$PIN")"
  if [ -z "$asset" ]; then
    echo "update-codex: ${plat}에 codex-package asset 선언 없음 — package.nix eval이 throw한다. codex-pin.json의 platforms.${plat}에 asset/hash를 추가하라" >&2
    exit 1
  fi
  printf '%s\n' "$asset"
}

# 핀 선언 완결성을 같은 버전 fast path보다 먼저 검사한다 — 부분 편집된 핀(예: 새 플랫폼
# 추가 시 asset/hash 누락)이 "이미 최신" 조기 종료를 타고 검증 없이 통과하면, 그 누락은
# 해당 호스트의 nrs eval에서야 드러난다 (update 단계 선제 검증 계약의 구멍 — PR #1220 리뷰 반영).
# asset 이름은 사람이 넣어야 하는 값이라 누락 시 즉시 실패하고, hash는 prefetch가 스스로
# 계산할 수 있는 값이라 누락 시 fast path를 우회해 prefetch로 복구한다 (PR #1221 리뷰 반영).
missing_hash=0
for plat in $(jq -r '.platforms | keys[]' "$PIN"); do
  ensure_asset_decl "$plat" >/dev/null
  hash_decl="$(jq -r --arg p "$plat" '.platforms[$p].hash? // empty' "$PIN")"
  if [ -z "$hash_decl" ]; then
    echo "update-codex: ${plat}에 hash 선언 없음 — fast path를 건너뛰고 prefetch로 복구한다"
    missing_hash=1
  fi
done

if [ "$ver" = "$current" ] && [ "$force" = 0 ] && [ "$missing_hash" = 0 ]; then
  echo "이미 최신: codex $current ($tag) — 변경 없음"
  exit 0
fi

echo "codex $current → $ver ($tag) 갱신 중..."
base="https://github.com/$REPO/releases/download/$tag"

# 해시 컬럼 정렬 폭 = 현행 최장 asset 이름(codex-package-x86_64-unknown-linux-musl.tar.gz, 46자)+1.
# 재검증: jq -r '.platforms[].asset' modules/shared/programs/codex/codex-pin.json | awk '{print length}' | sort -rn | head -1
ASSET_COL=47

# 핀과 같은 디렉토리에 임시 파일을 만들어 최종 mv가 same-fs atomic rename이 되게 하고,
# trap으로 중단 시 잔재를 정리한다(핀 디렉토리는 git 추적 대상이라 누수 시 working tree 오염).
tmp="$(mktemp "$(dirname "$PIN")/.codex-pin.XXXXXX")"
# "$tmp".2는 아래 jq write-then-rename의 scratch sibling. trap이 둘 다 정리한다(아직 없으면 no-op).
trap 'rm -f "$tmp" "$tmp".2' EXIT
cp "$PIN" "$tmp"

# prefetch_asset <plat>
# 플랫폼 codex-package asset(platforms.<plat>.{asset,hash})의 핀 해시를 prefetch해 갱신한다.
# 선언 검사는 ensure_asset_decl이 소유한다.
prefetch_asset() {
  local plat="$1" asset h
  asset="$(ensure_asset_decl "$plat")"
  printf '  prefetch %-*s' "$ASSET_COL" "$asset"
  h="$(nix store prefetch-file --json "$base/$asset" 2>/dev/null | jq -r '.hash')" || {
    echo "FAIL"
    echo "update-codex: $asset prefetch 실패 — 릴리스에 codex-package asset이 없거나 네트워크 오류" >&2
    exit 1
  }
  echo "$h"
  jq --arg p "$plat" --arg h "$h" '.platforms[$p].hash = $h' "$tmp" >"$tmp".2 && mv "$tmp".2 "$tmp"
}

for plat in $(jq -r '.platforms | keys[]' "$PIN"); do
  prefetch_asset "$plat"
done
jq --arg v "$ver" --arg t "$tag" '.version=$v | .tag=$t' "$tmp" >"$tmp".2 && mv "$tmp".2 "$tmp"
mv "$tmp" "$PIN"
trap - EXIT
echo "✅ 핀 갱신 완료: codex $ver ($PIN)"

if [ "$do_build" = 1 ]; then
  if [ -x "$NRS_BIN" ]; then
    echo "▶ nrs 실행 (sudo는 NOPASSWD 규칙으로 자동 인증)..."
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
