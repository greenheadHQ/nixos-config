# tests/suites/wt-active-process.sh — 도메인 테스트 정의 (sourced; aggregator가 lib/test-common.sh 후 source)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# SC2153: REPO_ROOT도 같은 aggregator 정의 변수다.
# shellcheck disable=SC2154,SC2164,SC2153
#
# wt의 활성 작업 가드(lib/wt/process.sh): worktree(하위 포함)를 cwd로 둔 프로세스가 있으면
# 제거·재생성을 멈춘다. 두 층으로 고정한다.
#   - 단위: 가짜 프로세스 표(PID, 부모 PID, cwd, 명령)를 lsof·ps 대역으로 주입해 경로 비교,
#     제외 대상(wt 자신·조상·자손), 탐지 실패를 본다.
#   - 실제 프로세스: 대상 하위 폴더를 cwd로 둔 sleep을 띄워 실제 lsof·ps 경로로 막히는지,
#     끝낸 뒤 통과하는지 본다. 띄운 프로세스는 EXIT trap으로 PID를 직접 정리한다.

# 가짜 프로세스 표를 lsof·ps 대역으로 노출한다. 표는 탭 구분 한 줄에 프로세스 하나
# (PID, 부모 PID, cwd, 명령)다. 부모 PID가 `gone`인 줄은 lsof에만 보이고 ps에는 없다 —
# 스캔과 ps 사이에 끝난 프로세스다. lsof 대역은 필드 출력(-F)에 fcwd 줄을 섞어 내보내
# (macOS 시스템 lsof 형식) 파서가 f 필드 유무에 기대지 않는지도 함께 본다.
# 받은 lsof 인자는 lsof.args에 남긴다. WT_FAKE_LSOF_FAIL·WT_FAKE_PS_FAIL로 실패를 주입한다.
install_wt_fake_process_tools() {
  local bin_dir="$1" table="$2"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/lsof" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$bin_dir/lsof.args"
if [[ -n "\${WT_FAKE_LSOF_FAIL:-}" ]]; then
  echo "lsof: injected failure" >&2
  exit 1
fi
while IFS=\$'\t' read -r pid ppid cwd cmd; do
  [[ -n "\$pid" ]] || continue
  printf 'p%s\nc%s\nfcwd\nn%s\n' "\$pid" "\${cmd%% *}" "\$cwd"
done < "$table"
EOF
  cat > "$bin_dir/ps" <<EOF
#!/usr/bin/env bash
if [[ -n "\${WT_FAKE_PS_FAIL:-}" ]]; then
  echo "ps: injected failure" >&2
  exit 1
fi
while IFS=\$'\t' read -r pid ppid cwd cmd; do
  [[ -n "\$pid" && "\$ppid" != "gone" ]] || continue
  printf '%5s %5s %s\n' "\$pid" "\$ppid" "\$cmd"
done < "$table"
EOF
  chmod +x "$bin_dir/lsof" "$bin_dir/ps"
}

