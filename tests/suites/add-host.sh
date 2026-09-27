# shellcheck shell=bash
# SC2154: REPO_ROOT/FIXTURE_DIR/TEST_TMP_FILE·new_sandbox·fail·assert_*는 aggregator가
#   test-common.sh를 먼저 source한 뒤 이 파일을 source해 정의한다(shellcheck는 이 순서를
#   모른다). tests/shell-script-tests.sh 헤더의 동일 disable과 같은 사유.
# shellcheck disable=SC2154
# tests/suites/add-host.sh — scripts/add-host.sh NixOS 분기 fixture (#1382)
#
# 실제 저장소의 hosts/·flake.nix는 건드리지 않는다. 매번 새 sandbox에 REPO_ROOT의
# scripts/add-host.sh를 복사해 "$sandbox/repo"를 마법사의 ROOT_DIR로 쓰게 한다
# (add-host.sh가 SCRIPT_DIR의 부모를 ROOT_DIR로 잡으므로 scripts/ 옆에 두면 그대로 성립).
#
# 재사용 범위: 이 파일의 _add_host_* 헬퍼는 NixOS 분기(stdin 순서 "2\n호스트명\n사용자명\n
# 유형\n공개키\nconfirm")를 다루는 다른 스위트가 그대로 부를 수 있다(_add_host_run 뒤
# $_add_host_stdout을 보면 됨). 시크릿 recipient 안내(#1396)는 합성 규칙 파일을 두는
# _add_host_run_with_synthetic_rules로 검증한다. darwin 분기용 stdin 조립 헬퍼나
# libraries/constants.nix 안내를 검증하는 fixture는 이 파일에 없다 — 필요한 스위트가 별도로
# 추가해야 한다.
#   - _add_host_prepare_sandbox SANDBOX           : repo/scripts/add-host.sh 배치
#   - _add_host_nixos_stdin HOST USER TYPE KEY CONFIRM : NixOS 분기 stdin 조립
#   - _add_host_run SANDBOX STDIN [EXTRA_PATH]    : 실행, stdout/stderr/rc를 전역에 채움
#     (결과: _add_host_stdout, _add_host_stderr, _add_host_rc)
#   - _add_host_default_nix_path SANDBOX HOST      : 생성될 default.nix의 경로 문자열
#   - _add_host_write_expected_default_nix HOST OUT : 기대 템플릿을 OUT에 씀
#   - _add_host_install_failing_stub STUB_DIR NAME : 이름이 NAME인 실행 파일을 호출하면
#     항상 실패(로그 남김)하는 대역으로 설치
#   - _add_host_install_failing_printf_bash_env OUT : printf를 항상 실패시키는 BASH_ENV
#     파일을 OUT에 써서, _add_host_run 호출 앞에 `BASH_ENV="$out" _add_host_run …`으로
#     주입할 수 있게 한다
#   - _add_host_write_synthetic_rules KIND OUT     : 가짜 공개키만 쓰는 합성 secrets.nix를 OUT에 씀
#     (KIND: common 공통 그룹 / user 사용자 키 전용 / host 호스트 키 전용)
#   - _add_host_run_with_synthetic_rules KIND      : 합성 규칙 파일과 nix·agenix·age 대역을 둔
#     sandbox에서 실행하고 대역 호출 0회·rc 0을 단정한다(결과: _add_host_run 전역 + _add_host_rules)

_add_host_prepare_sandbox() {
  local sandbox="$1"
  mkdir -p "$sandbox/repo/scripts" "$sandbox/repo/hosts"
  cp "$REPO_ROOT/scripts/add-host.sh" "$sandbox/repo/scripts/add-host.sh"
  chmod +x "$sandbox/repo/scripts/add-host.sh"
}

# NixOS 분기 전용 stdin 조립. add-host.sh의 read 순서: platform, hostname, username,
# type_choice, ssh_pubkey, confirm. platform은 "2"(NixOS)로 고정한다.
_add_host_nixos_stdin() {
  local hostname="$1" username="$2" type_choice="$3" ssh_pubkey="$4" confirm="$5"
  printf '2\n%s\n%s\n%s\n%s\n%s\n' "$hostname" "$username" "$type_choice" "$ssh_pubkey" "$confirm"
}

