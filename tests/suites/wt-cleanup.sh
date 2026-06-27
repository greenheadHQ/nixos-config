# tests/suites/wt-cleanup.sh — 도메인 테스트 정의 (sourced; aggregator가 lib/test-common.sh 후 source)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# shellcheck disable=SC2154,SC2164
add_stale_worktree() {
  # 손상(stale) worktree fixture: .git이 존재하지 않는 gitdir을 가리킨다 (사용자명
  # 마이그레이션 잔재 모사 — #883의 실제 트리거). 'aaa_broken'은 정렬상 feature_one보다
  # 앞서므로 _collect_worktrees(find … | sort -z)가 먼저 수집 → items 빌드 루프가 정상
  # worktree 전에 손상 worktree에 도달, 가드가 없다면 _wt_last_commit_msg 무가드
  # 파이프라인이 set -e/pipefail로 폭사(exit 128)하는 회귀 조건을 만든다.
  local repo_root="$1"
  local broken_path="$repo_root/.claude/worktrees/aaa_broken"
  mkdir -p "$broken_path"
  printf 'gitdir: /nonexistent/green/Workspace/nixos-config/.git/worktrees/aaa_broken\n' > "$broken_path/.git"
}
test_wt_recreate_guard_uses_physical_paths() {
  local sandbox home_dir repo_root link_root target_path origin_dir output
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  link_root="$sandbox/link"
  origin_dir="$sandbox/origin.git"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  git init --bare "$origin_dir" >/dev/null 2>&1
  git -C "$repo_root" remote add origin "$origin_dir"
  git -C "$repo_root/.claude/worktrees/feature_one" push -u origin feature-one >/dev/null 2>&1
  ln -s "$repo_root" "$link_root"
  target_path="$link_root/.claude/worktrees/feature_one"

  output=$(
    env -u TMUX \
      HOME="$home_dir" \
      PATH="$FIXTURE_DIR/bin:$PATH" \
      WT_NONINTERACTIVE=1 \
      bash -c '
      set -euo pipefail
      cd "'"$target_path"'"
      "'"$home_dir/.local/bin/wt"'" --if-exists=recreate feature/one
    ' 2>&1 || true
  )

  assert_contains "$output" "재생성 불가: 현재 작업 디렉토리가 이 worktree 안에 있습니다"
  [[ -d "$repo_root/.claude/worktrees/feature_one" ]] || fail "expected original worktree to survive recreate guard"
}

test_wt_cleanup_auto_removes_merged_worktree() {
  local sandbox home_dir repo_root gh_dir output target_path head_oid
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  gh_dir="$sandbox/gh-bin"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  git -C "$repo_root" remote add origin https://example.invalid/nixos-config.git
  target_path="$repo_root/.claude/worktrees/feature_one"
  head_oid="$(git -C "$target_path" rev-parse HEAD)"

  mkdir -p "$gh_dir"
  cat > "$gh_dir/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'MERGED %s\n' "$head_oid"
EOF
  chmod +x "$gh_dir/gh"

  output=$(
    HOME="$home_dir" \
    PATH="$gh_dir:$FIXTURE_DIR/bin:$PATH" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/wt"'" cleanup --auto
    ' 2>&1
  )

  assert_contains "$output" "자동 정리 완료"
  [[ ! -d "$target_path" ]] || fail "expected merged worktree to be removed: $target_path"
}

test_wt_cleanup_auto_skips_dirty_merged_worktree() {
  local sandbox home_dir repo_root gh_dir output target_path head_oid
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  gh_dir="$sandbox/gh-bin"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  git -C "$repo_root" remote add origin https://example.invalid/nixos-config.git
  target_path="$repo_root/.claude/worktrees/feature_one"
  head_oid="$(git -C "$target_path" rev-parse HEAD)"
  echo "dirty" > "$target_path/dirty.txt"

  mkdir -p "$gh_dir"
  cat > "$gh_dir/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'MERGED %s\n' "$head_oid"
EOF
  chmod +x "$gh_dir/gh"

  output=$(
    HOME="$home_dir" \
    PATH="$gh_dir:$FIXTURE_DIR/bin:$PATH" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/wt"'" cleanup --auto
    ' 2>&1
  )

  assert_contains "$output" "스킵: feature_one (dirty 있음)"
  [[ -d "$target_path" ]] || fail "expected dirty worktree to be kept: $target_path"
}

