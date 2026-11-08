# shellcheck shell=bash
# shellcheck disable=SC2154
# Caddy 배포 본체를 실행하며 자격·소유권 변경만 합성 입력과 대역으로 격리한다.

_caddy_credentials_setup() {
  local sandbox="$1"
  mkdir -p "$sandbox/runtime 'quoted' dir"
  printf '%s\n' 'synthetic-caddy-token' > "$sandbox/token"
  printf '%s\n' 'unrelated temporary file' > "$sandbox/runtime 'quoted' dir/env file.tmp.keep"
  cp "$sandbox/runtime 'quoted' dir/env file.tmp.keep" "$sandbox/neighbor-before"
  : > "$sandbox/audit"
  : > "$sandbox/chown"
  cat > "$sandbox/run.sh" <<'FIXTURE'
#!/usr/bin/env bash
# 넓은 시작 umask에서도 본체가 자격 파일을 비공개로 만들어야 한다.
umask 022
observe() {
  python3 - "$1" "$2" "$CADDY_AUDIT" <<'PY'
import json
import os
import sys
st = os.stat(sys.argv[2])
with open(sys.argv[3], "a") as output:
    output.write(json.dumps({"step": sys.argv[1], "mode": st.st_mode & 0o777}) + "\n")
PY
}
cat() {
  [ "$CADDY_FAILURE" != read ] || return 71
  command cat "$@"
}
mktemp() {
  [ "$CADDY_FAILURE" != create ] || return 72
  local created
  created=$(command mktemp "$@") || return
  observe created "$created" || return
  builtin printf '%s\n' "$created"
}
printf() {
  if [ "$1" = 'CLOUDFLARE_API_TOKEN=%s\n' ]; then
    # 리다이렉트로 연 직후, 내용을 쓰기 전의 권한도 관측한다.
    observe writing "${temp_file:-$CADDY_ENV_FILE}" || return
    if [ "$CADDY_FAILURE" = write ]; then
      builtin printf '%s' 'synthetic partial write'
      return 73
    fi
  fi
  builtin printf "$@"
}
chmod() {
  [ "$CADDY_FAILURE" != mode ] || return 74
  command chmod "$@" || return
  observe mode "${!#}"
}
chown() {
  [ "$CADDY_FAILURE" != owner ] || return 75
  [ "$1" = caddy:caddy ] || return 99
  # 실제 사용자 소유권은 바꾸지 않고 요청된 소유자와 순서를 기록한다.
  builtin printf '%s\n' "$1" >> "$CADDY_CHOWN_LOG"
  observe owner "${!#}"
}
mv() {
  [ "$CADDY_FAILURE" != replace ] || return 76
  observe replace "${@: -2:1}" || return
  command mv "$@"
}
rm() {
  [ "${CADDY_CLEANUP_FAIL:-0}" != 1 ] || return 77
  command rm "$@"
}
# shellcheck source=/dev/null
source "$CADDY_SOURCE"
FIXTURE
}

_caddy_credentials_run() {
  local sandbox="$1" failure="${2:-}" cleanup_fail="${3:-0}"
  CADDY_TOKEN_FILE="$sandbox/token" \
    CADDY_ENV_FILE="$sandbox/runtime 'quoted' dir/env file" \
    CADDY_AUDIT="$sandbox/audit" CADDY_CHOWN_LOG="$sandbox/chown" \
    CADDY_SOURCE="$REPO_ROOT/modules/nixos/programs/caddy-env/files/generate-env.sh" \
    CADDY_FAILURE="$failure" CADDY_CLEANUP_FAIL="$cleanup_fail" \
    bash "$sandbox/run.sh" > "$sandbox/output" 2>&1
}

_caddy_credentials_neighbors_preserved() {
  local sandbox="$1"
  cmp -s "$sandbox/runtime 'quoted' dir/env file.tmp.keep" "$sandbox/neighbor-before" \
    || fail "이웃 임시 파일의 전체 내용이 보존되어야 한다"
  [[ "$(find "$sandbox/runtime 'quoted' dir" -maxdepth 1 -name '*.tmp.*' | wc -l)" -eq 1 ]] \
    || fail "이번 실행의 임시 파일만 정리되어야 한다"
  assert_not_contains "$(cat "$sandbox/output")" 'synthetic-caddy-token'
}

test_caddy_credentials_private_atomic_creation_and_replacement() {
  local previous sandbox output
  for previous in absent existing; do
    sandbox="$(new_sandbox)"
    _caddy_credentials_setup "$sandbox"
    output="$sandbox/runtime 'quoted' dir/env file"
    if [ "$previous" = existing ]; then
      printf '%s\n' 'previous synthetic content' > "$output"
      chmod 0600 "$output"
    fi
    _caddy_credentials_run "$sandbox" || fail "정상 생성·교체 실패: $previous"
    printf '%s\n' 'CLOUDFLARE_API_TOKEN=synthetic-caddy-token' > "$sandbox/expected"
    cmp -s "$output" "$sandbox/expected" || fail "환경변수 내용이 정확히 일치해야 한다"
    [[ "$(stat -c %a "$output")" = 400 ]] || fail "최종 권한은 0400이어야 한다"
    assert_file_contains "$sandbox/chown" 'caddy:caddy'
    python3 - "$sandbox/audit" <<'PY'
import json
import sys
with open(sys.argv[1]) as source:
    events = [json.loads(line) for line in source]
assert [event["step"] for event in events] == ["created", "writing", "mode", "owner", "replace"]
assert [event["mode"] for event in events] == [0o600, 0o600, 0o400, 0o400, 0o400]
PY
    _caddy_credentials_neighbors_preserved "$sandbox"
  done
}

