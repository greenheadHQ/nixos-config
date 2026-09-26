# tests/suites/git-cleanup.sh — 도메인 테스트 정의 (sourced; aggregator가 lib/test-common.sh 후 source)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# shellcheck disable=SC2154,SC2164

GIT_CLEANUP_SCRIPT="$REPO_ROOT/modules/shared/scripts/git-cleanup.sh"

# 격리된 git 호출. create_git_fixture_repo(test-common)와 같은 격리 정책(호스트 전역
# git 설정/훅 배제)을 쓰지만, git-cleanup 전용 fixture는 그 공용 헬퍼가 만드는 여분의
# worktree/브랜치(feature-one)를 원하지 않아 별도로 둔다 — 그 브랜치가 stale/active
# 분류에 잡음을 더하면 경계 테스트의 리터럴 기대값이 흔들린다.
_git_cleanup_fixture_git() {
  local repo_root="$1"
  shift
  local home_dir
  home_dir="$(dirname "$repo_root")/home"
  HOME="$home_dir" \
    XDG_CONFIG_HOME="$home_dir/.config" \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_NOSYSTEM=1 \
    git -C "$repo_root" \
    -c core.hooksPath=/dev/null \
    -c commit.gpgSign=false \
    -c init.templateDir= \
    "$@"
}

# main 하나와 로컬 bare 원격만 있는 최소 fixture 저장소. 원격은 이슈 검증 절차가 요구하는
# "임시 로컬 bare 저장소" 조건을 만족시키기 위해 만들지만, 이 suite의 테스트 대상(로컬
# 전용 브랜치의 stale 판정)은 원격 상태와 무관하다.
create_git_cleanup_fixture_repo() {
  local repo_root="$1"
  local sandbox_root home_dir origin_dir
  sandbox_root="$(dirname "$repo_root")"
  home_dir="$sandbox_root/home"
  origin_dir="$sandbox_root/origin.git"

  mkdir -p "$repo_root" "$origin_dir" "$home_dir/.config"
  # _git_cleanup_fixture_git는 `git -C <대상>`을 쓰므로 대상 디렉터리가 미리 있어야 한다
  # (위 mkdir -p). 첫 인자(-C 대상)만 origin_dir로 바꿔 호출한다 — home_dir 계산은 동일
  # sandbox_root를 가리키므로 격리 정책은 repo_root 호출과 같다.
  _git_cleanup_fixture_git "$origin_dir" init --bare -q

  _git_cleanup_fixture_git "$repo_root" init -q
  _git_cleanup_fixture_git "$repo_root" branch -M main
  _git_cleanup_fixture_git "$repo_root" config user.name "Test User"
  _git_cleanup_fixture_git "$repo_root" config user.email "test@example.com"
  echo fixture > "$repo_root/README.md"
  _git_cleanup_fixture_git "$repo_root" add README.md
  GIT_COMMITTER_DATE="@1600000000 +0000" GIT_AUTHOR_DATE="@1600000000 +0000" \
    _git_cleanup_fixture_git "$repo_root" commit -q -m initial
  _git_cleanup_fixture_git "$repo_root" remote add origin "$origin_dir"
  _git_cleanup_fixture_git "$repo_root" push -q origin main
  # --set-upstream-to는 -q가 없어 "Branch 'main' set up to track ..." 안내를 stdout에
  # 낸다 — fixture 준비 로그일 뿐이라 숨긴다.
  _git_cleanup_fixture_git "$repo_root" branch --set-upstream-to=origin/main main > /dev/null
}

# 지정 epoch를 커밋 시각으로 갖는 로컬 전용 브랜치(원격 트래킹 없음)를 만든다. stale 판정은
# collect_branches()가 원격 트래킹 없는 브랜치에만 적용하므로, gone/active 분류에 걸리지
# 않게 origin에 올리지 않는다.
add_local_only_branch_at_epoch() {
  local repo_root="$1" branch="$2" epoch="$3"
  _git_cleanup_fixture_git "$repo_root" checkout -q -b "$branch" main
  GIT_COMMITTER_DATE="@${epoch} +0000" GIT_AUTHOR_DATE="@${epoch} +0000" \
    _git_cleanup_fixture_git "$repo_root" commit -q --allow-empty -m "commit for $branch"
  _git_cleanup_fixture_git "$repo_root" checkout -q main
}