# 이름이 $2인 실행 파일을 $1에 설치한다. 호출되면 항상 실패하고, 호출 여부를
# "$1/$2.invoked"에 기록한다 — sed -i 복원 같은 회귀가 있으면 이 파일이 생겨 잡힌다.
_add_host_install_failing_stub() {
  local stub_dir="$1" name="$2"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/$name" <<EOF
#!/bin/sh
: > "$stub_dir/$name.invoked"
echo "stub $name: should not be called" >&2
exit 1
EOF
  chmod +x "$stub_dir/$name"
}

# printf를 항상 실패시키는 BASH_ENV 파일을 $1에 쓴다. add-host.sh는 `bash script.sh`로
# 새 비대화형 bash 프로세스에서 실행되므로, 호출 쪽에서 BASH_ENV="$1"을 export해 두면
# bash가 스크립트를 읽기 전에 이 파일을 source해 여기서 정의한 printf 함수가 builtin보다
# 우선한다(printf가 실제로 파일을 못 쓰는 상황을 흉내내는 스텁 실행 파일과 달리, printf는
# 셸 builtin이라 PATH 대역으로는 가로챌 수 없다).
_add_host_install_failing_printf_bash_env() {
  local out="$1"
  cat > "$out" <<'EOF'
printf() { return 1; }
EOF
}

# 실행. 결과는 전역 _add_host_stdout/_add_host_stderr(파일 경로)·_add_host_rc에 채운다.
# extra_path가 있으면 PATH 맨 앞에 둔다(대역 주입용). 호출 쪽 환경의 BASH_ENV 같은 변수는
# 이 함수를 통해 그대로 add-host.sh 프로세스에 전달된다(bash의 임시 환경 규칙).
_add_host_run() {
  local sandbox="$1" stdin_data="$2" extra_path="${3:-}"
  local run_path="$PATH"
  [[ -n "$extra_path" ]] && run_path="$extra_path:$PATH"

  _add_host_stdout="$sandbox/stdout"
  _add_host_stderr="$sandbox/stderr"
  _add_host_rc=0
  # stdin_data는 대개 "$(...)" 캡처로 전달돼 트레일링 개행이 이미 잘려 있다. 마지막 줄에
  # 개행이 없으면 bash의 `read`가 값은 채우면서도 실패 상태를 반환하고, add-host.sh의
  # set -e가 그 지점에서 조용히(stderr 메시지 없이) 스크립트를 종료시킨다 — 여기서
  # printf '%s\n'로 개행을 보장해 그 하니스 아티팩트를 피한다.
  printf '%s\n' "$stdin_data" | PATH="$run_path" bash "$sandbox/repo/scripts/add-host.sh" \
    > "$_add_host_stdout" 2> "$_add_host_stderr" || _add_host_rc=$?
}

_add_host_default_nix_path() {
  local sandbox="$1" hostname="$2"
  printf '%s' "$sandbox/repo/hosts/$hostname/default.nix"
}

# 기대 템플릿 — HOST_NAME 없이, ${username}/SSH_KEY_NAME은 리터럴로 유지.
_add_host_write_expected_default_nix() {
  local hostname="$1" out="$2"
  {
    printf '# %s 호스트 설정\n' "$hostname"
    cat << 'NIXEOF'
{
  config,
  lib,
  pkgs,
  inputs,
  username,
  constants,
  ...
}:

{
  imports = [
    ./hardware-configuration.nix
  ];

  # SSH 공개키 (원격 접속용)
  users.users.${username}.openssh.authorizedKeys.keys = [
    constants.sshKeys.SSH_KEY_NAME
  ];
}
NIXEOF
  } > "$out"
}

