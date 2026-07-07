#!/usr/bin/env bash
set -euo pipefail

TOSS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOSS_SHARED_LIB_DIR=""
TOSS_LIB_DIR=""

TOSS_DEPLOYED_SHARED_LIB_DIR="$(cd "$TOSS_SCRIPT_DIR/.." && pwd)/lib"
TOSS_DEPLOYED_LIB_DIR="$TOSS_DEPLOYED_SHARED_LIB_DIR/toss"
TOSS_REPO_SHARED_LIB_DIR=""
TOSS_REPO_LIB_DIR=""
TOSS_HELPER_FILES=(
  "shared:file-lock.sh"
  "shared:pushover.sh"
  "toss:metadata.sh"
  "toss:curl.sh"
  "toss:auth.sh"
  "toss:ledger.sh"
  "toss:notify.sh"
  "toss:doctor.sh"
  "toss:api.sh"
)

case "$TOSS_SCRIPT_DIR" in
  */modules/shared/scripts)
    TOSS_REPO_SHARED_LIB_DIR="$TOSS_SCRIPT_DIR/lib"
    TOSS_REPO_LIB_DIR="$TOSS_SCRIPT_DIR/lib/toss"
    TOSS_DEFAULT_ENDPOINTS_FILE="${TOSS_ENDPOINTS_FILE:-$TOSS_SCRIPT_DIR/toss/endpoints.json}"
    ;;
  *)
    TOSS_DEFAULT_ENDPOINTS_FILE="${TOSS_ENDPOINTS_FILE:-$HOME/.local/share/toss/endpoints.json}"
    ;;
esac

toss_has_helper_set() {
  local shared_dir="$1"
  local toss_dir="$2"
  local helper scope file dir
  for helper in "${TOSS_HELPER_FILES[@]}"; do
    scope="${helper%%:*}"
    file="${helper#*:}"
    case "$scope" in
      shared) dir="$shared_dir" ;;
      toss) dir="$toss_dir" ;;
      *) return 1 ;;
    esac
    [ -f "$dir/$file" ] || return 1
  done
  return 0
}

if toss_has_helper_set "$TOSS_DEPLOYED_SHARED_LIB_DIR" "$TOSS_DEPLOYED_LIB_DIR"; then
  TOSS_SHARED_LIB_DIR="$TOSS_DEPLOYED_SHARED_LIB_DIR"
  TOSS_LIB_DIR="$TOSS_DEPLOYED_LIB_DIR"
elif [ -n "$TOSS_REPO_SHARED_LIB_DIR" ] && toss_has_helper_set "$TOSS_REPO_SHARED_LIB_DIR" "$TOSS_REPO_LIB_DIR"; then
  TOSS_SHARED_LIB_DIR="$TOSS_REPO_SHARED_LIB_DIR"
  TOSS_LIB_DIR="$TOSS_REPO_LIB_DIR"
fi

if [ -z "$TOSS_LIB_DIR" ]; then
  echo "error: toss helper directory not found" >&2
  exit 1
fi

export TOSS_SHARED_LIB_DIR
export TOSS_DEFAULT_ENDPOINTS_FILE

for helper in "${TOSS_HELPER_FILES[@]}"; do
  scope="${helper%%:*}"
  file="${helper#*:}"
  case "$scope" in
    shared) helper_path="$TOSS_SHARED_LIB_DIR/$file" ;;
    toss) helper_path="$TOSS_LIB_DIR/$file" ;;
    *) echo "error: unknown toss helper scope: $scope" >&2; exit 1 ;;
  esac
  # shellcheck source=/dev/null
  source "$helper_path"
done

toss_usage() {
  cat <<'EOF'
usage: toss <command> [args]

commands:
  token [--force]                         issue or reuse a cached access token
  api <METHOD> <PATH> [options]           call a Toss OpenAPI endpoint
  accounts                                list accounts and cache the default account sequence
  doctor                                  run non-destructive environment diagnostics

api options:
  --account ACCOUNT_SEQ
  --data JSON
  --dry-run
  --no-notify
EOF
}

case "${1:-}" in
  token)
    shift
    toss_cmd_token "$@"
    ;;
  api)
    shift
    toss_cmd_api "$@"
    ;;
  accounts)
    shift
    toss_cmd_accounts "$@"
    ;;
  doctor)
    shift
    toss_cmd_doctor "$@"
    ;;
  -h|--help|"")
    toss_usage
    ;;
  *)
    echo "error: unknown toss command: $1" >&2
    toss_usage >&2
    exit 2
    ;;
esac