# date 대역 설치. kind:
#   bsd             - BSD 문법(-v*)과 +%s만 받음. GNU 문법(-d)은 거부(illegal option).
#   gnu             - GNU 문법(-d, 뒤따르는 값 인자 하나)과 +%s만 받음. -d 뒤 값은 검증·해석
#                     없이 그냥 건너뛴다(캘린더 계산을 흉내내지 않는다). BSD 문법(-v*)은
#                     거부(invalid option).
#   fail-nonzero    - 항상 비0 종료(date 명령 자체의 실행 실패를 모사).
#   fail-nonnumeric - 0으로 종료하지만 숫자가 아닌 출력을 냄.
# bsd/gnu 모두 옵션 검증을 통과하면 GIT_CLEANUP_TEST_FIXED_NOW를 그대로 출력해 "현재 시각"을
# 고정한다 — 어떤 옵션으로 불렸는지와 무관하게 같은 고정값을 낸다(옵션 문법 수용 여부만
# 검증하고, 실제 날짜 계산은 흉내내지 않는다).
install_git_cleanup_date_stub() {
  local stub_dir="$1" kind="$2"
  mkdir -p "$stub_dir"
  case "$kind" in
    bsd)
      cat > "$stub_dir/date" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
  case "$arg" in
    +%s) ;;
    -v*) ;;
    *)
      echo "date: illegal option -- ${arg#-}" >&2
      exit 1
      ;;
  esac
done
printf '%s\n' "${GIT_CLEANUP_TEST_FIXED_NOW:?GIT_CLEANUP_TEST_FIXED_NOW unset}"
EOF
      ;;
    gnu)
      cat > "$stub_dir/date" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
skip_next=0
for arg in "$@"; do
  if [[ "$skip_next" == 1 ]]; then
    skip_next=0
    continue
  fi
  case "$arg" in
    +%s) ;;
    -d) skip_next=1 ;;
    *)
      echo "date: invalid option -- '${arg#-}'" >&2
      exit 1
      ;;
  esac
done
printf '%s\n' "${GIT_CLEANUP_TEST_FIXED_NOW:?GIT_CLEANUP_TEST_FIXED_NOW unset}"
EOF
      ;;
    fail-nonzero)
      cat > "$stub_dir/date" <<'EOF'
#!/usr/bin/env bash
echo "date: simulated failure" >&2
exit 1
EOF
      ;;
    fail-nonnumeric)
      cat > "$stub_dir/date" <<'EOF'
#!/usr/bin/env bash
echo "not-a-timestamp"
EOF
      ;;
    *)
      fail "unknown date stub kind: $kind"
      ;;
  esac
  chmod +x "$stub_dir/date"
}

# git-cleanup.sh --dry-run을 지정한 PATH 그대로(가공 없이) 실행하고 stdout/stderr/exit
# code를 전역 변수에 담는다. GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1로 호스트의
# 전역/시스템 git 설정(예: color.ui=always)을 배제한다 — 그런 설정이 있으면 git-cleanup.sh
# 내부의 `git branch -vv` 출력에 색상 코드가 섞여 파싱이 깨지고 거짓 실패가 난다
# (codex-activation-static.sh의 격리 선례와 동일한 이유). tz/fixed_now가 비어 있으면 그
# 환경변수를 빈 문자열로 넘긴다(fixed_now는 실제 date를 쓰는 호출에서는 무시된다).
run_git_cleanup_dry_run_with_exact_path() {
  local repo_root="$1" path_value="$2" tz="$3" fixed_now="$4"
  local out_file err_file exit_code
  out_file="$(mktemp "${TMPDIR:-/tmp}/git-cleanup-out.XXXXXX")"
  err_file="$(mktemp "${TMPDIR:-/tmp}/git-cleanup-err.XXXXXX")"
  printf '%s\n' "$out_file" >> "$TEST_TMP_FILE"
  printf '%s\n' "$err_file" >> "$TEST_TMP_FILE"

  if (
    cd "$repo_root" &&
      PATH="$path_value" \
        TZ="$tz" \
        GIT_CLEANUP_TEST_FIXED_NOW="$fixed_now" \
        GIT_CONFIG_GLOBAL=/dev/null \
        GIT_CONFIG_NOSYSTEM=1 \
        "$GIT_CLEANUP_SCRIPT" --dry-run
  ) >"$out_file" 2>"$err_file" </dev/null; then
    exit_code=0
  else
    exit_code=$?
  fi

  GIT_CLEANUP_LAST_STDOUT="$(cat "$out_file")"
  GIT_CLEANUP_LAST_STDERR="$(cat "$err_file")"
  GIT_CLEANUP_LAST_EXIT="$exit_code"
}