# ── 정상 생성: sed가 아예 없어도(호출하면 실패하는 대역) 동일 결과가 나오는지 고정한다.
# BSD sed(macOS)와 GNU sed는 in-place 인자 규칙이 달라 어느 한쪽만 흉내내면 다른 쪽
# 회귀를 놓친다 — 항상 실패하는 대역으로 "sed를 아예 안 부른다"를 구현체 무관하게 고정한다.
test_add_host_nixos_generates_default_nix_without_calling_sed() {
  local sandbox stub_dir hostname="test-host-1" username="testuser" expected
  sandbox="$(new_sandbox)"
  stub_dir="$sandbox/stub-bin"
  _add_host_prepare_sandbox "$sandbox"
  _add_host_install_failing_stub "$stub_dir" sed

  _add_host_run "$sandbox" \
    "$(_add_host_nixos_stdin "$hostname" "$username" 1 "ssh-ed25519 AAAAtest" y)" \
    "$stub_dir"

  [[ -f "$stub_dir/sed.invoked" ]] && fail "sed 대역이 호출됨 — sed -i 의존이 남아 있다"
  [[ "$_add_host_rc" -eq 0 ]] || fail "add-host.sh 실패 (rc=$_add_host_rc): $(cat "$_add_host_stderr")"

  local default_nix; default_nix="$(_add_host_default_nix_path "$sandbox" "$hostname")"
  [[ -f "$default_nix" ]] || fail "default.nix가 생성되지 않음"

  expected="$sandbox/expected-default.nix"
  _add_host_write_expected_default_nix "$hostname" "$expected"
  diff -u "$expected" "$default_nix" || fail "default.nix가 기대 템플릿과 다름"

  assert_not_contains "$(cat "$default_nix")" "HOST_NAME"
  # shellcheck disable=SC2016  # Literal Nix expression, not a shell expansion.
  assert_contains "$(cat "$default_nix")" '${username}'
  assert_contains "$(cat "$default_nix")" "SSH_KEY_NAME"
  assert_contains "$(cat "$_add_host_stdout")" "완료!"
  # 완료 뒤 수동 수정 안내(번호 헤더)가 끝까지 출력됐는지도 확인 — 시크릿 안내 문구는 아래
  # test_add_host_secret_guide_* 테스트가 따로 고정하므로, 여기서는 끊기지 않았다는 정도만 본다.
  assert_contains "$(cat "$_add_host_stdout")" "4️⃣"

  # mktemp가 만든 임시 파일은 0600이다 — mv로 그대로 옮기면 나머지 호스트 파일과 달리
  # default.nix만 0600이 된다. 스크립트는 umask 기반(0666 & ~umask)으로 되돌리므로,
  # 여기서도 같은 공식으로 기대값을 계산해 이 sandbox 프로세스의 실제 umask에 맞춘다
  # (umask 077처럼 0644가 원래 의미와 다른 환경에서 고정값 단정이 거짓 통과하지 않도록).
  local expected_mode
  expected_mode="$(printf '%03o' $(( 0666 & ~0$(umask) )))"
  [[ "$(_portable_file_mode "$default_nix")" == "$expected_mode" ]] \
    || fail "default.nix 모드가 $expected_mode(umask 기준)가 아님: $(_portable_file_mode "$default_nix")"
}

