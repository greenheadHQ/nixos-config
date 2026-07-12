#!/usr/bin/env bash
set -euo pipefail

toss_metadata_file() {
  local file="${TOSS_ENDPOINTS_FILE:-${TOSS_DEFAULT_ENDPOINTS_FILE:-$HOME/.local/share/toss/endpoints.json}}"
  if [ ! -f "$file" ]; then
    echo "error: Toss endpoint metadata not found: $file" >&2
    return 1
  fi
  printf '%s\n' "$file"
}

# exact/template lookup 결과(stdin JSON)에 공통 메타를 붙인다. 두 경로가 metadataStatus만
# 다르고 나머지가 동일하므로 단일 helper로 두어, 특히 order-safeguard hard floor 판정이 두
# lookup 경로에서 갈리지 않게 한다.
#
# requiresOrderSafeguards runtime hard floor: metadata의 isKnownOrderMutation을 신뢰하되,
# order-path(/orders·/conditional-orders) + mutation method(POST/PUT/PATCH/DELETE)이면
# metadata와 무관하게 항상 safeguard를 켠다. TOSS_ENDPOINTS_FILE로 분류표를 변조해 주문
# mutation의 원장/알림/preflight를 조용히 끄는 우회를 이 floor로 차단한다.
# generate-endpoint-metadata.sh의 is_known_order_mutation order-path 규칙과 동형.
toss_metadata_decorate() {
  local status="$1"
  local method="$2"
  local path="$3"
  jq -c --arg method "$method" --arg path "$path" --arg status "$status" '
    def is_order_path($p): $p | test("(^|/)(orders|conditional-orders)(/|$)");
    def is_mutation_method($m): (["POST","PUT","PATCH","DELETE"] | index($m)) != null;
    def order_safeguard_floor($m; $p): is_mutation_method($m) and is_order_path($p);
    . + {
      metadataStatus: $status,
      matchedPath: .path,
      requiresOrderSafeguards: ((.isKnownOrderMutation == true) or order_safeguard_floor($method; $path))
    }
  '
}

toss_metadata_lookup() {
  if [ "$#" -ne 2 ]; then
    echo "usage: toss_metadata_lookup <METHOD> <PATH>" >&2
    return 2
  fi

  local method="$1"
  local request_path="$2"
  local path="${request_path%%\?*}"
  local file
  method="$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')"
  file="$(toss_metadata_file)"

  local found
  found="$(
    jq -c --arg method "$method" --arg path "$path" '
      first(.endpoints[] | select(.method == $method and .path == $path)) // empty
    ' "$file"
  )"

  if [ -n "$found" ]; then
    toss_metadata_decorate "exact" "$method" "$path" <<<"$found"
    return 0
  fi

  found="$(
    jq -c --arg method "$method" --arg path "$path" '
      first(
        .endpoints[]
        | select(.method == $method)
        | . as $endpoint
        | select($path | test($endpoint.pathRegex))
      ) // empty
    ' "$file"
  )"

  if [ -n "$found" ]; then
    toss_metadata_decorate "template" "$method" "$path" <<<"$found"
    return 0
  fi

  jq -cn \
    --arg method "$method" \
    --arg path "$path" \
    '{
      metadataStatus: "unknown",
      method: $method,
      path: $path,
      matchedPath: null,
      operationId: null,
      requiresAccount: false,
      rateLimitGroup: null,
      pathRegex: null,
      isKnownOrderMutation: false,
      requiresOrderSafeguards: true
    }'
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  toss_metadata_lookup "$@"
fi