test_wt_cwd_holders_process_table_unit() {
  # 판정 기준은 폴더다: 대상의 물리 경로와 같거나 그 아래를 cwd로 둔 프로세스는 명령과
  # 무관하게 잡는다. 이름 접두사만 겹치는 이웃(feat_a ↔ feat_ab)은 잡지 않는다.
  # wt 자신과 조상 체인(부른 셸·세션), 자손(탐지 명령 포함)은 빼고, 같은 세션이 따로 띄운
  # 형제는 잡는다. 대상은 심링크 경로로 넘겨도 lsof가 보고하는 물리 경로와 맞춰 본다.
  local sandbox base target neighbor bin table out expected uid
  sandbox=$(new_sandbox)
  base="$(cd "$sandbox" && pwd -P)"
  target="$base/wts/feat_a"
  neighbor="$base/wts/feat_ab"
  mkdir -p "$target/sub/deep" "$neighbor"
  ln -s "$base/wts" "$base/link"
  bin="$sandbox/bin"
  table="$sandbox/proc.tsv"
  install_wt_fake_process_tools "$bin" "$table"

  out=$(
    PATH="$bin:$PATH" WT_LSOF="$bin/lsof" bash -c '
      set -euo pipefail
      table="$1" target="$2" neighbor="$3" repo="$4" link="$5"
      self=$$
      row() { printf "%s\t%s\t%s\t%s\n" "$@" >> "$table"; }
      : > "$table"
      row 901 1 "$target/sub" "zsh -l"                  # 조상의 조상 (터미널 탭 셸)
      row 900 901 "$target" "claude --resume"           # 조상 (wt를 부른 세션)
      row "$self" 900 /elsewhere "bash wt cleanup"      # wt 자신
      row 950 "$self" "$target/sub" "git status"        # 자식
      row 951 950 "$target" "less"                      # 손자
      row 960 900 "$target" "bash -c wait-loop"         # 형제 (같은 세션의 백그라운드 셸)
      row 970 1 "$target/sub/deep" "nvim notes.md"      # 무관한 프로세스, 하위 폴더
      row 980 1 "$neighbor" "nvim other.md"             # 이름 접두사만 겹치는 이웃
      row 990 1 /elsewhere "vim"                        # 대상 밖
      row 991 gone "$target" "short-lived"              # 스캔 뒤 끝남
      source "$repo/modules/shared/scripts/lib/wt/ui.sh"
      source "$repo/modules/shared/scripts/lib/wt/process.sh"
      _wt_cwd_holders "$link/feat_a"
    ' _ "$table" "$target" "$neighbor" "$REPO_ROOT" "$base/link"
  ) || fail "_wt_cwd_holders가 정상 표에서 실패함: $out"

  expected=$'960\tbash -c wait-loop\n970\tnvim notes.md'
  [[ "$out" == "$expected" ]] || fail "붙잡은 프로세스 판정이 다름: [$out] (기대: [$expected])"

  # 판정 범위는 현재 사용자 프로세스다 (다른 사용자·root는 읽지 못해도 멈추지 않는다).
  # 필터 조건이 OR로 풀리면 cwd 아닌 fd까지 섞이므로 -a로 묶는 것도 함께 고정한다.
  uid=$(id -u)
  assert_contains "$(cat "$bin/lsof.args")" "-a"
  assert_contains "$(cat "$bin/lsof.args")" "-u $uid"
  assert_contains "$(cat "$bin/lsof.args")" "-d cwd"
}

test_wt_cwd_holders_fails_closed_unit() {
  # 판정하지 못한 것은 "붙잡은 프로세스 없음"이 아니다. 도구가 없거나 실패하면 1을 내고
  # 원인 한 줄을 남겨 호출자가 멈추게 한다 (설계 선택 E).
  local sandbox base target bin table out rc
  sandbox=$(new_sandbox)
  base="$(cd "$sandbox" && pwd -P)"
  target="$base/wts/feat_a"
  mkdir -p "$target"
  bin="$sandbox/bin"
  table="$sandbox/proc.tsv"
  install_wt_fake_process_tools "$bin" "$table"
  printf '%s\t%s\t%s\t%s\n' 970 1 "$target" "nvim notes.md" > "$table"

  run_holders() {
    bash -c '
      set -euo pipefail
      source "$1/modules/shared/scripts/lib/wt/ui.sh"
      source "$1/modules/shared/scripts/lib/wt/process.sh"
      _wt_cwd_holders "$2"
    ' _ "$REPO_ROOT" "$1"
  }

  rc=0
  out=$(PATH="$bin:$PATH" WT_LSOF="$sandbox/missing/lsof" run_holders "$target") || rc=$?
  [[ "$rc" == "1" ]] || fail "lsof가 없으면 판정 실패(1)여야 함: rc=$rc out=$out"
  assert_contains "$out" "lsof"

  rc=0
  out=$(PATH="$bin:$PATH" WT_LSOF="$bin/lsof" WT_FAKE_LSOF_FAIL=1 run_holders "$target" 2>/dev/null) || rc=$?
  [[ "$rc" == "1" ]] || fail "lsof 실패는 판정 실패(1)여야 함: rc=$rc out=$out"
  assert_contains "$out" "lsof"

  rc=0
  out=$(PATH="$bin:$PATH" WT_LSOF="$bin/lsof" WT_FAKE_PS_FAIL=1 run_holders "$target" 2>/dev/null) || rc=$?
  [[ "$rc" == "1" ]] || fail "ps 실패는 판정 실패(1)여야 함: rc=$rc out=$out"
  assert_contains "$out" "ps"

  rc=0
  out=$(PATH="$bin:$PATH" WT_LSOF="$bin/lsof" run_holders "$base/wts/missing") || rc=$?
  [[ "$rc" == "1" ]] || fail "경로를 확인하지 못하면 판정 실패(1)여야 함: rc=$rc out=$out"

  # 대조군: 같은 대역이 정상이면 판정한다 (위 실패가 대역 자체의 고장이 아님).
  rc=0
  out=$(PATH="$bin:$PATH" WT_LSOF="$bin/lsof" run_holders "$target") || rc=$?
  [[ "$rc" == "0" && "$out" == $'970\tnvim notes.md' ]] \
    || fail "정상 대역에서 판정해야 함: rc=$rc out=$out"
}