# ── 실제 시스템 sed(현재 PATH 그대로, 스텁 없음)로도 같은 결과가 나오는지 확인.
# 이 devShell PATH에서는 nix가 제공하는 GNU sed(gnused)가 /usr/bin보다 먼저 잡혀,
# PATH를 건드리지 않는 이 실행은 GNU sed 경로를 검증한다(스크립트가 sed를 전혀 호출하지
# 않으므로 사실 어느 sed든 결과는 같아야 한다). BSD 경로는 아래에서 PATH 맨 앞을
# /usr/bin:/bin으로 바꿔 별도로 검증한다 — sed뿐 아니라 bash 자체(macOS 시스템은 3.2)와
# cat/mv/chmod/mkdir/rmdir까지 시스템 도구로 실행되는, devShell 밖 macOS 경로를 흉내낸다.
test_add_host_nixos_matches_expected_template_with_system_tools() {
  local sandbox hostname="test-host-2" username="anotheruser" expected
  sandbox="$(new_sandbox)"
  _add_host_prepare_sandbox "$sandbox"

  _add_host_run "$sandbox" \
    "$(_add_host_nixos_stdin "$hostname" "$username" 2 "ssh-ed25519 AAAAtest2" y)" ""

  [[ "$_add_host_rc" -eq 0 ]] || fail "add-host.sh 실패 (rc=$_add_host_rc): $(cat "$_add_host_stderr")"

  local default_nix; default_nix="$(_add_host_default_nix_path "$sandbox" "$hostname")"
  expected="$sandbox/expected-default.nix"
  _add_host_write_expected_default_nix "$hostname" "$expected"
  diff -u "$expected" "$default_nix" || fail "default.nix가 기대 템플릿과 다름"
  assert_contains "$(cat "$_add_host_stdout")" "완료!"

  # BSD 실행 변형: /usr/bin/sed가 실제로 존재하고 BSD sed일 때만(--version을 모르는
  # 옵션으로 거부) 돈다. `/usr/bin/sed --version`이 명령을 찾지 못해 실패하는 환경
  # (예: /usr/bin에 sed 없이 env만 있는 NixOS)도 이 조건이면 걸러져 N/A로 빠진다 —
  # "sed 파일이 없다"와 "BSD sed다"를 구분하지 않으면 그런 환경을 BSD로 오판한다.
  if [[ -x /usr/bin/sed ]] && ! /usr/bin/sed --version >/dev/null 2>&1; then
    local sandbox_bsd hostname_bsd="test-host-2-bsd" default_nix_bsd expected_bsd
    sandbox_bsd="$(new_sandbox)"
    _add_host_prepare_sandbox "$sandbox_bsd"
    _add_host_run "$sandbox_bsd" \
      "$(_add_host_nixos_stdin "$hostname_bsd" "$username" 2 "ssh-ed25519 AAAAtest2bsd" y)" \
      "/usr/bin:/bin"

    [[ "$_add_host_rc" -eq 0 ]] || fail "BSD 경로에서 add-host.sh 실패 (rc=$_add_host_rc): $(cat "$_add_host_stderr")"
    default_nix_bsd="$(_add_host_default_nix_path "$sandbox_bsd" "$hostname_bsd")"
    expected_bsd="$sandbox_bsd/expected-default.nix"
    _add_host_write_expected_default_nix "$hostname_bsd" "$expected_bsd"
    diff -u "$expected_bsd" "$default_nix_bsd" || fail "BSD 경로의 default.nix가 기대 템플릿과 다름"
    assert_contains "$(cat "$_add_host_stdout")" "완료!"
  else
    echo "N/A: /usr/bin/sed가 없거나 GNU sed라 BSD 경로 변형은 이 실행 환경에 적용되지 않는다 (runner=$(uname -s))" >&2
  fi
}

# ── 기존 파일 보존: 같은 호스트명으로 재실행해도 기존 default.nix가 바이트 단위로 보존.
test_add_host_nixos_preserves_existing_default_nix() {
  local sandbox hostname="test-host-3" host_dir default_nix before after
  sandbox="$(new_sandbox)"
  _add_host_prepare_sandbox "$sandbox"
  host_dir="$sandbox/repo/hosts/$hostname"
  mkdir -p "$host_dir"
  default_nix="$host_dir/default.nix"
  printf '# 기존 합성 설정 — 절대 덮어쓰지 않아야 한다\n' > "$default_nix"
  before="$(cat "$default_nix")"

  _add_host_run "$sandbox" \
    "$(_add_host_nixos_stdin "$hostname" "someuser" 3 "ssh-ed25519 AAAAtest3" y)" ""

  [[ "$_add_host_rc" -eq 0 ]] || fail "add-host.sh 실패 (rc=$_add_host_rc): $(cat "$_add_host_stderr")"
  after="$(cat "$default_nix")"
  [[ "$before" == "$after" ]] || fail "기존 default.nix 내용이 변경됨"
  assert_contains "$(cat "$_add_host_stdout")" "완료!"
}

