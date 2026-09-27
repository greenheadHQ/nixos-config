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
# 유형\n공개키\nconfirm")를 다루는 다른 스위트가 그대로 부를 수 있다(예: #1396의 안내 문구
# 검증 — _add_host_run 뒤 $_add_host_stdout을 보면 됨). darwin 분기용 stdin 조립 헬퍼나
# libraries/constants.nix·시크릿 재암호화 안내를 검증하는 fixture는 이 파일에 없다 — 필요한
# 스위트가 별도로 추가해야 한다.
#   - _add_host_prepare_sandbox SANDBOX           : repo/scripts/add-host.sh 배치
#   - _add_host_nixos_stdin HOST USER TYPE KEY CONFIRM : NixOS 분기 stdin 조립
#   - _add_host_run SANDBOX STDIN [EXTRA_PATH]    : 실행, stdout/stderr/rc를 전역에 채움
#     (결과: _add_host_stdout, _add_host_stderr, _add_host_rc)
#   - _add_host_default_nix_path SANDBOX HOST      : 생성될 default.nix의 경로 문자열
#   - _add_host_write_expected_default_nix HOST OUT : 기대 템플릿을 OUT에 씀
#   - _add_host_install_failing_stub STUB_DIR NAME : 이름이 NAME인 실행 파일을 호출하면
#     항상 실패(로그 남김)하는 대역으로 설치

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

# 실행. 결과는 전역 _add_host_stdout/_add_host_stderr(파일 경로)·_add_host_rc·
# _add_host_host_dir에 채운다. extra_path가 있으면 PATH 맨 앞에 둔다(대역 주입용).
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

# ── 정상 생성: sed가 아예 없어도(호출하면 실패하는 대역) 동일 결과 — BSD/GNU sed 구현
# 차이에 좌우되지 않는 방식으로 이식성을 고정한다(팀 지침의 "sed 실패 대역" 대안 채택).
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
  # 완료 뒤 수동 수정 안내(번호 헤더)가 끝까지 출력됐는지도 확인 — 문구 전체는 #1396이
  # 바꿀 예정이라 고정하지 않고, 안내가 중간에 끊기지 않았다는 정도만 본다.
  assert_contains "$(cat "$_add_host_stdout")" "4️⃣"

  # mktemp가 만든 임시 파일은 0600이다 — mv로 그대로 옮기면 나머지 호스트 파일과 달리
  # default.nix만 0600이 되므로, 최종 파일은 0644로 맞춰야 한다.
  [[ "$(_portable_file_mode "$default_nix")" == "644" ]] \
    || fail "default.nix 모드가 644가 아님: $(_portable_file_mode "$default_nix")"
}

# ── 실제 시스템 sed(현재 PATH 그대로, 스텁 없음)로도 같은 결과가 나오는지 확인.
# 이 devShell PATH에서는 nix가 제공하는 GNU sed(gnused)가 /usr/bin보다 먼저 잡혀,
# PATH를 건드리지 않는 이 실행은 GNU sed 경로를 검증한다(스크립트가 sed를 전혀 호출하지
# 않으므로 사실 어느 sed든 결과는 같아야 한다). BSD sed 경로는 아래에서 /usr/bin을 PATH
# 앞에 둬 별도로 검증한다 — macOS에서만 /usr/bin/sed가 BSD sed이기 때문이다.
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

  # BSD sed 실행 변형: /usr/bin/sed가 BSD sed일 때(--version을 모르는 옵션으로 거부)만
  # PATH 맨 앞에 /usr/bin을 둬 그 경로가 먼저 잡히게 하고 같은 결과를 다시 확인한다.
  # /usr/bin/sed가 GNU sed인 환경(대부분의 Linux)에서는 이 구분이 성립하지 않아 건너뛴다.
  if /usr/bin/sed --version >/dev/null 2>&1; then
    echo "N/A: /usr/bin/sed가 GNU sed라 BSD 경로 변형은 이 실행 환경에 적용되지 않는다 (runner=$(uname -s))" >&2
    return 0
  fi

  local sandbox_bsd hostname_bsd="test-host-2-bsd" default_nix_bsd expected_bsd
  sandbox_bsd="$(new_sandbox)"
  _add_host_prepare_sandbox "$sandbox_bsd"
  _add_host_run "$sandbox_bsd" \
    "$(_add_host_nixos_stdin "$hostname_bsd" "$username" 2 "ssh-ed25519 AAAAtest2bsd" y)" \
    "/usr/bin"

  [[ "$_add_host_rc" -eq 0 ]] || fail "BSD sed 경로에서 add-host.sh 실패 (rc=$_add_host_rc): $(cat "$_add_host_stderr")"
  default_nix_bsd="$(_add_host_default_nix_path "$sandbox_bsd" "$hostname_bsd")"
  expected_bsd="$sandbox_bsd/expected-default.nix"
  _add_host_write_expected_default_nix "$hostname_bsd" "$expected_bsd"
  diff -u "$expected_bsd" "$default_nix_bsd" || fail "BSD sed 경로의 default.nix가 기대 템플릿과 다름"
  assert_contains "$(cat "$_add_host_stdout")" "완료!"
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
# 고정한다. mv 실패(위 테스트)와 달리 이 실패는 조건 문맥 문제가 없어도 `{ } > tmp` 그룹의
# exit status가 마지막 명령(cat)만 반영한다는 별도 함정도 함께 잡는다.
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
