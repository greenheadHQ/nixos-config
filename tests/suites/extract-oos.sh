# tests/suites/extract-oos.sh — 도메인 테스트 정의 (sourced; aggregator가 lib/test-common.sh 후 source)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# shellcheck disable=SC2154,SC2164
# ─── rebuild/common.sh extract_oos_entries characterization (이슈 #915) ───
# extract_oos_entries는 tests/ 전체에 직접 참조가 없던 검증된 미커버 갭이다.
# 두 입력형태("ref:path" git show / 파일시스템 경로)와 주석 라인 무시 · trailing
# comment strip · 중복 제거(sort -u) · 매치 없음/파일 부재 시 exit 0 동작을 현재
# 구현 기준으로 박제한다. 함수만 직접 source하므로 tomlkit/배포 레이아웃 불필요.
extract_oos_git_isolated() {
  # GIT_CONFIG_GLOBAL/NOSYSTEM은 config 파일만 무력화하므로 git 기본 excludesFile
  # ($XDG_CONFIG_HOME/git/ignore → $HOME/.config/git/ignore)은 여전히 읽힌다. 사용자
  # 전역 ignore의 `*.nix` 같은 패턴이 fixture의 `git add oos.nix`를 silent 실패시키지
  # 않도록 excludesFile을 /dev/null로 고정한다 (HOME/XDG 격리 헬퍼와 동등한 hermeticity).
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -c core.hooksPath=/dev/null -c commit.gpgSign=false -c init.templateDir= \
    -c core.excludesFile=/dev/null \
    -c user.email=oos@test -c user.name=oos "$@"
}

test_extract_oos_entries_filesystem_input() {
  local sandbox nix_file output common_sh count
  sandbox=$(new_sandbox)
  common_sh="$REPO_ROOT/modules/shared/scripts/lib/rebuild/common.sh"
  nix_file="$sandbox/oos.nix"
  cat > "$nix_file" <<'NIX'
{
  b = config.lib.file.mkOutOfStoreSymlink "/path/b";
  a = lib.mkOutOfStoreSymlink "/path/a"; # trailing comment
  # commented = config.lib.file.mkOutOfStoreSymlink "/path/c";
  dup = config.lib.file.mkOutOfStoreSymlink "/path/b";
  plain = "no symlink";
}
NIX
  output=$(
    GREEN='' YELLOW='' RED='' NC='' FLAKE_PATH="$sandbox" \
    bash -c 'set -euo pipefail; source "$1"; extract_oos_entries "$2"' _ "$common_sh" "$nix_file"
  )
  assert_contains "$output" '"/path/a"'
  assert_contains "$output" '"/path/b"'
  assert_not_contains "$output" '/path/c'          # 주석 라인은 무시된다
  assert_not_contains "$output" 'no symlink'        # mkOutOfStoreSymlink 없는 라인 무시
  assert_not_contains "$output" 'trailing comment'  # trailing comment는 strip된다
  # 중복 항목(dup)은 sort -u로 제거되어 "/path/b"는 정확히 1회만 출력된다
  count=$(printf '%s\n' "$output" | grep -Fc '"/path/b"')
  [[ "$count" == "1" ]] || fail "expected '/path/b' exactly once (sort -u), got: $count"
}

test_extract_oos_entries_git_show_input() {
  local sandbox nix_file output common_sh
  sandbox=$(new_sandbox)
  common_sh="$REPO_ROOT/modules/shared/scripts/lib/rebuild/common.sh"
  mkdir -p "$sandbox/repo"
  nix_file="$sandbox/repo/oos.nix"
  cat > "$nix_file" <<'NIX'
{
  z = config.lib.file.mkOutOfStoreSymlink "/git/z";
  # skip = config.lib.file.mkOutOfStoreSymlink "/git/skip";
}
NIX
  (
    cd "$sandbox/repo"
    extract_oos_git_isolated init -q
    extract_oos_git_isolated add oos.nix
    extract_oos_git_isolated commit -qm init
  )
  output=$(
    GREEN='' YELLOW='' RED='' NC='' FLAKE_PATH="$sandbox/repo" \
    bash -c 'set -euo pipefail; source "$1"; extract_oos_entries "$2"' _ "$common_sh" "HEAD:oos.nix"
  )
  assert_contains "$output" '"/git/z"'
  assert_not_contains "$output" '/git/skip'   # 주석 라인은 git show 입력에서도 무시
}

test_extract_oos_entries_empty_and_absent_exit_zero() {
  local sandbox common_sh result
  sandbox=$(new_sandbox)
  common_sh="$REPO_ROOT/modules/shared/scripts/lib/rebuild/common.sh"
  printf '{ x = 1; }\n' > "$sandbox/empty.nix"
  result=$(
    GREEN='' YELLOW='' RED='' NC='' FLAKE_PATH="$sandbox" \
    bash -c '
      set -euo pipefail
      source "$1"
      out=$(extract_oos_entries "$2"); printf "empty=[%s] rc=%s\n" "$out" "$?"
      out=$(extract_oos_entries "/nonexistent.nix"); printf "absent=[%s] rc=%s\n" "$out" "$?"
    ' _ "$common_sh" "$sandbox/empty.nix"
  )
  # 매치 없음과 파일 부재 모두 빈 출력 + exit 0 (set -euo pipefail 하 nrs abort 방지)
  assert_contains "$result" "empty=[] rc=0"
  assert_contains "$result" "absent=[] rc=0"
}