# stub_dir이 비어 있지 않으면 기존 PATH 맨 앞에 둔다(date 대역만 가로채고 git/awk/grep
# 등은 기존 PATH를 그대로 쓴다). date 자체를 PATH에서 완전히 없애야 하는 테스트는 이 헬퍼가
# 아니라 run_git_cleanup_dry_run_with_exact_path를 직접 쓴다(기존 PATH를 뒤에 붙이면 그
# 안의 date가 다시 잡혀 "date 없음" 조건이 깨진다).
run_git_cleanup_dry_run() {
  local repo_root="$1" stub_dir="$2" tz="$3" fixed_now="$4"
  local path_value="$PATH"
  [[ -n "$stub_dir" ]] && path_value="$stub_dir:$PATH"
  run_git_cleanup_dry_run_with_exact_path "$repo_root" "$path_value" "$tz" "$fixed_now"
}

# git-cleanup.sh가 date 외에 필요로 하는 외부 명령(bash·git·awk·grep·sed·tr·cat)만
# 심링크한 PATH 디렉터리를 만든다. bash는 스크립트의 `#!/usr/bin/env bash` shebang을 env가
# 해석하는 데 필요하다. date는 절대 포함하지 않는다 — 이슈 검증 절차 5(날짜 명령 부재
# 조건)를 재현하려면 PATH 전체에서 date를 찾을 수 없어야 한다.
install_git_cleanup_path_without_date() {
  local stub_dir="$1"
  mkdir -p "$stub_dir"
  local cmd real
  for cmd in bash git awk grep sed tr cat; do
    real="$(command -v "$cmd")" || fail "필수 명령을 찾지 못했다: $cmd"
    ln -sf "$real" "$stub_dir/$cmd"
  done
}

# 완료 기준: "macOS의 정상 BSD date 환경에서 지원하지 않는 옵션 오류가 발생하지 않는다."
# stale 후보가 하나도 없으면 main()이 dry-run 안내 전에 "정리할 브랜치가 없습니다"로 먼저
# 끝나므로(대상 없음 분기가 dry-run 여부보다 앞선다), stale 브랜치를 하나 심어 dry-run
# 안내 문구까지 도달하는지 확인한다.
test_git_cleanup_bsd_only_date_dry_run_succeeds() {
  local sandbox repo_root stub_dir
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/bin"
  create_git_cleanup_fixture_repo "$repo_root"
  add_local_only_branch_at_epoch "$repo_root" some-branch 1697407999
  install_git_cleanup_date_stub "$stub_dir" bsd

  run_git_cleanup_dry_run "$repo_root" "$stub_dir" "UTC" "1700000000"

  [[ "$GIT_CLEANUP_LAST_EXIT" == "0" ]] ||
    fail "BSD-only date 환경에서 exit 0을 기대했지만 $GIT_CLEANUP_LAST_EXIT (stderr: $GIT_CLEANUP_LAST_STDERR)"
  assert_not_contains "$GIT_CLEANUP_LAST_STDERR" "illegal option"
  assert_contains "$GIT_CLEANUP_LAST_STDOUT" "some-branch (30일 경과)"
  assert_contains "$GIT_CLEANUP_LAST_STDOUT" "dry-run 모드"
}

# 완료 기준: "GNU date 우선 환경과 Linux에서도 정상 동작한다." (동일 이유로 stale 브랜치 필요)
test_git_cleanup_gnu_only_date_dry_run_succeeds() {
  local sandbox repo_root stub_dir
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/bin"
  create_git_cleanup_fixture_repo "$repo_root"
  add_local_only_branch_at_epoch "$repo_root" some-branch 1697407999
  install_git_cleanup_date_stub "$stub_dir" gnu

  run_git_cleanup_dry_run "$repo_root" "$stub_dir" "UTC" "1700000000"

  [[ "$GIT_CLEANUP_LAST_EXIT" == "0" ]] ||
    fail "GNU-only date 환경에서 exit 0을 기대했지만 $GIT_CLEANUP_LAST_EXIT (stderr: $GIT_CLEANUP_LAST_STDERR)"
  assert_not_contains "$GIT_CLEANUP_LAST_STDERR" "invalid option"
  assert_contains "$GIT_CLEANUP_LAST_STDOUT" "some-branch (30일 경과)"
  assert_contains "$GIT_CLEANUP_LAST_STDOUT" "dry-run 모드"
}

