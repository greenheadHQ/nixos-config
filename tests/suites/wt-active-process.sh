# tests/suites/wt-active-process.sh — 도메인 테스트 정의 (sourced; aggregator가 lib/test-common.sh 후 source)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# SC2153: REPO_ROOT도 같은 aggregator 정의 변수다.
# SC2329: 단위 테스트는 helper 함수를 같은 이름의 대역으로 덮어써 production 코드가 간접 호출한다.
# shellcheck disable=SC2154,SC2164,SC2153,SC2329
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
  # 막힐 수 있는 커널 호출(stat·readlink)을 피한다. 이 옵션이 cwd 이름 해석을 바꾸면
  # fail-open이 되므로, 아래 실제 프로세스 테스트들이 두 플랫폼에서 그것을 지킨다.
  assert_contains "$(cat "$bin/lsof.args")" "-b"
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

# tmux 호출을 기록만 하는 대역. wt가 tmux를 부르지 않는지 보려고 PATH 앞에 둔다 — 활성
# 판정은 tmux 사용 여부와 무관하고, 창·세션 닫기도 더는 하지 않는다.
install_wt_tmux_call_recorder() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/tmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$bin_dir/tmux.calls"
exit 1
EOF
  chmod +x "$bin_dir/tmux"
}

test_wt_cleanup_preserves_worktree_held_by_process() {
  # tmux 밖 터미널 탭이 worktree 하위 폴더에 머문 상황을 실제 프로세스로 재현한다.
  # 이름 지정 정리와 --auto가 모두 대상을 보존하고 PID와 명령을 알려야 하며, 프로세스가
  # 끝나면 같은 명령이 지워야 한다(과잉 차단 아님). MERGED 대역은 이름 지정 정리의 확인
  # 프롬프트(push하지 않은 커밋)를 없애 가드까지 도달하게 한다. tmux는 한 번도 부르지 않는다.
  local sandbox home_dir repo_root gh_dir stub_dir target_path head_oid
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  gh_dir="$sandbox/gh-bin"
  stub_dir="$sandbox/stub-bin"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  git -C "$repo_root" remote add origin https://example.invalid/nixos-config.git
  target_path="$repo_root/.claude/worktrees/feature_one"
  mkdir -p "$target_path/sub"
  head_oid="$(git -C "$target_path" rev-parse HEAD)"
  install_merged_pr_mock "$gh_dir" "$head_oid"
  install_wt_tmux_call_recorder "$stub_dir"

  (
    wt_holder_pid=""
    trap stop_wt_cwd_holder EXIT
    start_wt_cwd_holder "$target_path/sub"
    local output

    output=$(run_fixture_wt "$home_dir" "$repo_root" "$stub_dir:$gh_dir:" cleanup feature_one 2>&1) \
      || fail "cleanup <name> 비정상 종료: $output"
    assert_contains "$output" "스킵: feature_one (이 worktree를 작업 위치로 쓰는 프로세스가 있습니다)"
    assert_contains "$output" "PID $wt_holder_pid: sleep 120"
    assert_contains "$output" "wt cleanup feature_one --yes"
    assert_contains "$output" "정리 완료: 0개 삭제"
    [[ -d "$target_path" ]] || fail "쓰는 중인 worktree가 이름 지정 정리로 지워짐: $output"

    output=$(run_fixture_wt "$home_dir" "$repo_root" "$stub_dir:$gh_dir:" cleanup --auto 2>&1) \
      || fail "cleanup --auto 비정상 종료: $output"
    assert_contains "$output" "PID $wt_holder_pid: sleep 120"
    [[ -d "$target_path" ]] || fail "쓰는 중인 worktree가 --auto로 지워짐: $output"

    stop_wt_cwd_holder
    output=$(run_fixture_wt "$home_dir" "$repo_root" "$stub_dir:$gh_dir:" cleanup feature_one 2>&1) \
      || fail "프로세스 종료 후 cleanup 비정상 종료: $output"
    assert_contains "$output" "정리 완료: 1개 삭제"
    [[ ! -d "$target_path" ]] || fail "프로세스가 끝난 worktree는 지워져야 함: $output"
  )
  [[ ! -e "$stub_dir/tmux.calls" ]] || fail "wt가 tmux를 호출함: $(cat "$stub_dir/tmux.calls")"
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
  # WT_ASSUME_YES와 별개로 우회 여부를 재생성 분기까지 넘겨야 한다. 재생성 전 tmux 창·세션을
  # 닫던 단계도 없어졌으므로 tmux는 부르지 않는다.
  local sandbox home_dir repo_root stub_dir target_path
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stub-bin"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  target_path="$repo_root/.claude/worktrees/feature_one"
  wt_fixture_git -C "$repo_root" branch -m feature-one feature/one
  mkdir -p "$target_path/sub"
  echo "stale" > "$target_path/sub/marker.txt"
  install_wt_tmux_call_recorder "$stub_dir"

  (
    wt_holder_pid=""
    trap stop_wt_cwd_holder EXIT
    start_wt_cwd_holder "$target_path/sub"
    local output

    output=$(run_fixture_wt "$home_dir" "$repo_root" "$stub_dir:" --yes --if-exists=recreate feature/one 2>/dev/null) \
      || fail "--yes 재생성이 활성 가드에서 멈춤"
    [[ "$output" == "$target_path" ]] || fail "재생성은 worktree 경로를 내야 함: $output"
    [[ ! -e "$target_path/sub/marker.txt" ]] || fail "재생성이 기존 worktree를 지우지 않음"
    [[ "$(git -C "$target_path" branch --show-current)" == "feature/one" ]] \
      || fail "재생성된 worktree의 브랜치가 다름"
  )
  [[ ! -e "$stub_dir/tmux.calls" ]] || fail "wt가 tmux를 호출함: $(cat "$stub_dir/tmux.calls")"
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

    wt_source_helpers ui git-state process bootstrap
    _wt_require_state_helpers() { :; }
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

# 출력에서 "위험을 알고 진행하려면: <명령>" 안내 명령을 뽑는다 (색상 코드는 걷어 낸다).
wt_bypass_hint_from_output() {
  printf '%s\n' "$1" | sed $'s/\033\\[[0-9;]*m//g' | sed -n 's/.*위험을 알고 진행하려면: //p' | head -1
}

test_wt_cleanup_active_guard_hint_names_nested_worktree() {
  # 활성 가드가 안내하는 --yes 명령은 막힌 그 worktree를 가리켜야 한다. 이름은 wt ls가
  # 보여 주는 상대 경로(feat/x)다. 마지막 경로 요소(x)로 안내하면 같은 이름의 depth 1
  # worktree를 지목하고, 그 안내를 그대로 실행하면 커밋하지 않은 작업이 있는 다른
  # worktree가 지워진다(--yes는 dirty 확인도 넘긴다). 안내를 그대로 실행해 확인한다.
  local sandbox home_dir repo_root gh_dir base nested top
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  gh_dir="$sandbox/gh-bin"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  git -C "$repo_root" remote add origin https://example.invalid/nixos-config.git
  base="$repo_root/.claude/worktrees"
  nested="$base/feat/x"
  top="$base/x"
  add_fixture_worktree "$repo_root" "$nested" "feat-x"
  add_fixture_worktree "$repo_root" "$top" "x"
  echo "unsaved" > "$top/notes.txt"
  mkdir -p "$nested/sub"
  # feat/x만 MERGED로 둬 확인 프롬프트 없이 가드까지 가게 한다.
  install_merged_pr_mock_for_branch "$gh_dir" "feat-x" "$(git -C "$nested" rev-parse HEAD)"

  (
    wt_holder_pid=""
    trap stop_wt_cwd_holder EXIT
    start_wt_cwd_holder "$nested/sub"
    local output hint
    local -a hint_args

    output=$(run_fixture_wt "$home_dir" "$repo_root" "$gh_dir:" cleanup feat/x 2>&1) \
      || fail "cleanup feat/x 비정상 종료: $output"
    assert_contains "$output" "스킵: feat/x (이 worktree를 작업 위치로 쓰는 프로세스가 있습니다)"
    hint=$(wt_bypass_hint_from_output "$output")
    [[ "$hint" == "wt cleanup feat/x --yes" ]] || fail "--yes 안내가 막힌 worktree를 가리키지 않음: [$hint]"

    read -r -a hint_args <<< "${hint#wt }"
    output=$(run_fixture_wt "$home_dir" "$repo_root" "$gh_dir:" "${hint_args[@]}" 2>&1) \
      || fail "안내 명령 실행 실패: $output"
    [[ ! -d "$nested" ]] || fail "안내 명령이 feat/x를 지우지 않음: $output"
    [[ -f "$top/notes.txt" ]] || fail "안내 명령이 다른 worktree(x)를 지움: $output"
  )
}

test_wt_remove_worktree_guarded_failure_hint_names_nested_worktree_unit() {
  # guarded 제거를 git이 거부할 때의 재실행 안내(--yes)도 상대 경로 이름을 쓴다 — 위와
  # 같은 이유로, 마지막 경로 요소만 쓰면 다른 worktree를 지목한다.
  local sandbox repo wt_path
  sandbox=$(new_sandbox)
  repo="$(cd "$sandbox" && pwd -P)/repo"
  wt_path="$repo/.claude/worktrees/feat/x"
  mkdir -p "$repo"

  (
    set -euo pipefail
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    git -C "$repo" init -q
    git -C "$repo" config user.email t@example.invalid
    git -C "$repo" config user.name t
    git -C "$repo" commit -q --allow-empty -m first
    git -C "$repo" worktree add -q "$wt_path" -b feat-x
    local recorded_oid
    recorded_oid=$(git -C "$wt_path" rev-parse HEAD)
    # 추적하지 않는 파일이 있으면 비강제 remove가 거부한다.
    echo "untracked" > "$wt_path/untracked.txt"

    wt_source_helpers ui git-state process bootstrap
    _wt_require_state_helpers() { :; }
    _wt_cwd_holders() { :; }
    _wt_remove_claude_local_plugins_for_worktree() { :; }

    local output
    output=$(_remove_worktree "$wt_path" feat-x "$repo" guarded "$recorded_oid" 2>&1) && exit 11
    [[ "$output" == *"스킵: feat/x ("* ]] || exit 12
    [[ "$output" == *"wt cleanup feat/x --yes"* ]] || exit 13
    [[ -d "$wt_path" ]] || exit 14
  ) || fail "guarded 제거 실패 안내가 중첩 worktree 이름을 쓰지 않음 (exit $?)"
}

test_wt_lsof_escape_path_unit() {
  # lsof 필드 출력(LC_ALL=C)의 경로 표기를 그대로 재현해야 비교가 성립한다. 실측 형식:
  # 0x80 이상 바이트는 소문자 \xNN, 백슬래시는 \\, 나머지 출력 가능 ASCII(공백·%·따옴표
  # 포함)는 그대로다. 제어문자는 lsof 표기와 맞추지 않고 실패한다.
  local out rc
  out=$(bash -c '
    source "$1/modules/shared/scripts/lib/wt/process.sh"
    _wt_lsof_escape_path "$2"
  ' _ "$REPO_ROOT" $'/w/\xed\x95\x9c \\b%\'"~') || fail "출력 가능한 경로의 이스케이프가 실패함"
  [[ "$out" == '/w/\xed\x95\x9c \\b%'"'"'"~' ]] || fail "lsof 표기와 다름: [$out]"

  local bad
  for bad in $'/w/a\tb' $'/w/a\nb' $'/w/a\x7fb' $'/w/a\x01b'; do
    rc=0
    bash -c '
      source "$1/modules/shared/scripts/lib/wt/process.sh"
      _wt_lsof_escape_path "$2"
    ' _ "$REPO_ROOT" "$bad" >/dev/null || rc=$?
    [[ "$rc" == "1" ]] || fail "제어문자 경로는 실패(1)해야 함: $(printf '%q' "$bad") rc=$rc"
  done
}

test_wt_cwd_holders_fails_closed_on_control_char_path_unit() {
  # 대상 경로에 제어문자가 있으면 lsof 표기와 맞춰 볼 수 없으므로 판정 실패로 멈춘다 —
  # "맞는 이름이 없다"로 흘려 통과시키지 않는다. 대역 lsof는 실제 lsof(LC_ALL=C)처럼
  # 탭·개행을 `\t`·`\n`으로 적어 그 폴더를 cwd로 둔 프로세스를 보고한다(실측 표기). 날 경로와
  # 비교하면 맞는 이름이 없어 통과하므로, 결과는 "없음"이 아니라 실패여야 한다. 끝에 붙은
  # 개행도 잃지 않는다.
  local sandbox base bin table dir lsof_name out rc
  sandbox=$(new_sandbox)
  base="$(cd "$sandbox" && pwd -P)"
  bin="$sandbox/bin"
  table="$sandbox/proc.tsv"
  install_wt_fake_process_tools "$bin" "$table"

  for dir in "$base/wts/tab"$'\t'"x" "$base/wts/trailing-newline"$'\n'; do
    mkdir -p "$dir"
    lsof_name="${dir//$'\t'/\\t}"
    lsof_name="${lsof_name//$'\n'/\\n}"
    printf '%s\t%s\t%s\t%s\n' 970 1 "$lsof_name" "nvim notes.md" > "$table"
    rc=0
    out=$(PATH="$bin:$PATH" WT_LSOF="$bin/lsof" bash -c '
      set -euo pipefail
      source "$1/modules/shared/scripts/lib/wt/ui.sh"
      source "$1/modules/shared/scripts/lib/wt/process.sh"
      _wt_cwd_holders "$2"
    ' _ "$REPO_ROOT" "$dir") || rc=$?
    [[ "$rc" == "1" ]] || fail "제어문자 경로는 판정 실패(1)여야 함: $(printf '%q' "$dir") rc=$rc out=$out"
    assert_contains "$out" "제어문자"
  done
}

test_wt_cleanup_active_guard_matches_escaped_path() {
  # lsof -F는 경로를 이스케이프해 낸다. 이름에 한글·이모지·백슬래시(공백 포함)가 든
  # worktree를 실제 프로세스가 붙잡고 있을 때, 호출 환경의 locale(C·UTF-8)과 무관하게
  # 같은 판정을 내야 한다. 날 경로와 비교하면 이 프로세스를 놓쳐 그대로 지운다.
  local sandbox home_dir repo_root gh_dir name special loc
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  gh_dir="$sandbox/gh-bin"
  name='한글😀back\slash sp'

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  git -C "$repo_root" remote add origin https://example.invalid/nixos-config.git
  special="$repo_root/.claude/worktrees/$name"
  add_fixture_worktree "$repo_root" "$special" "feat-special"
  mkdir -p "$special/sub"
  install_merged_pr_mock_for_branch "$gh_dir" "feat-special" "$(git -C "$special" rev-parse HEAD)"

  (
    wt_holder_pid=""
    trap stop_wt_cwd_holder EXIT
    start_wt_cwd_holder "$special/sub"
    local output
    for loc in C C.UTF-8; do
      output=$(LC_ALL="$loc" run_fixture_wt "$home_dir" "$repo_root" "$gh_dir:" cleanup "$name" 2>&1) \
        || fail "LC_ALL=$loc cleanup 비정상 종료: $output"
      assert_contains "$output" "PID $wt_holder_pid: sleep 120"
      [[ -d "$special" ]] || fail "LC_ALL=$loc: 특수 문자 경로의 쓰는 중인 worktree가 지워짐: $output"
    done
  )
}

test_wt_cleanup_confirmed_dirty_keeps_active_guard() {
  # 확인 프롬프트 통과는 dirty/unpushed에 대한 승인이지 활성 가드 우회가 아니다. 커밋하지
  # 않은 변경이 있는 worktree를 WT_ASSUME_YES=1로 승인하면 제거 전략은 강제로 바뀌지만,
  # 그 worktree를 쓰는 프로세스가 있으면 여전히 보존하고 PID를 알려야 한다(--yes 인자 없음).
  local sandbox home_dir repo_root target_path
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  target_path="$repo_root/.claude/worktrees/feature_one"
  mkdir -p "$target_path/sub"
  echo "unsaved" > "$target_path/sub/notes.txt"

  (
    wt_holder_pid=""
    trap stop_wt_cwd_holder EXIT
    start_wt_cwd_holder "$target_path/sub"
    local output
    output=$(WT_ASSUME_YES=1 run_fixture_wt "$home_dir" "$repo_root" "" cleanup feature_one 2>&1) \
      || fail "cleanup <name> 비정상 종료: $output"
    assert_contains "$output" "uncommitted 변경사항"
    assert_contains "$output" "PID $wt_holder_pid: sleep 120"
    [[ -f "$target_path/sub/notes.txt" ]] || fail "확인 승인만으로 쓰는 중인 worktree가 지워짐: $output"
  )
}

test_wt_cwd_holders_ancestor_caffeinate_unit() {
  # 조상 체인이 띄운 caffeinate는 판정에서 뺀다. Claude Code 세션은 작업 중 caffeinate를
  # 자식으로 계속 새로 띄우고 그 cwd는 세션을 시작한 폴더라, 빼지 않으면 worktree에서 시작한
  # 세션의 정리가 매번 막힌다(caffeinate는 파일을 쓰지 않는다). 예외는 좁게 둔다: 부모가
  # 조상 체인에 있고 argv[0]의 basename이 정확히 caffeinate인 경우만이다.
  local sandbox base target bin table out expected
  sandbox=$(new_sandbox)
  base="$(cd "$sandbox" && pwd -P)"
  target="$base/wts/feat_a"
  mkdir -p "$target"
  bin="$sandbox/bin"
  table="$sandbox/proc.tsv"
  install_wt_fake_process_tools "$bin" "$table"

  out=$(
    PATH="$bin:$PATH" WT_LSOF="$bin/lsof" bash -c '
      set -euo pipefail
      table="$1" target="$2" repo="$3"
      self=$$
      row() { printf "%s\t%s\t%s\t%s\n" "$@" >> "$table"; }
      : > "$table"
      row 901 1 /elsewhere "zsh -l"                               # 조상의 조상
      row 900 901 "$target" "claude --resume"                     # 조상 (세션)
      row "$self" 900 /elsewhere "bash wt cleanup"                # wt 자신
      row 800 900 /elsewhere "bash -c wait-loop"                  # 형제 셸 (조상 아님)
      row 960 900 "$target" "caffeinate -i -t 300"                # 조상의 자식 caffeinate → 뺀다
      row 961 901 "$target" "/usr/bin/caffeinate -i"              # 경로가 붙은 caffeinate → 뺀다
      row 970 800 "$target" "caffeinate -i -t 300"                # 조상이 아닌 부모의 caffeinate
      row 971 900 "$target" "sleep 300"                           # 조상의 자식이지만 caffeinate 아님
      row 972 900 "$target" "caffeinate-x -i"                     # 이름만 비슷함
      row 973 900 "$target" "/tmp/caffeinate2 -i"                 # 이름만 비슷함
      source "$repo/modules/shared/scripts/lib/wt/ui.sh"
      source "$repo/modules/shared/scripts/lib/wt/process.sh"
      _wt_cwd_holders "$target"
    ' _ "$table" "$target" "$REPO_ROOT"
  ) || fail "_wt_cwd_holders가 정상 표에서 실패함: $out"

  expected=$'970\tcaffeinate -i -t 300\n971\tsleep 300\n972\tcaffeinate-x -i\n973\t/tmp/caffeinate2 -i'
  [[ "$out" == "$expected" ]] || fail "caffeinate 예외 판정이 다름: [$out] (기대: [$expected])"
}

# 대상 폴더를 cwd로 둔 caffeinate를 띄운다. parent=ancestor면 이 셸(wt의 조상)의 자식으로,
# parent=other면 cwd가 대상 밖인 별도 bash(조상 아님)의 자식으로 띄운다. PID는
# wt_caffeinate_pid에, 별도 bash는 wt_caffeinate_parent_pid에 남긴다. 호출한 셸에
# stop_wt_caffeinate EXIT trap을 먼저 건다.
start_wt_caffeinate() {
  local dir="$1" parent="$2" pid_file="$3" _
  if [[ "$parent" == "ancestor" ]]; then
    (cd "$dir" && exec caffeinate -t 120) &
    wt_caffeinate_pid=$!
  else
    : > "$pid_file"
    bash -c '(cd "$1" && exec caffeinate -t 120) & printf "%s\n" "$!" > "$2"; wait' _ "$dir" "$pid_file" &
    wt_caffeinate_parent_pid=$!
    for _ in {1..100}; do
      [[ -s "$pid_file" ]] && break
      sleep 0.05
    done
    wt_caffeinate_pid=$(cat "$pid_file")
  fi
  for _ in {1..100}; do
    [[ "$(ps -o command= -p "$wt_caffeinate_pid" 2>/dev/null)" == caffeinate* ]] && return 0
    sleep 0.05
  done
  fail "caffeinate가 뜨지 않음: $dir"
}

stop_wt_caffeinate() {
  [[ -z "${wt_caffeinate_pid:-}" ]] || kill "$wt_caffeinate_pid" 2>/dev/null || true
  if [[ -n "${wt_caffeinate_parent_pid:-}" ]]; then
    kill "$wt_caffeinate_parent_pid" 2>/dev/null || true
    wait "$wt_caffeinate_parent_pid" 2>/dev/null || true
  elif [[ -n "${wt_caffeinate_pid:-}" ]]; then
    wait "$wt_caffeinate_pid" 2>/dev/null || true
  fi
  wt_caffeinate_pid=""
  wt_caffeinate_parent_pid=""
}

test_wt_cleanup_ancestor_caffeinate_does_not_block() {
  # 실제 caffeinate로 예외 범위를 본다(Darwin 전용 — Linux에는 caffeinate가 없어 단위
  # 테스트가 규칙을 고정한다). 조상이 아닌 프로세스가 띄운 caffeinate는 막고, wt의 조상
  # (여기서는 테스트 셸)이 띄운 caffeinate는 정리를 막지 않는다.
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "N/A: caffeinate는 macOS 전용이라 실제 프로세스 검증은 이 실행 환경에 적용되지 않는다 (runner=$(uname -s))" >&2
    return 0
  fi
  command -v caffeinate >/dev/null 2>&1 || fail "macOS인데 caffeinate가 없음"

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
    wt_caffeinate_pid="" wt_caffeinate_parent_pid=""
    trap stop_wt_caffeinate EXIT
    local output

    start_wt_caffeinate "$target_path/sub" other "$sandbox/caffeinate.pid"
    output=$(run_fixture_wt "$home_dir" "$repo_root" "$gh_dir:" cleanup feature_one 2>&1) \
      || fail "cleanup 비정상 종료: $output"
    assert_contains "$output" "PID $wt_caffeinate_pid: caffeinate -t 120"
    [[ -d "$target_path" ]] || fail "조상이 아닌 프로세스가 띄운 caffeinate인데 지워짐: $output"
    stop_wt_caffeinate

    start_wt_caffeinate "$target_path/sub" ancestor ""
    output=$(run_fixture_wt "$home_dir" "$repo_root" "$gh_dir:" cleanup feature_one 2>&1) \
      || fail "cleanup 비정상 종료: $output"
    assert_not_contains "$output" "PID $wt_caffeinate_pid"
    assert_contains "$output" "정리 완료: 1개 삭제"
    [[ ! -d "$target_path" ]] || fail "조상이 띄운 caffeinate가 정리를 막음: $output"
  )
}
