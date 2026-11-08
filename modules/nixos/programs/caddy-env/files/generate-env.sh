# shellcheck shell=bash
# Caddy 환경 파일 생성. 입력 경로는 caddy.nix에서 주입한다.
# 디버그 셸의 추적·자동 export를 상속해도 자격을 출력하거나 자식 환경에 넣지 않는다.
set +x
set +a
set -euo pipefail
umask 077
unset caddy_token
: "${CADDY_TOKEN_FILE:?}" "${CADDY_ENV_FILE:?}"

temp_file=""
cleanup_caddy_env() {
  local rc=$?
  trap - EXIT
  if [ -n "$temp_file" ] && ! rm -f -- "$temp_file"; then
    printf '%s\n' 'caddy-env: temporary file cleanup failed' >&2
    [ "$rc" -ne 0 ] || rc=1
  fi
  exit "$rc"
}
trap cleanup_caddy_env EXIT

env_dir="$(dirname -- "$CADDY_ENV_FILE")"
mkdir -p -- "$env_dir"
caddy_token="$(cat -- "$CADDY_TOKEN_FILE")"
# 같은 디렉터리의 배타적 파일을 처음부터 0600으로 만든다. 기존 최종 파일은 열지 않는다.
temp_file="$(mktemp -- "${CADDY_ENV_FILE}.tmp.XXXXXXXX")"
printf 'CLOUDFLARE_API_TOKEN=%s\n' "$caddy_token" > "$temp_file"
unset caddy_token
chmod 0400 "$temp_file"
chown caddy:caddy "$temp_file"
# 목적지가 디렉터리여도 그 안으로 이동하지 않고 실패해야 한다. GNU coreutils를 사용한다.
mv -fT -- "$temp_file" "$CADDY_ENV_FILE"
temp_file=""