# ── 생성 실패 주입(mv 실패): 완료 메시지가 나오지 않고, default.nix가 최종 위치에
# 남지 않으며, 이번 실행이 만든 host_dir까지 지워져 재실행으로 다시 시도할 수 있어야 한다.
test_add_host_nixos_mv_failure_leaves_no_partial_file_and_removes_created_dir() {
  local sandbox stub_dir hostname="test-host-4" host_dir default_nix
  sandbox="$(new_sandbox)"
  stub_dir="$sandbox/stub-bin"
  _add_host_prepare_sandbox "$sandbox"
  _add_host_install_failing_stub "$stub_dir" mv
  host_dir="$sandbox/repo/hosts/$hostname"
  default_nix="$host_dir/default.nix"

  _add_host_run "$sandbox" \
    "$(_add_host_nixos_stdin "$hostname" "user4" 1 "ssh-ed25519 AAAAtest4" y)" \
    "$stub_dir"

  [[ -f "$stub_dir/mv.invoked" ]] || fail "mv 대역이 호출되지 않음 — 실패 주입이 경로에 닿지 않았다"
  [[ "$_add_host_rc" -ne 0 ]] || fail "mv 실패에도 add-host.sh가 rc 0으로 종료됨"
  assert_not_contains "$(cat "$_add_host_stdout")" "완료!"
  [[ ! -e "$default_nix" ]] || fail "mv 실패에도 default.nix가 최종 위치에 남음"
  [[ ! -d "$host_dir" ]] || fail "이번 실행이 만든 host_dir가 실패 후 남음 — 재실행이 디렉토리 존재로 계속 스킵된다"

  # 재실행하면 (대역 없이) 정상적으로 이어서 생성할 수 있어야 한다.
  _add_host_run "$sandbox" \
    "$(_add_host_nixos_stdin "$hostname" "user4" 1 "ssh-ed25519 AAAAtest4" y)" ""
  [[ "$_add_host_rc" -eq 0 ]] || fail "정리 후 재실행이 실패함 (rc=$_add_host_rc): $(cat "$_add_host_stderr")"
  [[ -f "$default_nix" ]] || fail "정리 후 재실행에서도 default.nix가 생성되지 않음"
}

# ── 쓰기 실패 주입(cat 실패): default.nix 본문을 쓰는 heredoc의 cat 자체가 실패해도
# 완료 메시지가 나오지 않고, default.nix가 최종 위치에 남지 않으며, 이번 실행이 만든
# host_dir까지 지워져 재실행으로 다시 시도할 수 있어야 한다. `if ! ( … )` 조건 문맥에서는
# bash가 서브셸 내부 errexit를 무시해(bash 3.2·5.x 동일) cat 실패가 조용히 넘어가고
# 마지막 mv의 성공 여부만 rc에 반영되는 회귀가 있었다(#1382 리뷰) — 이 테스트는 그 경로를
# 고정한다. cat은 `{ printf; cat; } > tmp` 그룹의 마지막 명령이라 그룹 exit status에 이미
# 반영되므로, 그 그룹의 exit status가 마지막 명령만 반영한다는 별도 함정은 printf 실패
# 테스트(아래)가 잡는다.
test_add_host_nixos_write_failure_leaves_no_partial_file_and_removes_created_dir() {
  local sandbox stub_dir hostname="test-host-5" host_dir default_nix
  sandbox="$(new_sandbox)"
  stub_dir="$sandbox/stub-bin"
  _add_host_prepare_sandbox "$sandbox"
  _add_host_install_failing_stub "$stub_dir" cat
  host_dir="$sandbox/repo/hosts/$hostname"
  default_nix="$host_dir/default.nix"

  _add_host_run "$sandbox" \
    "$(_add_host_nixos_stdin "$hostname" "user5" 2 "ssh-ed25519 AAAAtest5" y)" \
    "$stub_dir"

  [[ -f "$stub_dir/cat.invoked" ]] || fail "cat 대역이 호출되지 않음 — 실패 주입이 쓰기 경로에 닿지 않았다"
  [[ "$_add_host_rc" -ne 0 ]] || fail "쓰기 실패에도 add-host.sh가 rc 0으로 종료됨"
  assert_not_contains "$(cat "$_add_host_stdout")" "완료!"
  [[ ! -e "$default_nix" ]] || fail "쓰기 실패에도 default.nix가 최종 위치에 남음"
  [[ ! -d "$host_dir" ]] || fail "이번 실행이 만든 host_dir가 실패 후 남음 — 재실행이 디렉토리 존재로 계속 스킵된다"

  # 재실행하면 (대역 없이) 정상적으로 이어서 생성할 수 있어야 한다.
  _add_host_run "$sandbox" \
    "$(_add_host_nixos_stdin "$hostname" "user5" 2 "ssh-ed25519 AAAAtest5" y)" ""
  [[ "$_add_host_rc" -eq 0 ]] || fail "정리 후 재실행이 실패함 (rc=$_add_host_rc): $(cat "$_add_host_stderr")"
  [[ -f "$default_nix" ]] || fail "정리 후 재실행에서도 default.nix가 생성되지 않음"
}