test_wt_active_process_blocks_messages_unit() {
  # 가드의 안내 계약: 막을 때는 PID와 명령, 해결 방법(끝낸 뒤 재실행 또는 --yes 명령)을
  # 보여 주고 0(막음)을 낸다. 판정하지 못해도 원인과 함께 막는다. 붙잡은 프로세스가
  # 없으면 조용히 1(통과)이다.
  local out rc
  run_guard() {
    bash -c '
      set -euo pipefail
      source "$1/modules/shared/scripts/lib/wt/ui.sh"
      source "$1/modules/shared/scripts/lib/wt/process.sh"
      case "$2" in
        held)  _wt_cwd_holders() { printf "970\tnvim notes.md\n971\tzsh\n"; } ;;
        free)  _wt_cwd_holders() { :; } ;;
        error) _wt_cwd_holders() { printf "lsof 실행 실패 (종료 코드 1)\n"; return 1; } ;;
      esac
      _wt_active_process_blocks "스킵: feat_a" /wts/feat_a "wt cleanup feat_a --yes"
    ' _ "$REPO_ROOT" "$1" 2>&1
  }

  rc=0
  out=$(run_guard held) || rc=$?
  [[ "$rc" == "0" ]] || fail "붙잡은 프로세스가 있으면 막아야 함(0): rc=$rc"
  assert_contains "$out" "스킵: feat_a (이 worktree를 작업 위치로 쓰는 프로세스가 있습니다)"
  assert_contains "$out" "PID 970: nvim notes.md"
  assert_contains "$out" "PID 971: zsh"
  assert_contains "$out" "wt cleanup feat_a --yes"

  rc=0
  out=$(run_guard error) || rc=$?
  [[ "$rc" == "0" ]] || fail "판정하지 못하면 막아야 함(0): rc=$rc"
  assert_contains "$out" "스킵: feat_a (이 worktree를 쓰는 프로세스를 확인하지 못해 멈춥니다 — lsof 실행 실패 (종료 코드 1))"
  assert_contains "$out" "wt cleanup feat_a --yes"

  rc=0
  out=$(run_guard free) || rc=$?
  [[ "$rc" == "1" ]] || fail "붙잡은 프로세스가 없으면 통과해야 함(1): rc=$rc"
  [[ -z "$out" ]] || fail "통과할 때는 안내가 없어야 함: $out"
}

# 대상 폴더를 cwd로 둔 실제 프로세스(sleep)를 띄우고 PID를 wt_holder_pid에 남긴다.
# ps가 sleep 명령줄을 보일 때까지 기다린다 — exec 뒤라야 cd가 끝났음이 보장된다.
# 명령 치환 안에서 부르면 치환이 sleep의 stdout을 기다려 멈추므로 같은 셸에서 부르고,
# 그 셸에 stop_wt_cwd_holder EXIT trap을 먼저 건다.
start_wt_cwd_holder() {
  local dir="$1" _
  (cd "$dir" && exec sleep 120) &
  wt_holder_pid=$!
  for _ in {1..100}; do
    [[ "$(ps -o command= -p "$wt_holder_pid" 2>/dev/null)" == sleep* ]] && return 0
    sleep 0.05
  done
  fail "cwd를 붙잡는 프로세스가 뜨지 않음: $dir"
}

stop_wt_cwd_holder() {
  [[ -n "${wt_holder_pid:-}" ]] || return 0
  kill "$wt_holder_pid" 2>/dev/null || true
  wait "$wt_holder_pid" 2>/dev/null || true
  wt_holder_pid=""
}