# 완료 기준: "고정 시간대·고정 시각의 30일 경계 분류가 플랫폼 사이에서 일치한다."
# stale_timestamp = FIXED_NOW(1700000000) - 30*86400 = 1697408000.
# 경계 직전(1697407999)은 stale(30일 경과), 경계 정확히(1697408000)와 경계 직후
# (1697408001)는 active로 남는다 — 스크립트의 기존 `-lt`(strict less-than) 비교가 정한
# 경계 의미를 그대로 리터럴 기대값으로 고정한다(이 비교 연산자 자체는 이슈 범위 밖).
test_git_cleanup_stale_boundary_consistent_across_date_tools() {
  local sandbox repo_root stub_dir_bsd stub_dir_gnu
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  stub_dir_bsd="$sandbox/bin-bsd"
  stub_dir_gnu="$sandbox/bin-gnu"
  create_git_cleanup_fixture_repo "$repo_root"

  add_local_only_branch_at_epoch "$repo_root" boundary-before 1697407999
  add_local_only_branch_at_epoch "$repo_root" boundary-exact 1697408000
  add_local_only_branch_at_epoch "$repo_root" boundary-after 1697408001

  install_git_cleanup_date_stub "$stub_dir_bsd" bsd
  install_git_cleanup_date_stub "$stub_dir_gnu" gnu

  run_git_cleanup_dry_run "$repo_root" "$stub_dir_bsd" "UTC" "1700000000"
  local bsd_stdout="$GIT_CLEANUP_LAST_STDOUT" bsd_exit="$GIT_CLEANUP_LAST_EXIT" bsd_stderr="$GIT_CLEANUP_LAST_STDERR"

  run_git_cleanup_dry_run "$repo_root" "$stub_dir_gnu" "UTC" "1700000000"
  local gnu_stdout="$GIT_CLEANUP_LAST_STDOUT" gnu_exit="$GIT_CLEANUP_LAST_EXIT" gnu_stderr="$GIT_CLEANUP_LAST_STDERR"

  [[ "$bsd_exit" == "0" ]] || fail "BSD date 대역 실행이 실패했다: $bsd_stderr"
  [[ "$gnu_exit" == "0" ]] || fail "GNU date 대역 실행이 실패했다: $gnu_stderr"

  assert_contains "$bsd_stdout" "boundary-before (30일 경과)"
  assert_not_contains "$bsd_stdout" "boundary-exact"
  assert_not_contains "$bsd_stdout" "boundary-after"

  assert_contains "$gnu_stdout" "boundary-before (30일 경과)"
  assert_not_contains "$gnu_stdout" "boundary-exact"
  assert_not_contains "$gnu_stdout" "boundary-after"

  [[ "$bsd_stdout" == "$gnu_stdout" ]] ||
    fail "BSD/GNU date 대역 사이에 --dry-run 출력이 달랐다"
}

# 완료 기준: "시간대 또는 일광절약시간 경계를 포함한 경우의 기준을 테스트로 문서화한다."
# 고정 초 차이 방식(30*86400초)은 달력 계산을 하지 않으므로 TZ/DST와 무관해야 한다. 실제
# 시스템 date(스텁 없음)를 세 TZ에서 각각 호출해 분류가 동일함을 확인한다 — 이 devShell의
# date는 GNU(Nix coreutils)이며 +%s는 어느 구현에서도 TZ 무관한 절대 epoch를 낸다.
test_git_cleanup_stale_boundary_is_timezone_independent() {
  local sandbox repo_root now stale_epoch fresh_epoch tz
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  create_git_cleanup_fixture_repo "$repo_root"

  now=$(date +%s)
  stale_epoch=$(( now - 100 * 86400 ))
  fresh_epoch=$(( now - 1 * 86400 ))

  add_local_only_branch_at_epoch "$repo_root" tz-stale-branch "$stale_epoch"
  add_local_only_branch_at_epoch "$repo_root" tz-fresh-branch "$fresh_epoch"

  for tz in UTC America/New_York Asia/Seoul; do
    run_git_cleanup_dry_run "$repo_root" "" "$tz" ""
    [[ "$GIT_CLEANUP_LAST_EXIT" == "0" ]] ||
      fail "TZ=$tz 에서 exit 0을 기대했지만 $GIT_CLEANUP_LAST_EXIT (stderr: $GIT_CLEANUP_LAST_STDERR)"
    assert_contains "$GIT_CLEANUP_LAST_STDOUT" "tz-stale-branch (100일 경과)"
    assert_not_contains "$GIT_CLEANUP_LAST_STDOUT" "tz-fresh-branch"
  done
}