# ── 쓰기 실패 주입(printf 실패): `{ printf; cat; } > tmp` 그룹의 첫 명령인 printf가
# 실패해도(cat은 정상 실행돼 그룹 자체는 무언가를 계속 쓴다) 완료 메시지가 나오지 않고,
# default.nix가 최종 위치에 남지 않으며, 이번 실행이 만든 host_dir까지 지워져야 한다.
# printf는 셸 builtin이라 PATH 대역(위 cat 테스트 방식)으로는 가로챌 수 없으므로, BASH_ENV로
# printf를 덮어쓰는 함수를 주입한다. 이 테스트는 그룹의 exit status가 마지막 명령(cat,
# 성공)만 반영해 앞선 printf 실패를 가린다는 별도 함정을 잡는다 — cat 실패 테스트(위)는
# cat이 그룹의 마지막 명령이라 이 함정을 검증하지 못한다.
test_add_host_nixos_printf_failure_leaves_no_partial_file_and_removes_created_dir() {
  local sandbox hostname="test-host-6" host_dir default_nix bash_env
  sandbox="$(new_sandbox)"
  _add_host_prepare_sandbox "$sandbox"
  bash_env="$sandbox/failing-printf-bash-env.sh"
  _add_host_install_failing_printf_bash_env "$bash_env"
  host_dir="$sandbox/repo/hosts/$hostname"
  default_nix="$host_dir/default.nix"

  BASH_ENV="$bash_env" _add_host_run "$sandbox" \
    "$(_add_host_nixos_stdin "$hostname" "user6" 2 "ssh-ed25519 AAAAtest6" y)" ""

  [[ "$_add_host_rc" -ne 0 ]] || fail "printf 실패에도 add-host.sh가 rc 0으로 종료됨"
  assert_not_contains "$(cat "$_add_host_stdout")" "완료!"
  [[ ! -e "$default_nix" ]] || fail "printf 실패에도 default.nix가 최종 위치에 남음"
  [[ ! -d "$host_dir" ]] || fail "이번 실행이 만든 host_dir가 실패 후 남음 — 재실행이 디렉토리 존재로 계속 스킵된다"

  # 재실행하면 (BASH_ENV 없이) 정상적으로 이어서 생성할 수 있어야 한다.
  _add_host_run "$sandbox" \
    "$(_add_host_nixos_stdin "$hostname" "user6" 2 "ssh-ed25519 AAAAtest6" y)" ""
  [[ "$_add_host_rc" -eq 0 ]] || fail "정리 후 재실행이 실패함 (rc=$_add_host_rc): $(cat "$_add_host_stderr")"
  [[ -f "$default_nix" ]] || fail "정리 후 재실행에서도 default.nix가 생성되지 않음"
}

# 합성 규칙 파일. 실제 libraries/constants.nix를 import하지 않고 가짜 공개키 문자열만 쓴다.
# KIND: common(여러 호스트의 사용자 키를 묶은 공통 그룹) | user(사용자 키 전용) | host(호스트 키 전용)
_add_host_write_synthetic_rules() {
  local kind="$1" out="$2" public_keys
  case "$kind" in
    common) public_keys='sharedUsers' ;;
    user) public_keys='[ userA ]' ;;
    host) public_keys='[ hostA ]' ;;
    *) fail "알 수 없는 합성 규칙 종류: $kind" ;;
  esac
  mkdir -p "$(dirname "$out")"
  cat > "$out" <<EOF
let
  userA = "ssh-ed25519 AAAAsyntheticUserA";
  userB = "ssh-ed25519 AAAAsyntheticUserB";
  hostA = "ssh-ed25519 AAAAsyntheticHostA";
  sharedUsers = [ userA userB ];
in
{
  "synthetic-$kind.age".publicKeys = $public_keys;
}
EOF
}

