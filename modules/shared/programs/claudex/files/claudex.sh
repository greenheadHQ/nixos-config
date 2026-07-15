#!@bashBin@
# shellcheck shell=bash
# shellcheck disable=SC2034
set -euo pipefail
umask 077

# shellcheck source=/dev/null
source "@runtimeLibrary@"
CLAUDEX_CONFIG_TEMPLATE="@configTemplate@"
CLAUDEX_WRAPPER_SETTINGS="@wrapperSettings@"
CLAUDEX_WRAPPER_SETTINGS_FAST="@wrapperSettingsFast@"
CLAUDEX_MAX_CONTEXT_TOKENS="@maxContextTokens@"

# Effort stays wrapper-owned: the inherited CLAUDE_CODE_EFFORT_LEVEL is scrubbed below and
# only an explicit, whitelist-validated `claudex --effort <level>` argument may change the
# session level. The wrapper consumes the argument and re-issues it as its own CLI value so
# a single deterministic `--effort` reaches Claude.
effort_level=high
fast_tier=false
expect_effort_value=false
forward_args=()
scan_options=true
for arg in "$@"; do
  if [ "$scan_options" = false ]; then
    forward_args+=("$arg")
    continue
  fi
  if [ "$expect_effort_value" = true ]; then
    effort_level="$arg"
    expect_effort_value=false
    continue
  fi
  if [ "$arg" = "--" ]; then
    scan_options=false
    forward_args+=("$arg")
    continue
  fi
  case "$arg" in
    --model | --model=* | --fallback-model | --fallback-model=* | --settings | --settings=* | --setting-sources | --setting-sources=* | --permission-mode | --permission-mode=*)
      _claudex_error "option is managed by the claudex host wrapper: $arg"
      exit 2
      ;;
    --effort)
      expect_effort_value=true
      ;;
    --effort=*)
      effort_level="${arg#--effort=}"
      ;;
    --fast)
      fast_tier=true
      ;;
    --fast=*)
      _claudex_error "--fast does not accept a value (the Codex fast tier is a boolean session flag)"
      exit 2
      ;;
    *)
      forward_args+=("$arg")
      ;;
  esac
done
if [ "$expect_effort_value" = true ]; then
  _claudex_error "--effort requires a value: low, medium, high, xhigh, max, ultra"
  exit 2
fi
case "$effort_level" in
  low | medium | high | xhigh | max | ultra) ;;
  *)
    _claudex_error "invalid --effort level: $effort_level (allowed: low, medium, high, xhigh, max, ultra)"
    exit 2
    ;;
esac
# The pinned CLI validates --effort argv values (low..max) and warns-then-ignores unknown
# ones, while CLAUDE_CODE_EFFORT_LEVEL is forwarded unvalidated for the backend to
# interpret. ultra is a backend-recognized level for the pinned model, so it travels via
# the wrapper-owned environment value only — passing it as argv would be warn-then-ignored.
effort_argv=(--effort "$effort_level")
if [ "$effort_level" = ultra ]; then
  effort_argv=()
fi

# CIR: the Codex fast tier is wrapper-owned request-body state. The pinned Claude CLI has
# no argv for it (Claude's own fastMode is a separate Anthropic-direct-only feature that
# never activates on this loopback provider), so the only channel is the wrapper-owned
# settings file feeding CLAUDE_CODE_EXTRA_BODY. `--fast` selects between two pinned Nix
# store settings variants; the inherited CLAUDE_CODE_EXTRA_BODY environment stays scrubbed
# either way, so hostile request-body overrides remain neutralized. The backend applies the
# tier only when the OAuth account is entitled and silently falls back to the default tier
# otherwise (documented limitation; no in-wrapper detection because the wrapper exec()s).
if [ "$fast_tier" = true ]; then
  CLAUDEX_WRAPPER_SETTINGS="$CLAUDEX_WRAPPER_SETTINGS_FAST"
