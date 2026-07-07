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
    jq -c '
      . + {
        metadataStatus: "exact",
        matchedPath: .path,
        requiresOrderSafeguards: (.isKnownOrderMutation == true)
      }
    ' <<<"$found"
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
    jq -c '
      . + {
        metadataStatus: "template",
        matchedPath: .path,
        requiresOrderSafeguards: (.isKnownOrderMutation == true)
      }
    ' <<<"$found"
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