# KIND 합성 규칙을 sandbox의 repo/secrets/secrets.nix에 두고 NixOS 분기로 마법사를 실행한다.
# 마법사는 안내만 출력해야 하므로 nix·agenix·age를 호출하면 실패하는 대역을 PATH 맨 앞에 두고,
# 대역이 실제로 먼저 잡히는지(검사가 공허하지 않은지)와 호출 0회를 함께 단정한다.
_add_host_run_with_synthetic_rules() {
  local kind="$1" sandbox stub_dir name
  sandbox="$(new_sandbox)"
  stub_dir="$sandbox/stub-bin"
  _add_host_prepare_sandbox "$sandbox"
  _add_host_rules="$sandbox/repo/secrets/secrets.nix"
  _add_host_write_synthetic_rules "$kind" "$_add_host_rules"
  for name in nix agenix age; do
    _add_host_install_failing_stub "$stub_dir" "$name"
    [[ "$(PATH="$stub_dir:$PATH" command -v "$name")" == "$stub_dir/$name" ]] \
      || fail "[$kind] $name 대역이 PATH에서 먼저 잡히지 않음"
  done

  _add_host_run "$sandbox" \
    "$(_add_host_nixos_stdin "recipient-$kind" "user" 1 "ssh-ed25519 AAAAsynthetic$kind" y)" \
    "$stub_dir"

  [[ "$_add_host_rc" -eq 0 ]] || fail "[$kind] add-host.sh 실패 (rc=$_add_host_rc): $(cat "$_add_host_stderr")"
  for name in nix agenix age; do
    [[ ! -e "$stub_dir/$name.invoked" ]] || fail "[$kind] $name 대역이 호출됨 — 마법사는 재암호화를 실행하지 않고 안내만 출력해야 한다"
  done
}

# ── 시크릿 작업 위치 (#1396): agenix는 현재 디렉토리의 secrets.nix를 규칙 파일로 읽는다.
# 마법사가 안내하는 `cd` 위치는 하나여야 하고, 그 위치에 sandbox의 규칙 파일이 있어야 한다.
# 합성 규칙 세 종류 모두에서 같은 위치를 확인한다.
test_add_host_secret_guide_workdir_has_rules_file() {
  local kind cd_lines workdir
  for kind in common user host; do
    _add_host_run_with_synthetic_rules "$kind"

    cd_lines="$(sed -n 's/^[[:space:]]*cd //p' "$_add_host_stdout")"
    [[ -n "$cd_lines" && "$cd_lines" != *$'\n'* ]] \
      || fail "[$kind] 작업 위치를 안내하는 cd 줄이 정확히 하나가 아님: $cd_lines"
    workdir="$cd_lines"
    [[ -f "$workdir/secrets.nix" ]] \
      || fail "[$kind] 안내된 작업 위치($workdir)에 secrets.nix가 없음 — agenix가 규칙 파일을 찾지 못한다"
    cmp -s "$_add_host_rules" "$workdir/secrets.nix" \
      || fail "[$kind] 안내된 작업 위치의 secrets.nix가 합성 규칙 파일과 다름"
  done
}