# 완료 기준: "날짜 계산 실패가 잘못된 삭제 후보를 만들지 않는다." (date 명령 자체가 비0으로 실패)
# stub이 자기 stderr("date: simulated failure")를 쓰므로 "stderr가 비어 있지 않다"만 보면
# 스크립트가 스스로 진단 메시지를 내는지와 무관하게 항상 참이 된다. 스크립트 자신의 ❌
# 메시지(`date +%s` 실행 실패를 언급하는 문구)를 직접 단언한다 — get_stale_timestamp()의
# `|| { echo …; exit 1; }`를 `|| exit 1`로 바꾸는 변이를 넣으면 이 단언이 실제로 red가
# 됨을 확인했다(원복 완료, 스크립트 로직은 그대로다).
test_git_cleanup_date_command_failure_stops_before_candidates() {
  local sandbox repo_root stub_dir
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/bin"
  create_git_cleanup_fixture_repo "$repo_root"
  add_local_only_branch_at_epoch "$repo_root" some-branch 1697407999
  install_git_cleanup_date_stub "$stub_dir" fail-nonzero

  run_git_cleanup_dry_run "$repo_root" "$stub_dir" "UTC" ""

  [[ "$GIT_CLEANUP_LAST_EXIT" != "0" ]] ||
    fail "date 명령 실패에도 exit 0으로 끝났다"
  assert_not_contains "$GIT_CLEANUP_LAST_STDOUT" "Git Branch Cleanup"
  assert_not_contains "$GIT_CLEANUP_LAST_STDOUT" "some-branch"
  assert_contains "$GIT_CLEANUP_LAST_STDERR" "'date +%s' 실행 실패"
}

# 완료 기준: "날짜 계산 실패가 잘못된 삭제 후보를 만들지 않는다." (date는 0으로 종료하지만 출력이 숫자가 아님)
test_git_cleanup_date_non_numeric_output_stops_before_candidates() {
  local sandbox repo_root stub_dir
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/bin"
  create_git_cleanup_fixture_repo "$repo_root"
  add_local_only_branch_at_epoch "$repo_root" some-branch 1697407999
  install_git_cleanup_date_stub "$stub_dir" fail-nonnumeric

  run_git_cleanup_dry_run "$repo_root" "$stub_dir" "UTC" ""

  [[ "$GIT_CLEANUP_LAST_EXIT" != "0" ]] ||
    fail "date 출력이 숫자가 아닌데도 exit 0으로 끝났다"
  assert_not_contains "$GIT_CLEANUP_LAST_STDOUT" "Git Branch Cleanup"
  assert_not_contains "$GIT_CLEANUP_LAST_STDOUT" "some-branch"
  assert_contains "$GIT_CLEANUP_LAST_STDERR" "not-a-timestamp"
}

# 완료 기준: "--dry-run은 브랜치를 삭제하지 않고 기존 보호·승인 정책을 유지한다." (회귀 확인)
test_git_cleanup_dry_run_does_not_delete_stale_branch() {
  local sandbox repo_root stub_dir exists
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/bin"
  create_git_cleanup_fixture_repo "$repo_root"
  add_local_only_branch_at_epoch "$repo_root" stale-branch 1697407999
  install_git_cleanup_date_stub "$stub_dir" bsd

  run_git_cleanup_dry_run "$repo_root" "$stub_dir" "UTC" "1700000000"

  [[ "$GIT_CLEANUP_LAST_EXIT" == "0" ]] ||
    fail "--dry-run 실행이 실패했다: $GIT_CLEANUP_LAST_STDERR"
  assert_contains "$GIT_CLEANUP_LAST_STDOUT" "dry-run 모드"

  exists=$(_git_cleanup_fixture_git "$repo_root" branch --list stale-branch)
  [[ -n "$exists" ]] || fail "--dry-run 이후 stale-branch가 사라졌다"
}