test_caddy_credentials_failure_preserves_previous_file() {
  local previous failure sandbox output before after rc expected
  for previous in absent existing; do
    for failure in read create write mode owner replace; do
      sandbox="$(new_sandbox)"
      _caddy_credentials_setup "$sandbox"
      output="$sandbox/runtime 'quoted' dir/env file"
      if [ "$previous" = existing ]; then
        printf '%s\n' 'previous synthetic content' > "$output"
        chmod 0600 "$output"
        cp "$output" "$sandbox/previous"
        before="$(stat -c '%u:%g:%a' "$output")"
      fi
      rc=0
      _caddy_credentials_run "$sandbox" "$failure" || rc=$?
      case "$failure" in
        read) expected=71 ;;
        create) expected=72 ;;
        write) expected=73 ;;
        mode) expected=74 ;;
        owner) expected=75 ;;
        replace) expected=76 ;;
      esac
      [[ "$rc" -eq "$expected" ]] || fail "$previous/$failure 실패 코드 보존 실패: $rc"
      if [ "$previous" = existing ]; then
        cmp -s "$output" "$sandbox/previous" || fail "$failure 이후 기존 파일 내용이 바뀌었다"
        after="$(stat -c '%u:%g:%a' "$output")"
        [[ "$before" = "$after" ]] || fail "$failure 이후 기존 권한·소유권이 바뀌었다"
      else
        [[ ! -e "$output" ]] || fail "$failure 이후 실패한 최종 파일이 남았다"
      fi
      _caddy_credentials_neighbors_preserved "$sandbox"
    done
  done
}

test_caddy_credentials_rejects_directory_destination() {
  local sandbox output rc=0
  sandbox="$(new_sandbox)"
  _caddy_credentials_setup "$sandbox"
  output="$sandbox/runtime 'quoted' dir/env file"
  mkdir "$output"
  printf '%s\n' 'protected directory content' > "$output/preserve"
  _caddy_credentials_run "$sandbox" || rc=$?
  # 이전 구현은 디렉터리까지 0400으로 바꿨다. 실패 fixture 자체의 정리는 가능하게 한다.
  chmod u+rwx "$output"
  [[ "$rc" -ne 0 ]] || fail "디렉터리를 최종 파일로 받아들이면 안 된다"
  assert_file_contains "$output/preserve" 'protected directory content'
  [[ "$(find "$output" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ]] \
    || fail "최종 디렉터리 내부에 임시 파일을 옮기면 안 된다"
  _caddy_credentials_neighbors_preserved "$sandbox"
}

test_caddy_credentials_replaces_symlink_without_touching_target() {
  local sandbox output
  sandbox="$(new_sandbox)"
  _caddy_credentials_setup "$sandbox"
  output="$sandbox/runtime 'quoted' dir/env file"
  printf '%s\n' 'protected symlink target' > "$sandbox/target"
  chmod 0600 "$sandbox/target"
  cp "$sandbox/target" "$sandbox/target-before"
  ln -s "$sandbox/target" "$output"
  _caddy_credentials_run "$sandbox" || fail "symlink 경로 교체 실패"
  [[ ! -L "$output" && -f "$output" ]] || fail "최종 경로만 일반 파일로 교체해야 한다"
  cmp -s "$sandbox/target" "$sandbox/target-before" || fail "symlink 대상 내용이 바뀌었다"
  [[ "$(stat -c %a "$sandbox/target")" = 600 ]] || fail "symlink 대상 권한이 바뀌었다"
  _caddy_credentials_neighbors_preserved "$sandbox"
}

test_caddy_credentials_cleanup_failure_preserves_original_status() {
  local sandbox rc=0
  sandbox="$(new_sandbox)"
  _caddy_credentials_setup "$sandbox"
  _caddy_credentials_run "$sandbox" mode 1 || rc=$?
  [[ "$rc" -eq 74 ]] || fail "정리 실패가 원래 실패 코드를 덮으면 안 된다"
  assert_contains "$(cat "$sandbox/output")" 'temporary file cleanup failed'
  assert_not_contains "$(cat "$sandbox/output")" 'synthetic-caddy-token'
  [[ ! -e "$sandbox/runtime 'quoted' dir/env file" ]] || fail "실패한 최종 파일이 남았다"
  cmp -s "$sandbox/runtime 'quoted' dir/env file.tmp.keep" "$sandbox/neighbor-before" \
    || fail "정리 실패 뒤에도 이웃 파일은 보존되어야 한다"
}