# ── 대상별 recipient·identity 확인 (#1396): 합성 규칙 종류마다 안내가 그 종류의 복호화
# identity를 짚어야 한다. 순서는 작업 위치 → 각 항목의 publicKeys 확인 → identity로 복호화
# 확인(test -f 선행) → 대상별 재암호화 → 빈 값 확인이다. 재암호화는 EDITOR=:가 agenix까지
# 전달돼야 하므로 root 형태는 `sudo EDITOR=: …`여야 한다(`EDITOR=: sudo …`는 sudo가 변수를
# 지워 비대화형 실행에서 시크릿이 비워진다). 전체 재암호화(-r)는 사용 조건과 함께 설명만 한다 —
# 조건 없는 `agenix -- -r` 명령(identity를 붙인 변형 포함)은 identity가 없는 항목에서 중간에
# 멈추는 작업을 무조건 권한다. 재암호화 전후 바이트 수 비교, d·f의 호스트 키 sudo 변형, 새 호스트
# identity로 복호화하는 g 단계도 본다. 이 검사들은 managing-secrets-docs.sh의
# _secrets_docs_assert_rekey_all_conditional·_secrets_docs_assert_value_check_steps·
# _secrets_docs_assert_new_host_check_step을 함께 쓴다.
test_add_host_secret_guide_checks_recipients_per_target() {
  local kind label identity out cd_line pub_line dec_line enc_line check_line
  for kind in common user host; do
    # shellcheck disable=SC2088  # 안내 문구에 그대로 나오는 리터럴 경로다(확장하지 않음).
    case "$kind" in
      common) label="공통 그룹"; identity="~/.ssh/id_ed25519" ;;
      user) label="사용자 키 전용"; identity="~/.ssh/id_ed25519" ;;
      host) label="호스트 키 전용"; identity="/etc/ssh/ssh_host_ed25519_key" ;;
    esac
    _add_host_run_with_synthetic_rules "$kind"
    out="$_add_host_stdout"

    _secrets_docs_assert_rekey_all_conditional "[$kind] add-host.sh 안내" < "$out"
    grep -F -- '(-r)' "$out" | grep -qF '때만' \
      || fail "[$kind] 전체 재암호화(-r)를 쓸 수 있는 조건이 안내에 없음"

    # 줄 번호 조회는 못 찾아도 빈 값으로 두고 아래 단정이 이유를 출력하게 한다(pipefail로 조용히 끝나지 않게).
    cd_line="$(grep -n -m1 '^[[:space:]]*cd ' "$out" | cut -d: -f1 || true)"
    pub_line="$(grep -nF -m1 'publicKeys를 확인' "$out" | cut -d: -f1 || true)"
    dec_line="$(grep -nF -m1 -- '-d <name>.age -i <identity>' "$out" | cut -d: -f1 || true)"
    enc_line="$(grep -nF -m1 -- '-e <name>.age -i <identity>' "$out" | cut -d: -f1 || true)"
    check_line="$(grep -nF -- '-d <name>.age -i <identity> | wc -c' "$out" | cut -d: -f1 | tail -1 || true)"
    [[ -n "$cd_line" ]] || fail "[$kind] 작업 위치를 안내하는 cd 줄이 없음"

    # identity 안내는 작업 위치 뒤(시크릿 단계)에서 찾는다 — 앞선 키 등록 안내의 `.pub` 경로와 섞이지 않게.
    sed -n "$cd_line,\$p" "$out" | grep -F -- "$label" | grep -qF -- "$identity" \
      || fail "[$kind] 시크릿 단계의 '$label' 안내 줄에 복호화 identity($identity)가 없음"

    [[ -n "$pub_line" ]] || fail "[$kind] 각 항목의 publicKeys 확인 단계가 없음"
    [[ -n "$dec_line" ]] || fail "[$kind] identity로 복호화할 수 있는지 확인하는 단계가 없음"
    [[ -n "$enc_line" ]] || fail "[$kind] 대상별 재암호화 명령이 없음"
    [[ -n "$check_line" ]] || fail "[$kind] 재암호화 뒤 빈 값 확인(바이트 수) 단계가 없음"
    [[ "$cd_line" -lt "$pub_line" && "$pub_line" -lt "$dec_line" && "$dec_line" -lt "$enc_line" && "$enc_line" -lt "$check_line" ]] \
      || fail "[$kind] 안내 순서가 작업 위치 → publicKeys 확인 → 복호화 확인 → 재암호화 → 빈 값 확인이 아님 (cd=$cd_line pub=$pub_line dec=$dec_line enc=$enc_line check=$check_line)"
    sed -n "${dec_line}p" "$out" | grep -qF 'test -f <name>.age &&' \
      || fail "[$kind] 복호화 확인 명령 앞에 test -f <name>.age가 없음 — 파일 없는 항목이 복호화 가능으로 보인다"

    grep -qF 'sudo EDITOR=: nix run github:ryantm/agenix -- -e <name>.age -i /etc/ssh/ssh_host_ed25519_key' "$out" \
      || fail "[$kind] 호스트 키 재암호화의 root 형태(sudo 뒤에 EDITOR=:)가 없음"
    ! grep -qF 'EDITOR=: sudo' "$out" \
      || fail "[$kind] EDITOR=:를 sudo 앞에 둔 형태를 안내함 — sudo가 변수를 지워 시크릿이 비워진다"
    grep -F 'EDITOR=:' "$out" | grep -qF '비워진다' \
      || fail "[$kind] EDITOR=:가 전달되지 않으면 시크릿이 비워진다는 경고가 없음"
    _secrets_docs_assert_value_check_steps "[$kind] add-host.sh 안내" < "$out"
    _secrets_docs_assert_new_host_check_step "[$kind] add-host.sh 안내" < "$out"
  done
}
