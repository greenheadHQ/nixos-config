#!@bashBin@
# shellcheck shell=bash
# shellcheck disable=SC2034
set -euo pipefail
umask 077

# shellcheck source=/dev/null
source "@runtimeLibrary@"
CLAUDEX_CONFIG_TEMPLATE="@configTemplate@"

scan_options=true
for arg in "$@"; do
  if [ "$scan_options" = false ]; then
    continue
  fi
  if [ "$arg" = "--" ]; then
    scan_options=false
    continue
  fi
  case "$arg" in
    --model | --model=* | --fallback-model | --fallback-model=* | --effort | --effort=* | --settings | --settings=* | --setting-sources | --setting-sources=*)
      _claudex_error "option is managed by the claudex host wrapper: $arg"
      exit 2
      ;;
  esac
done

prepare_state
assert_single_codex_credential
wait_for_proxy_ready
catalog="$(curl_loopback /v1/models)"
if ! "$CLAUDEX_JQ" -e --arg model "$CLAUDEX_MODEL" \
  '.data | type == "array" and any(.id == $model)' <<< "$catalog" >/dev/null; then
  _claudex_error "declared model is absent from the proxy catalog (catalog is not an entitlement check)"
  exit 1
fi

claude_bin="$CLAUDEX_HOME/.local/bin/claude"
if [ ! -x "$claude_bin" ]; then
  _claudex_error "Claude Code is missing or not executable at $claude_bin"
  exit 1
fi
api_key="$(_claudex_read_api_key)"

# Prevent inherited process variables from selecting another provider, endpoint, credential,
# model, or network proxy. CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST also makes provider variables
# embedded in settings files inapplicable, leaving ordinary ~/.claude settings untouched.
unset \
  ANTHROPIC_API_KEY \
  ANTHROPIC_AUTH_TOKEN \
  ANTHROPIC_AWS_API_KEY \
  ANTHROPIC_AWS_BASE_URL \
  ANTHROPIC_AWS_WORKSPACE_ID \
  ANTHROPIC_BASE_URL \
  ANTHROPIC_BEDROCK_BASE_URL \
  ANTHROPIC_BEDROCK_MANTLE_BASE_URL \
  ANTHROPIC_BEDROCK_SERVICE_TIER \
  ANTHROPIC_CUSTOM_HEADERS \
  ANTHROPIC_CUSTOM_MODEL_OPTION \
  ANTHROPIC_DEFAULT_FABLE_MODEL \
  ANTHROPIC_DEFAULT_HAIKU_MODEL \
  ANTHROPIC_DEFAULT_OPUS_MODEL \
  ANTHROPIC_DEFAULT_SONNET_MODEL \
  ANTHROPIC_FOUNDRY_API_KEY \
  ANTHROPIC_FOUNDRY_AUTH_TOKEN \
  ANTHROPIC_FOUNDRY_BASE_URL \
  ANTHROPIC_FOUNDRY_RESOURCE \
  ANTHROPIC_MODEL \
  ANTHROPIC_SMALL_FAST_MODEL \
  ANTHROPIC_VERTEX_BASE_URL \
  ANTHROPIC_VERTEX_PROJECT_ID \
  AWS_BEARER_TOKEN_BEDROCK \
  CLAUDE_CODE_SKIP_FOUNDRY_AUTH \
  CLAUDE_CODE_SKIP_MANTLE_AUTH \
  CLAUDE_CODE_SKIP_VERTEX_AUTH \
  CLAUDE_CODE_USE_ANTHROPIC_AWS \
  CLAUDE_CODE_USE_BEDROCK \
  CLAUDE_CODE_USE_FOUNDRY \
  CLAUDE_CODE_USE_MANTLE \
  CLAUDE_CODE_USE_VERTEX \
  HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY \
  http_proxy https_proxy all_proxy no_proxy

export ANTHROPIC_BASE_URL="$CLAUDEX_BASE_URL"
export ANTHROPIC_AUTH_TOKEN="$api_key"
export HOME="$CLAUDEX_HOME"
export CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST=1
export CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1
export CLAUDE_CODE_SUBAGENT_MODEL="$CLAUDEX_MODEL"
export CLAUDE_CODE_ALWAYS_ENABLE_EFFORT=1
export CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=3
export ENABLE_TOOL_SEARCH=false
export NO_PROXY="127.0.0.1,localhost"
export no_proxy="127.0.0.1,localhost"

exec "$claude_bin" \
  --model "$CLAUDEX_MODEL" \
  --effort high \
  "$@"