test_wt_cleanup_preserves_worktree_held_by_process() {
  # tmux 밖 터미널 탭이 worktree 하위 폴더에 머문 상황을 실제 프로세스로 재현한다.
  # 이름 지정 정리와 --auto가 모두 대상을 보존하고 PID와 명령을 알려야 하며, 프로세스가
  # 끝나면 같은 명령이 지워야 한다(과잉 차단 아님). MERGED 대역은 이름 지정 정리의 확인
  # 프롬프트(push하지 않은 커밋)를 없애 가드까지 도달하게 한다.
  local sandbox home_dir repo_root gh_dir target_path head_oid
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  gh_dir="$sandbox/gh-bin"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  git -C "$repo_root" remote add origin https://example.invalid/nixos-config.git
  target_path="$repo_root/.claude/worktrees/feature_one"
  mkdir -p "$target_path/sub"
  head_oid="$(git -C "$target_path" rev-parse HEAD)"
  install_merged_pr_mock "$gh_dir" "$head_oid"

  (
    wt_holder_pid=""
    trap stop_wt_cwd_holder EXIT
    start_wt_cwd_holder "$target_path/sub"
    local output

    output=$(run_fixture_wt "$home_dir" "$repo_root" "$gh_dir:" cleanup feature_one 2>&1) \
      || fail "cleanup <name> 비정상 종료: $output"
    assert_contains "$output" "스킵: feature_one (이 worktree를 작업 위치로 쓰는 프로세스가 있습니다)"
    assert_contains "$output" "PID $wt_holder_pid: sleep 120"
    assert_contains "$output" "wt cleanup feature_one --yes"
    assert_contains "$output" "정리 완료: 0개 삭제"
    [[ -d "$target_path" ]] || fail "쓰는 중인 worktree가 이름 지정 정리로 지워짐: $output"

    output=$(run_fixture_wt "$home_dir" "$repo_root" "$gh_dir:" cleanup --auto 2>&1) \
      || fail "cleanup --auto 비정상 종료: $output"
    assert_contains "$output" "PID $wt_holder_pid: sleep 120"
    [[ -d "$target_path" ]] || fail "쓰는 중인 worktree가 --auto로 지워짐: $output"

    stop_wt_cwd_holder
    output=$(run_fixture_wt "$home_dir" "$repo_root" "$gh_dir:" cleanup feature_one 2>&1) \
      || fail "프로세스 종료 후 cleanup 비정상 종료: $output"
    assert_contains "$output" "정리 완료: 1개 삭제"
    [[ ! -d "$target_path" ]] || fail "프로세스가 끝난 worktree는 지워져야 함: $output"
  )
}

test_wt_recreate_preserves_worktree_held_by_process() {
  # 재생성(--if-exists=recreate)은 제거를 포함하므로 같은 가드를 지난다. WT_ASSUME_YES=1은
  # 손실 확인 프롬프트(push하지 않은 커밋)만 통과시킨다 — 확인용 환경 변수가 활성 가드를
  # 끄지 않는다는 것도 함께 본다(우회는 --yes 인자로만 받는다).
  local sandbox home_dir repo_root target_path
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  target_path="$repo_root/.claude/worktrees/feature_one"
  # 재생성은 경로의 checkout이 요청 브랜치일 때만 진행한다 (#1375).
  wt_fixture_git -C "$repo_root" branch -m feature-one feature/one
  mkdir -p "$target_path/sub"
  echo "keep" > "$target_path/sub/marker.txt"

  (
    wt_holder_pid=""
    trap stop_wt_cwd_holder EXIT
    start_wt_cwd_holder "$target_path/sub"
    local output rc=0

    output=$(WT_ASSUME_YES=1 run_fixture_wt "$home_dir" "$repo_root" "" --if-exists=recreate feature/one 2>&1) || rc=$?
    [[ "$rc" != "0" ]] || fail "쓰는 중인 worktree 재생성은 실패해야 함: $output"
    assert_contains "$output" "재생성 불가: feature_one (이 worktree를 작업 위치로 쓰는 프로세스가 있습니다)"
    assert_contains "$output" "PID $wt_holder_pid: sleep 120"
    assert_contains "$output" "wt --yes --if-exists=recreate feature/one"
    [[ -f "$target_path/sub/marker.txt" ]] || fail "재생성 거부인데 worktree 내용이 사라짐: $output"
  )
}