test_wt_cleanup_auto_skips_unpushed_with_upstream() {
  local sandbox home_dir repo_root gh_dir origin_dir output target_path head_oid
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  gh_dir="$sandbox/gh-bin"
  origin_dir="$sandbox/origin.git"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  git init --bare "$origin_dir" >/dev/null 2>&1
  git -C "$repo_root" remote add origin "$origin_dir"
  target_path="$repo_root/.claude/worktrees/feature_one"
  git -C "$target_path" push -u origin feature-one >/dev/null 2>&1
  echo "ahead" >> "$target_path/README.md"
  git -C "$target_path" add README.md
  git -C "$target_path" commit -m "ahead" >/dev/null 2>&1
  head_oid="$(git -C "$target_path" rev-parse HEAD)"

  mkdir -p "$gh_dir"
  cat > "$gh_dir/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'MERGED %s\n' "$head_oid"
EOF
  chmod +x "$gh_dir/gh"

  output=$(
    HOME="$home_dir" \
    PATH="$gh_dir:$FIXTURE_DIR/bin:$PATH" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/wt"'" cleanup --auto
    ' 2>&1
  )

  assert_contains "$output" "스킵: feature_one (merge 후 추가 커밋 있음)"
  [[ -d "$target_path" ]] || fail "expected unpushed worktree to be kept: $target_path"
}

test_wt_cleanup_auto_skips_merged_branch_reuse() {
  local sandbox home_dir repo_root gh_dir output target_path
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  gh_dir="$sandbox/gh-bin"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  target_path="$repo_root/.claude/worktrees/feature_one"
  mkdir -p "$gh_dir"
  cat > "$gh_dir/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'MERGED deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n'
EOF
  chmod +x "$gh_dir/gh"

  output=$(
    HOME="$home_dir" \
    PATH="$gh_dir:$FIXTURE_DIR/bin:$PATH" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/wt"'" cleanup --auto
    ' 2>&1
  )

  assert_contains "$output" "자동 정리 대상 (MERGED)이 없습니다"
  [[ -d "$target_path" ]] || fail "expected reused branch worktree to be kept: $target_path"
}

test_wt_cleanup_auto_survives_stale_worktree() {
  # #883 회귀: 손상(stale) worktree가 섞여 있어도 wt cleanup --auto가 git fatal(exit 128)로
  # silent 폭사하지 않고, 정상 MERGED worktree는 정리하며 손상 worktree는 경고 후 건너뛴다.
  local sandbox home_dir repo_root gh_dir output target_path broken_path head_oid rc
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  gh_dir="$sandbox/gh-bin"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  git -C "$repo_root" remote add origin https://example.invalid/nixos-config.git
  target_path="$repo_root/.claude/worktrees/feature_one"
  broken_path="$repo_root/.claude/worktrees/aaa_broken"
  head_oid="$(git -C "$target_path" rev-parse HEAD)"
  add_stale_worktree "$repo_root"

  mkdir -p "$gh_dir"
  cat > "$gh_dir/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'MERGED %s\n' "$head_oid"
EOF
  chmod +x "$gh_dir/gh"

  rc=0
  output=$(
    HOME="$home_dir" \
    PATH="$gh_dir:$FIXTURE_DIR/bin:$PATH" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/wt"'" cleanup --auto
    ' 2>&1
  ) || rc=$?

  [[ "$rc" != "128" ]] || fail "cleanup --auto가 손상 worktree에서 git fatal(128)로 폭사: $output"
  [[ "$rc" == "0" ]] || fail "cleanup --auto 비정상 종료 rc=$rc: $output"
  assert_contains "$output" "자동 정리 완료"
  assert_contains "$output" "손상된 worktree 건너뜀: aaa_broken"
  assert_contains "$output" "손상 1개 건너뜀"  # 요약 suffix로 broken_count 노출·정확도 고정
  [[ ! -d "$target_path" ]] || fail "정상 MERGED worktree가 제거되지 않음: $target_path"
  [[ -d "$broken_path" ]] || fail "손상 worktree는 보존돼야 함(정리 제외): $broken_path"
}

