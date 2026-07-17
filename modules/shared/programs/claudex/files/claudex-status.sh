#!@bashBin@
# shellcheck shell=bash
set -euo pipefail

# shellcheck source=/dev/null
source "@runtimeLibrary@"

if [ "$#" -ne 0 ]; then
  echo "usage: claudex-status" >&2
  exit 2
fi

service_state="missing"
auth_state="missing"
proxy_state="unreachable"
catalog_state="unavailable"

domain="gui/$($CLAUDEX_ID -u)"
if "$CLAUDEX_LAUNCHCTL" print "$domain/$CLAUDEX_LABEL" >/dev/null 2>&1; then
  service_state="present"
fi

if [ -d "$CLAUDEX_AUTH_DIR" ] && [ ! -L "$CLAUDEX_AUTH_DIR" ]; then
  count="$(credential_count 2>/dev/null || printf 'invalid')"
  if [ "$count" != "0" ]; then
    # The default set contract (codex exactly 1, claude at most 1) is the readiness bar;
    # a mixed-capable set is a valid superset, so status stays mode-agnostic.
    if assert_credential_set "$CLAUDEX_AUTH_DIR" default >/dev/null 2>&1; then
      auth_state="ready"
    else
      auth_state="invalid"
    fi
  fi
fi

if [ "$auth_state" = "ready" ] && payload="$(curl_loopback /v1/models 2>/dev/null)"; then
  if "$CLAUDEX_JQ" -e '.data | type == "array"' <<< "$payload" >/dev/null 2>&1; then
    proxy_state="ready"
    if "$CLAUDEX_JQ" -e --arg model "$CLAUDEX_DEFAULT_MAIN_MODEL" \
      '.data | any(.id == $model)' <<< "$payload" >/dev/null 2>&1; then
      catalog_state="ready"
    else
      catalog_state="missing"
    fi
  else
    proxy_state="invalid"
    catalog_state="invalid"
  fi
fi

printf 'service=%s\n' "$service_state"
printf 'auth=%s\n' "$auth_state"
printf 'proxy=%s\n' "$proxy_state"
printf 'catalog=%s\n' "$catalog_state"

if [ "$auth_state" = "ready" ] \
  && [ "$proxy_state" = "ready" ] \
  && [ "$catalog_state" = "ready" ]; then
  exit 0
fi
exit 1
