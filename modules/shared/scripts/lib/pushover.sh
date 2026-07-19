# shellcheck shell=bash
# Shared Pushover transport helper.
# Callers decide whether a failed notification is fatal or best-effort.
#
# 자격(token/user)은 curl argv에 싣지 않는다 — 프로세스 명령행은 같은 호스트의
# 다른 프로세스가 /proc/<pid>/cmdline으로 읽을 수 있다. `--config -`로 stdin을
# 통해 전달한다 (claudex-runtime의 기존 선례와 동일 패턴).

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

  {
    # curl config 문법: 값의 큰따옴표는 \"로 이스케이프해야 한다.
    printf 'form-string = "token=%s"\n' "${PUSHOVER_TOKEN//\"/\\\"}"
    printf 'form-string = "user=%s"\n' "${PUSHOVER_USER//\"/\\\"}"
    printf 'form-string = "title=%s"\n' "${title//\"/\\\"}"
    printf 'form-string = "message=%s"\n' "${message//\"/\\\"}"
    printf 'form-string = "priority=%s"\n' "${priority//\"/\\\"}"
    if [ "$#" -ge 5 ]; then
      printf 'form-string = "sound=%s"\n' "${sound//\"/\\\"}"
    fi
  } | curl -sf --proto =https --max-time 10 -q --config - \
    https://api.pushover.net/1/messages.json > /dev/null 2>&1
}