test_wt_cleanup_active_guard_matches_physical_folder() {
  # 경로 비교는 물리 경로에서 폴더 경계로 한다. 심링크 경로로 들어간 프로세스도 그
  # worktree를 붙잡은 것이고(lsof는 물리 경로를 보고한다), 이름 접두사만 겹치는 이웃
  # worktree의 프로세스는 이 worktree를 붙잡은 것이 아니다.
  local sandbox home_dir repo_root gh_dir base feat_a feat_ab
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  gh_dir="$sandbox/gh-bin"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  base="$repo_root/.claude/worktrees"
  feat_a="$base/feat_a"
  feat_ab="$base/feat_ab"
  add_fixture_worktree "$repo_root" "$feat_a" "feat-a"
  add_fixture_worktree "$repo_root" "$feat_ab" "feat-ab"
  mkdir -p "$feat_ab/sub"
  # 두 worktree 모두 같은 커밋이라 MERGED 대역 하나로 확인 프롬프트 없이 가드까지 간다.
  git -C "$repo_root" remote add origin https://example.invalid/nixos-config.git
  install_merged_pr_mock "$gh_dir" "$(git -C "$feat_a" rev-parse HEAD)"
  ln -s "$repo_root" "$sandbox/repo-link"

  (
    wt_holder_pid=""
    trap stop_wt_cwd_holder EXIT
    start_wt_cwd_holder "$sandbox/repo-link/.claude/worktrees/feat_ab/sub"
    local output

    output=$(run_fixture_wt "$home_dir" "$repo_root" "$gh_dir:" cleanup feat_ab 2>&1) \
      || fail "cleanup feat_ab 비정상 종료: $output"
    assert_contains "$output" "PID $wt_holder_pid: sleep 120"
    [[ -d "$feat_ab" ]] || fail "심링크 경로로 들어간 프로세스가 붙잡은 worktree가 지워짐: $output"

    output=$(run_fixture_wt "$home_dir" "$repo_root" "$gh_dir:" cleanup feat_a 2>&1) \
      || fail "cleanup feat_a 비정상 종료: $output"
    assert_not_contains "$output" "PID $wt_holder_pid"
    assert_contains "$output" "정리 완료: 1개 삭제"
    [[ ! -d "$feat_a" ]] || fail "이웃 worktree의 프로세스 때문에 feat_a가 막힘: $output"
  )
}

test_wt_cleanup_yes_bypasses_active_guard_only_when_named() {
  # --yes 우회는 이름을 지정한 정리에만 적용한다. `wt cleanup --auto --yes`는 여러 worktree를
  # 한 번에 지우는 경로라 쓰는 중인 worktree를 건너뛴다(설계 선택 G) — 편집기의 저장하지 않은
  # 내용은 --auto가 --yes로도 우회하지 않는 dirty와 같은 종류의 미보존 작업이다.
  local sandbox home_dir repo_root gh_dir target_path head_oid
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  gh_dir="$sandbox/gh-bin"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  git -C "$repo_root" remote add origin https://example.invalid/nixos-config.git
  target_path="$repo_root/.claude/worktrees/feature_one"
  mkdir -p "$target_path/sub"
  head_oid="$(git -C "$target_path" rev-parse HEAD)"
  install_merged_pr_mock "$gh_dir" "$head_oid"

  (
    wt_holder_pid=""
    trap stop_wt_cwd_holder EXIT
    start_wt_cwd_holder "$target_path/sub"
    local output

    output=$(run_fixture_wt "$home_dir" "$repo_root" "$gh_dir:" cleanup --auto --yes 2>&1) \
      || fail "cleanup --auto --yes 비정상 종료: $output"
    assert_contains "$output" "PID $wt_holder_pid: sleep 120"
    [[ -d "$target_path" ]] || fail "--auto --yes가 쓰는 중인 worktree를 지움: $output"

    output=$(run_fixture_wt "$home_dir" "$repo_root" "$gh_dir:" cleanup feature_one --yes 2>&1) \
      || fail "cleanup <name> --yes 비정상 종료: $output"
    assert_not_contains "$output" "PID $wt_holder_pid"
    assert_contains "$output" "정리 완료: 1개 삭제"
    [[ ! -d "$target_path" ]] || fail "이름 지정 --yes는 활성 가드를 우회해 지워야 함: $output"
  )
}