fi

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
# model, effort, request body, transport, or network proxy. Provider variables
# embedded in settings files are separately disabled by CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST,
# leaving ordinary ~/.claude settings untouched.
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
  ANTHROPIC_UNIX_SOCKET \
  ANTHROPIC_VERTEX_BASE_URL \
  ANTHROPIC_VERTEX_PROJECT_ID \
  AWS_BEARER_TOKEN_BEDROCK \
  CLAUDE_CODE_HFI_BEARER_TOKEN \
  CLAUDE_CODE_HOST_AUTH_ENV_VAR \
  CLAUDE_CODE_HOST_AUTH_REFRESH_TIMEOUT_MS \
  CLAUDE_CODE_HOST_CREDS_FILE \
  CLAUDE_CODE_HOST_HTTP_PROXY_PORT \
  CLAUDE_CODE_HOST_PLATFORM \
  CLAUDE_CODE_HOST_SOCKS_PROXY_PORT \
  CLAUDE_CODE_SKIP_FOUNDRY_AUTH \
  CLAUDE_CODE_SKIP_MANTLE_AUTH \
  CLAUDE_CODE_SKIP_VERTEX_AUTH \
  CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH \
  CLAUDE_CODE_AUTO_COMPACT_WINDOW \
  CLAUDE_CODE_EFFORT_LEVEL \
  CLAUDE_CODE_EXTRA_BODY \
  CLAUDE_CODE_MAX_CONTEXT_TOKENS \
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
# CIR: SUBPROCESS_ENV_SCRUB is explicitly opted out (0). When set to 1, the pinned CLI's
# allowed_non_write_users hardening forces the permission mode back to default, which
# silently defeats --dangerously-skip-permissions (measured on 2.1.210). The user chose
# always-bypass sessions over subprocess env scrubbing; the residual exposure is the
# wrapper-owned loopback API key becoming visible to in-session subprocesses, which is a
# loopback-only credential confined to 127.0.0.1:8317.
export CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0
export CLAUDE_CODE_SUBAGENT_MODEL="$CLAUDEX_MODEL"
export CLAUDE_CODE_ALWAYS_ENABLE_EFFORT=1
export CLAUDE_CODE_EFFORT_LEVEL="$effort_level"
# CIR: the pinned CLI assumes a 200k context window for unrecognized model names, and the
# pinned proxy hard-codes usage 0/0 into SSE message_start (upstream declined to fix), which
# forces the CLI's context tracking onto an overestimating character-based fallback — the
# statusline then saturates at "100% context used" early. This official non-claude-model
# override corrects the denominator to the limit the Codex app currently reports (a
# temporary upstream reduction from 372k; re-tune when OpenAI raises it back — see the
# value's CIR in default.nix). The numerator stays a local estimate, so the displayed
# percentage is an approximation (handoff limits section).
export CLAUDE_CODE_MAX_CONTEXT_TOKENS="$CLAUDEX_MAX_CONTEXT_TOKENS"
# CIR: MAX_CONTEXT_TOKENS alone only fixes the displayed denominator. The pinned CLI keeps
# auto-compact disabled whenever the compact window's *source* resolves to "auto" (local
# sessions guard), which is always the case for unrecognized model names without an
# explicit window channel — so claudex sessions never auto-compacted (measured on 2.1.210;
# the "N% context used" statusline label, instead of "N% until auto-compact", is the visible
# symptom). CLAUDE_CODE_AUTO_COMPACT_WINDOW is the CLI's official env channel that flips the
# source to "env" and re-enables the compact threshold check. It shares the same
# wrapper-owned value so the issue #1113 re-tune stays single-sourced.
export CLAUDE_CODE_AUTO_COMPACT_WINDOW="$CLAUDEX_MAX_CONTEXT_TOKENS"
export CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=3
export ENABLE_TOOL_SEARCH=false
export NO_PROXY="$CLAUDEX_NO_PROXY"
export no_proxy="$CLAUDEX_NO_PROXY"

# An explicitly empty CLI fallback list has higher precedence than fallbackModel loaded from
# ordinary settings and resolves to no fallback in the pinned Claude Code CLI.
# CIR: --dangerously-skip-permissions is deliberate. The pinned CLI can only enter
# bypassPermissions when it is enabled at startup (no mid-session switch without the flag),
# and the user decided claudex sessions always start in bypass mode. Removing the flag
# restores normal permission prompts but also removes the mid-session bypass option.
exec "$claude_bin" \
  --settings "$CLAUDEX_WRAPPER_SETTINGS" \
  --model "$CLAUDEX_MODEL" \
  --fallback-model "" \
  "${effort_argv[@]}" \
  --dangerously-skip-permissions \
  "${forward_args[@]}"