test_wt_cleanup_name_filter_survives_stale_worktree() {
  # #883 회귀: name-filter 경로(wt cleanup <name>)도 손상 worktree가 섞여 있어도 exit 128로
  # silent 폭사하지 않고, 지정한 정상 worktree를 정리하며 손상 worktree는 경고 후 건너뛴다.
  local sandbox home_dir repo_root gh_dir output target_path broken_path head_oid rc
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  gh_dir="$sandbox/gh-bin"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  git -C "$repo_root" remote add origin https://example.invalid/nixos-config.git
  target_path="$repo_root/.claude/worktrees/feature_one"
  broken_path="$repo_root/.claude/worktrees/aaa_broken"
  head_oid="$(git -C "$target_path" rev-parse HEAD)"
  add_stale_worktree "$repo_root"

  mkdir -p "$gh_dir"
  cat > "$gh_dir/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'MERGED %s\n' "$head_oid"
EOF
  chmod +x "$gh_dir/gh"

  rc=0
  output=$(
    HOME="$home_dir" \
    PATH="$gh_dir:$FIXTURE_DIR/bin:$PATH" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/wt"'" cleanup feature_one --yes
    ' 2>&1
  ) || rc=$?

  [[ "$rc" != "128" ]] || fail "cleanup <name>이 손상 worktree에서 git fatal(128)로 폭사: $output"
  [[ "$rc" == "0" ]] || fail "cleanup <name> 비정상 종료 rc=$rc: $output"
  assert_contains "$output" "정리 완료: 1개 삭제"
  assert_contains "$output" "손상된 worktree 건너뜀: aaa_broken"
  assert_contains "$output" "손상 1개 건너뜀"  # 요약 suffix로 broken_count 노출·정확도 고정
  [[ ! -d "$target_path" ]] || fail "지정한 정상 worktree가 제거되지 않음: $target_path"
  [[ -d "$broken_path" ]] || fail "손상 worktree는 보존돼야 함(정리 제외): $broken_path"
}

test_wt_cleanup_auto_broken_only_reports_skip_count() {
  # #883 broken-only 시나리오: 손상 worktree만 있고 MERGED 정리 대상이 0인 경우
  # (cleanup.sh의 merged_indices==0 early-return 분기 — PoC가 실제로 밟던 경로).
  # gh mock·origin remote를 두지 않아 PR 상태가 NONE이 되어 merged_indices가 비고,
  # cleanup이 폭사하지 않고 손상 카운트를 종합 요약에 일관 노출하며 둘 다 보존하는지 고정.
  local sandbox home_dir repo_root output target_path broken_path rc
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  target_path="$repo_root/.claude/worktrees/feature_one"
  broken_path="$repo_root/.claude/worktrees/aaa_broken"
  add_stale_worktree "$repo_root"

  rc=0
  output=$(
    HOME="$home_dir" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/wt"'" cleanup --auto
    ' 2>&1
  ) || rc=$?

  [[ "$rc" != "128" ]] || fail "broken-only cleanup --auto가 git fatal(128)로 폭사: $output"
  [[ "$rc" == "0" ]] || fail "broken-only cleanup --auto 비정상 종료 rc=$rc: $output"
  assert_contains "$output" "손상된 worktree 건너뜀: aaa_broken"
  assert_contains "$output" "자동 정리 대상 (MERGED)이 없습니다 (손상 1개 건너뜀)"
  [[ -d "$broken_path" ]] || fail "손상 worktree는 보존돼야 함(정리 제외): $broken_path"
  [[ -d "$target_path" ]] || fail "MERGED 아닌 정상 worktree는 보존돼야 함: $target_path"
}
