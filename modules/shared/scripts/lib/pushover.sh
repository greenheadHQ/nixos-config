# shellcheck shell=bash
# Shared Pushover transport helper.
# Callers decide whether a failed notification is fatal or best-effort.

pushover_send() {
  local cred_file="$1"
  local title="$2"
  local message="$3"
  local priority="$4"
  local sound="${5-}"
  local PUSHOVER_TOKEN=""
  local PUSHOVER_USER=""

  [ -r "$cred_file" ] || return 1

  # shellcheck source=/dev/null
  if ! source "$cred_file" 2>/dev/null; then
    return 1
  fi

  [ -n "${PUSHOVER_TOKEN:-}" ] || return 1
  [ -n "${PUSHOVER_USER:-}" ] || return 1

  if [ "$#" -ge 5 ]; then
    curl -sf --proto =https --max-time 10 \
      --form-string "token=${PUSHOVER_TOKEN}" \
      --form-string "user=${PUSHOVER_USER}" \
      --form-string "title=${title}" \
      --form-string "message=${message}" \
      --form-string "priority=${priority}" \
      --form-string "sound=${sound}" \
      https://api.pushover.net/1/messages.json > /dev/null 2>&1
  else
    curl -sf --proto =https --max-time 10 \
      --form-string "token=${PUSHOVER_TOKEN}" \
      --form-string "user=${PUSHOVER_USER}" \
      --form-string "title=${title}" \
      --form-string "message=${message}" \
      --form-string "priority=${priority}" \
      https://api.pushover.net/1/messages.json > /dev/null 2>&1
  fi
}