# G1의 "30일 = 고정 초 차이(30*86400초)" 의미를 일광절약시간(DST) 전환을 낀 경계로 잠근다.
# FIXED_NOW=1711987200(2024-04-01 12:00 America/New_York, EDT)에서 cut=FIXED_NOW-2592000
# (=1709395200, 2024-03-02 11:00 America/New_York, EST)까지의 30일 구간 안에 2024년 미국
# DST 시작(2024-03-10)이 들어 있다. cut+1800(30분 뒤)은 고정 초 방식으로는 active이지만,
# `-v-30d`/`-d '30 days ago'` 같은 지역 달력 계산(로컬 시각 12:00을 유지한 채 캘린더로
# 30일을 빼는 방식)이라면 그 계산 결과가 cut보다 1시간(DST 오프셋 변화분) 늦어져
# cut+1800이 여전히 그 이전이 되어 stale로 잘못 분류된다 — 두 의미를 가르는 지점이다.
# BSD 대역은 어떤 옵션으로 불려도 GIT_CLEANUP_TEST_FIXED_NOW를 그대로 낼 뿐 캘린더 계산을
# 흉내내지 않으므로, 이 테스트는 get_stale_timestamp()가 실제로 순수 초 산술만 하는지(대역
# 반환값에 로컬 캘린더 보정을 추가로 얹지 않는지)를 검증한다.
test_git_cleanup_stale_boundary_uses_fixed_seconds_not_calendar_days_across_dst() {
  local sandbox repo_root stub_dir fixed_now cut
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/bin"
  fixed_now=1711987200
  cut=$(( fixed_now - 2592000 ))
  create_git_cleanup_fixture_repo "$repo_root"

  add_local_only_branch_at_epoch "$repo_root" dst-before-cut $(( cut - 1 ))
  add_local_only_branch_at_epoch "$repo_root" dst-at-cut "$cut"
  add_local_only_branch_at_epoch "$repo_root" dst-after-cut-by-30m $(( cut + 1800 ))

  install_git_cleanup_date_stub "$stub_dir" bsd

  run_git_cleanup_dry_run "$repo_root" "$stub_dir" "America/New_York" "$fixed_now"

  [[ "$GIT_CLEANUP_LAST_EXIT" == "0" ]] ||
    fail "DST 경계 실행이 실패했다: $GIT_CLEANUP_LAST_STDERR"
  assert_contains "$GIT_CLEANUP_LAST_STDOUT" "dst-before-cut (30일 경과)"
  assert_not_contains "$GIT_CLEANUP_LAST_STDOUT" "dst-at-cut"
  assert_not_contains "$GIT_CLEANUP_LAST_STDOUT" "dst-after-cut-by-30m"
}

# 완료 기준 검증 절차 5: "날짜 명령 부재·실패 조건을 주입해 이해 가능한 실패로 종료하는지
# 확인한다." PATH에 date를 전혀 두지 않는다(대역 존재/문법 문제가 아니라 명령 자체의
# 부재). 기존 PATH를 뒤에 붙이면 그 안의 date가 다시 잡히므로
# run_git_cleanup_dry_run_with_exact_path로 PATH를 완전히 대체한다.
test_git_cleanup_date_command_absent_stops_before_candidates() {
  local sandbox repo_root path_dir
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  path_dir="$sandbox/bin-no-date"
  create_git_cleanup_fixture_repo "$repo_root"
  add_local_only_branch_at_epoch "$repo_root" some-branch 1697407999
  install_git_cleanup_path_without_date "$path_dir"

  run_git_cleanup_dry_run_with_exact_path "$repo_root" "$path_dir" "UTC" ""

  [[ "$GIT_CLEANUP_LAST_EXIT" != "0" ]] ||
    fail "date 명령이 PATH에 없는데도 exit 0으로 끝났다"
  assert_not_contains "$GIT_CLEANUP_LAST_STDOUT" "Git Branch Cleanup"
  assert_not_contains "$GIT_CLEANUP_LAST_STDOUT" "some-branch"
  assert_contains "$GIT_CLEANUP_LAST_STDERR" "'date +%s' 실행 실패"
}