test_wt_recreate_yes_bypasses_active_guard() {
  # 재생성도 --yes로 활성 가드를 우회한다(설계 선택 G). create의 --yes는 확인 프롬프트용
  # WT_ASSUME_YES와 별개로 우회 여부를 재생성 분기까지 넘겨야 한다.
  local sandbox home_dir repo_root target_path
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  target_path="$repo_root/.claude/worktrees/feature_one"
  wt_fixture_git -C "$repo_root" branch -m feature-one feature/one
  mkdir -p "$target_path/sub"
  echo "stale" > "$target_path/sub/marker.txt"

  (
    wt_holder_pid=""
    trap stop_wt_cwd_holder EXIT
    start_wt_cwd_holder "$target_path/sub"
    local output

    output=$(run_fixture_wt "$home_dir" "$repo_root" "" --yes --if-exists=recreate feature/one 2>/dev/null) \
      || fail "--yes 재생성이 활성 가드에서 멈춤"
    [[ "$output" == "$target_path" ]] || fail "재생성은 worktree 경로를 내야 함: $output"
    [[ ! -e "$target_path/sub/marker.txt" ]] || fail "재생성이 기존 worktree를 지우지 않음"
    [[ "$(git -C "$target_path" branch --show-current)" == "feature/one" ]] \
      || fail "재생성된 worktree의 브랜치가 다름"
  )
}

test_wt_remove_worktree_active_guard_bypass_scope_unit() {
  # 우회 인자(bypass)는 활성 작업 가드만 건너뛴다: 탐지를 부르지 않고, 탐지가 실패해도
  # 진행한다. 잠금 가드와 wt를 실행한 셸의 cwd 가드는 그대로다. 우회 여부는 명시 인자로만
  # 받는다 — 확인 프롬프트용 WT_ASSUME_YES가 환경에 남아 있어도 가드는 꺼지지 않는다.
  local sandbox repo wt_path calls
  sandbox=$(new_sandbox)
  repo="$sandbox/repo"
  mkdir -p "$repo"
  repo="$(cd "$repo" && pwd -P)"
  wt_path="$(cd "$sandbox" && pwd -P)/wt"
  calls="$sandbox/holder-calls.log"

  (
    set -euo pipefail
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    git -C "$repo" init -q
    git -C "$repo" config user.email t@example.invalid
    git -C "$repo" config user.name t
    git -C "$repo" commit -q --allow-empty -m first
    git -C "$repo" worktree add -q "$wt_path" -b feature

    for helper in ui git-state tmux process bootstrap; do
      # shellcheck source=/dev/null
      source "$REPO_ROOT/modules/shared/scripts/lib/wt/$helper.sh"
    done
    _wt_require_state_helpers() { :; }
    _wt_tmux_session_state() { printf 'absent\n'; }
    _wt_tmux_close() { :; }
    _wt_tmux_session_close() { :; }
    _wt_remove_claude_local_plugins_for_worktree() { :; }
    _wt_untrust_codex_project() { :; }
    _wt_cwd_holders() {
      printf '%s\n' "$1" >> "$calls"
      printf 'lsof 실행 실패 (종료 코드 1)\n'
      return 1
    }

    local output
    # 환경의 WT_ASSUME_YES는 우회가 아니다
    output=$(WT_ASSUME_YES=1 _remove_worktree "$wt_path" feature "$repo" forced 2>&1) && exit 11
    [[ "$output" == *"확인하지 못해 멈춥니다"* ]] || exit 12

    # 우회해도 wt를 실행한 셸의 cwd 가드는 남는다
    output=$(cd "$wt_path" && _remove_worktree "$wt_path" feature "$repo" forced "" bypass 2>&1) && exit 13
    [[ "$output" == *"현재 작업 디렉토리가 이 worktree 안에 있습니다"* ]] || exit 14

    # 우회해도 잠금 가드는 남는다
    git -C "$repo" worktree lock --reason "bridge holds it" "$wt_path"
    output=$(_remove_worktree "$wt_path" feature "$repo" forced "" bypass 2>&1) && exit 15
    [[ "$output" == *"잠긴 worktree"* ]] || exit 16
    [[ -d "$wt_path" ]] || exit 17
    git -C "$repo" worktree unlock "$wt_path"

    # 우회는 탐지를 부르지 않으므로 탐지 실패와 무관하게 지운다
    : > "$calls"
    _remove_worktree "$wt_path" feature "$repo" forced "" bypass >/dev/null 2>&1 || exit 18
    [[ ! -d "$wt_path" ]] || exit 19
    [[ ! -s "$calls" ]] || exit 20
  ) || fail "활성 가드 우회 범위가 기대와 다름 (exit $?)"
}
