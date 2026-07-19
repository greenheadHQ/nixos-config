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

  # curl config의 quoted string 문법에 맞춘 완전 escape — 역슬래시·큰따옴표를
  # 이스케이프하고 개행·CR·탭은 \n·\r·\t로 인코딩한다(curl이 unquote 시 복원).
  # 부분 escape는 multiline 메시지를 여러 config 행으로 쪼개 전송을 깨뜨린다.
  _pushover_cfg_escape() {
    local v="$1"
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    v="${v//$'\n'/\\n}"
    v="${v//$'\r'/\\r}"
    v="${v//$'\t'/\\t}"
    printf '%s' "$v"
  }

  {
    printf 'form-string = "token=%s"\n' "$(_pushover_cfg_escape "$PUSHOVER_TOKEN")"
    printf 'form-string = "user=%s"\n' "$(_pushover_cfg_escape "$PUSHOVER_USER")"
    printf 'form-string = "title=%s"\n' "$(_pushover_cfg_escape "$title")"
    printf 'form-string = "message=%s"\n' "$(_pushover_cfg_escape "$message")"
    printf 'form-string = "priority=%s"\n' "$(_pushover_cfg_escape "$priority")"
    if [ "$#" -ge 5 ]; then
      printf 'form-string = "sound=%s"\n' "$(_pushover_cfg_escape "$sound")"
    fi
  } | curl -q -sf --proto =https --max-time 10 --config - \
    https://api.pushover.net/1/messages.json > /dev/null 2>&1
}
