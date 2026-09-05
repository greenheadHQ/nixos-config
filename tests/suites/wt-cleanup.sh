# tests/suites/wt-cleanup.sh — 도메인 테스트 정의 (sourced; aggregator가 lib/test-common.sh 후 source)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# SC2153: REPO_ROOT도 같은 aggregator 정의 변수라 local repo_root 오타가 아니다.
# SC2030/SC2031: 단위 테스트가 subshell 안에서만 PATH를 바꾸는 것은 의도된 격리다.
# shellcheck disable=SC2154,SC2164,SC2153,SC2030,SC2031
# MERGED PR을 보고하는 gh mock. 여러 테스트가 같은 출력 프로토콜을 쓰므로 한곳에 둔다 —
# `_wt_pr_status`가 파싱하는 형식("<STATE> <headRefOid>")이 바뀌면 이 함수만 고치면 된다.
install_merged_pr_mock() {
  local gh_dir="$1" head_oid="$2"
  mkdir -p "$gh_dir"
  cat > "$gh_dir/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'MERGED %s\n' "$head_oid"
EOF
  chmod +x "$gh_dir/gh"
}

# 지정한 브랜치에만 MERGED를 보고하는 gh mock. "MERGED 후보가 실제로 있는데도 지우지
# 않는다"를 검증하려면 대상 worktree만 MERGED여야 한다 — 아무것도 MERGED가 아니면 후보가
# 0이라 가드를 지워도 통과하는 비판별 테스트가 되고, 전부 MERGED면 다른 worktree 삭제가
# 섞여 어서션이 흐려진다.
install_merged_pr_mock_for_branch() {
  local gh_dir="$1" branch="$2" head_oid="$3"
  mkdir -p "$gh_dir"
  cat > "$gh_dir/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
for arg in "\$@"; do
  if [[ "\$arg" == "$branch" ]]; then
    printf 'MERGED %s\n' "$head_oid"
    exit 0
  fi
done
exit 1
EOF
  chmod +x "$gh_dir/gh"
}

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
      CODEX_HOME="$home_dir/.codex" \
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

test_wt_recreate_refuses_locked_worktree() {
  # `--if-exists=recreate`는 제거를 포함하므로 삭제 경로와 같은 잠금 계약을 지켜야 한다.
  # 과거 구현은 `git worktree remove --force || rm -rf`라, 잠긴 worktree를 recreate하면
  # git이 거부한 뒤 rm -rf가 미커밋 파일까지 지웠고(잠근 주체가 쓰던 디렉토리 파괴),
  # 이어지는 prune은 잠긴 등록을 건너뛰어 유령 등록이 남았다 (실측).
  local sandbox home_dir repo_root locked_path output rc
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  locked_path="$repo_root/.claude/worktrees/feature_one"
  echo "precious" > "$locked_path/precious.txt"
  lock_fixture_worktree "$repo_root" "$locked_path" "bridge holds it"

  rc=0
  output=$(
    env -u TMUX \
      HOME="$home_dir" \
      CODEX_HOME="$home_dir/.codex" \
      PATH="$FIXTURE_DIR/bin:$PATH" \
      WT_NONINTERACTIVE=1 \
      WT_ASSUME_YES=1 \
      bash -c '
        set -euo pipefail
        cd "'"$repo_root"'"
        "'"$home_dir/.local/bin/wt"'" --if-exists=recreate feature/one
      ' 2>&1
  ) || rc=$?

  # WT_ASSUME_YES=1: dirty 확인 프롬프트를 통과시켜 잠금 가드까지 실제로 도달하게 한다
  # (여기서 멈추면 "확인 때문에 안 지워진 것"과 구분되지 않아 비판별 테스트가 된다).
  [[ "$rc" != "0" ]] || fail "잠긴 worktree 재생성은 실패해야 함: $output"
  assert_contains "$output" "재생성 불가: feature_one (잠긴 worktree — 사유: bridge holds it"
  [[ -f "$locked_path/precious.txt" ]] || fail "잠긴 worktree의 미커밋 파일이 파괴됨: $output"
  git -C "$repo_root" worktree list --porcelain | grep -qxF "worktree $locked_path" \
    || fail "잠긴 worktree 등록이 사라짐: $locked_path"
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

  install_merged_pr_mock "$gh_dir" "$head_oid"

  output=$(
    HOME="$home_dir" \
    CODEX_HOME="$home_dir/.codex" \
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

  install_merged_pr_mock "$gh_dir" "$head_oid"

  output=$(
    HOME="$home_dir" \
    CODEX_HOME="$home_dir/.codex" \
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

  install_merged_pr_mock "$gh_dir" "$head_oid"

  output=$(
    HOME="$home_dir" \
    CODEX_HOME="$home_dir/.codex" \
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
  # 로컬 HEAD와 다른 OID = 동명의 다른 브랜치 (branch name reuse)
  install_merged_pr_mock "$gh_dir" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

  output=$(
    HOME="$home_dir" \
    CODEX_HOME="$home_dir/.codex" \
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

  install_merged_pr_mock "$gh_dir" "$head_oid"

  rc=0
  output=$(
    HOME="$home_dir" \
    CODEX_HOME="$home_dir/.codex" \
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

  install_merged_pr_mock "$gh_dir" "$head_oid"

  rc=0
  output=$(
    HOME="$home_dir" \
    CODEX_HOME="$home_dir/.codex" \
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
    CODEX_HOME="$home_dir/.codex" \
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

test_wt_cleanup_name_filter_merged_without_upstream_needs_no_confirm() {
  # squash merge 후 원격 브랜치가 삭제되면 upstream이 사라져 _wt_has_unpushed가
  # 보수적 true를 낸다. 그 값을 그대로 믿으면 이미 머지된 worktree가 "push하지 않은
  # 커밋 있음"으로 확인을 요구하고, 비대화형(finish-pr 등)에서는 확인이 실패해
  # 정리가 막힌다. PR MERGED는 headRefOid == 로컬 HEAD가 검증된 상태이므로
  # --yes 없이도 확인 프롬프트 없이 정리돼야 한다.
  local sandbox home_dir repo_root gh_dir output target_path head_oid
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  gh_dir="$sandbox/gh-bin"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  # origin은 있으나 push하지 않아 upstream이 없는 상태 (= squash merge 후 원격
  # 브랜치가 삭제되고 remote-tracking ref까지 정리된 상황과 동일한 git 상태)
  git -C "$repo_root" remote add origin https://example.invalid/nixos-config.git
  target_path="$repo_root/.claude/worktrees/feature_one"
  head_oid="$(git -C "$target_path" rev-parse HEAD)"

  install_merged_pr_mock "$gh_dir" "$head_oid"

  output=$(
    HOME="$home_dir" \
    CODEX_HOME="$home_dir/.codex" \
    PATH="$gh_dir:$FIXTURE_DIR/bin:$PATH" \
    WT_NONINTERACTIVE=1 \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/wt"'" cleanup feature_one
    ' 2>&1
  )

  assert_contains "$output" "정리 완료: 1개 삭제"
  assert_not_contains "$output" "비대화형: 확인 필요"
  assert_not_contains "$output" "push하지 않은 커밋"
  [[ ! -d "$target_path" ]] || fail "MERGED worktree가 upstream 부재로 정리되지 않음: $target_path"
}

test_wt_cleanup_name_filter_confirmed_dirty_merged_removes() {
  # 삭제 정책은 PR 상태가 아니라 "사용자가 승인했는가"로 갈린다. dirty + MERGED를
  # --yes로 승인하면 강제 삭제로 진행돼야 한다 — 승인 경로까지 비강제로 끌려가면
  # git이 dirty를 거부해 "0개 삭제"만 반복하고 CLAUDE.md의 --yes 우회 계약이 깨진다.
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
  install_merged_pr_mock "$gh_dir" "$head_oid"

  output=$(
    HOME="$home_dir" \
    CODEX_HOME="$home_dir/.codex" \
    PATH="$gh_dir:$FIXTURE_DIR/bin:$PATH" \
    WT_NONINTERACTIVE=1 \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/wt"'" cleanup feature_one --yes
    ' 2>&1
  )

  assert_contains "$output" "정리 완료: 1개 삭제"
  [[ ! -d "$target_path" ]] || fail "--yes로 승인한 dirty MERGED worktree가 삭제되지 않음: $target_path"
}

test_wt_cleanup_name_filter_current_worktree_reports_root_command() {
  # #1186: worktree 안에서 자기 자신을 정리하려 하면 items에서 제외되어 삭제되지
  # 않는데, 과거 메시지는 세 원인을 뭉뚱그려 사용자가 어느 쪽인지 몰랐고 해결
  # 방법도 없었다. 원인을 특정하고 저장소 루트 재실행 명령을 제시해야 한다.
  local sandbox home_dir repo_root output target_path
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  target_path="$repo_root/.claude/worktrees/feature_one"

  output=$(
    env -u TMUX \
      HOME="$home_dir" \
      CODEX_HOME="$home_dir/.codex" \
      PATH="$FIXTURE_DIR/bin:$PATH" \
      WT_NONINTERACTIVE=1 \
      bash -c '
      set -euo pipefail
      cd "'"$target_path"'"
      "'"$home_dir/.local/bin/wt"'" cleanup feature_one
    ' 2>&1 || true
  )

  assert_contains "$output" "현재 위치한 worktree라 여기서는 삭제할 수 없습니다: feature_one"
  assert_contains "$output" "저장소 루트에서 실행하세요"
  [[ -d "$target_path" ]] || fail "현재 worktree는 보존돼야 함: $target_path"

  # 안내 책임이 공통 블록과 미매칭 분기에 중복되면 같은 재실행 명령이 두 번 나온다.
  # 이름 지정 호출에서는 미매칭 분기 하나만 안내해야 한다.
  local guide_count
  guide_count=$(printf '%s\n' "$output" | grep -c "저장소 루트에서 실행하세요" || true)
  [[ "$guide_count" == "1" ]] || fail "재실행 안내가 1회여야 하는데 ${guide_count}회 출력됨: $output"
}

test_wt_cleanup_reports_missing_worktree_prune_hint() {
  # 등록만 남고 디렉토리가 사라진 worktree(잠긴 브리지 worktree 등이 prune을 못 받은 잔재).
  # 과거엔 디렉토리 스캔 기준이라 아예 보이지 않았다. 손상 경로로 흘려 건너뛰되, 이
  # 상황에서 실제로 듣는 명령(prune)을 안내해야 한다 — rm -rf 안내는 지울 경로가 없다.
  local sandbox home_dir repo_root output gone_path locked_gone_path target_path rc
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  target_path="$repo_root/.claude/worktrees/feature_one"
  gone_path="$repo_root/.claude/worktrees/zz_gone"
  add_fixture_worktree "$repo_root" "$gone_path" "zz-gone"
  rm -rf "$gone_path"

  # 실제 문제 사례(잠긴 Claude 브리지 worktree)는 "잠김 + 디렉토리 없음" 조합이다.
  # 이 조합에 prune만 안내하면 prune이 잠긴 등록을 건너뛰어(실측) 아무 일도 일어나지 않는다.
  locked_gone_path="$repo_root/.claude/worktrees/zz_locked_gone"
  add_fixture_worktree "$repo_root" "$locked_gone_path" "zz-locked-gone"
  lock_fixture_worktree "$repo_root" "$locked_gone_path" "bridge holds it"
  rm -rf "$locked_gone_path"

  rc=0
  output=$(
    HOME="$home_dir" \
    CODEX_HOME="$home_dir/.codex" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/wt"'" cleanup --auto
    ' 2>&1
  ) || rc=$?

  [[ "$rc" == "0" ]] || fail "cleanup --auto 비정상 종료 rc=$rc: $output"
  assert_contains "$output" "손상된 worktree 건너뜀: zz_gone (디렉토리 없음 — 수동 정리: git worktree prune)"
  assert_contains "$output" "손상된 worktree 건너뜀: zz_locked_gone (디렉토리 없음(잠김) — 수동 정리: git worktree unlock"
  assert_contains "$output" "후 git worktree prune"
  assert_contains "$output" "자동 정리 대상 (MERGED)이 없습니다 (손상 2개 건너뜀)"
  [[ -d "$target_path" ]] || fail "정상 worktree는 보존돼야 함: $target_path"
}

test_wt_cleanup_skips_locked_worktree() {
  # git lock은 "다른 주체가 이 worktree를 붙잡고 있다"는 신호이고, tmux pane 기반 활성
  # 판정에는 잡히지 않는다. --auto도, 이름 지정 --yes도 정리해서는 안 되며(--yes는 제거
  # 전략만 바꾸지 잠금을 해제하지 않는다) 디렉토리와 git 등록이 모두 그대로 남아야 한다.
  #
  # 대상 worktree를 MERGED로 만들어 두는 것이 이 테스트의 판별력이다: PR이 없으면 --auto의
  # 후보가 애초에 0이라, 후보 수집의 잠금 가드를 지우고 경고만 남겨도 통과한다.
  # 마지막에 unlock 후 같은 --auto가 실제로 지우는지까지 봐서 과잉 차단 회귀도 덮는다.
  local sandbox home_dir repo_root gh_dir auto_out named_out unlocked_out locked_path head_oid rc
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  gh_dir="$sandbox/gh-bin"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  git -C "$repo_root" remote add origin https://example.invalid/nixos-config.git

  locked_path="$repo_root/.claude/worktrees/zz_locked"
  add_fixture_worktree "$repo_root" "$locked_path" "zz-locked"
  head_oid="$(git -C "$locked_path" rev-parse HEAD)"
  install_merged_pr_mock_for_branch "$gh_dir" "zz-locked" "$head_oid"
  lock_fixture_worktree "$repo_root" "$locked_path" "bridge holds it"

  rc=0
  auto_out=$(
    HOME="$home_dir" \
    CODEX_HOME="$home_dir/.codex" \
    PATH="$gh_dir:$FIXTURE_DIR/bin:$PATH" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/wt"'" cleanup --auto
    ' 2>&1
  ) || rc=$?
  [[ "$rc" == "0" ]] || fail "cleanup --auto 비정상 종료 rc=$rc: $auto_out"
  assert_contains "$auto_out" "잠긴 worktree 건너뜀: zz_locked (사유: bridge holds it"
  # MERGED인데도 후보 수집에서 빠졌음을 요약으로 고정한다 (경고만 내고 후보에 남는 회귀 차단).
  assert_contains "$auto_out" "자동 정리 대상 (MERGED)이 없습니다 (잠김 1개 건너뜀)"
  assert_not_contains "$auto_out" "삭제: zz_locked"

  rc=0
  named_out=$(
    HOME="$home_dir" \
    CODEX_HOME="$home_dir/.codex" \
    PATH="$gh_dir:$FIXTURE_DIR/bin:$PATH" \
    WT_NONINTERACTIVE=1 \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/wt"'" cleanup zz_locked --yes
    ' 2>&1
  ) || rc=$?
  [[ "$rc" == "0" ]] || fail "cleanup <name> --yes 비정상 종료 rc=$rc: $named_out"
  assert_contains "$named_out" "정리 대상 아님: zz_locked (잠긴 worktree"
  assert_contains "$named_out" "정리 완료: 0개 삭제"

  [[ -d "$locked_path" ]] || fail "잠긴 worktree 디렉토리가 삭제됨: $locked_path"
  git -C "$repo_root" worktree list --porcelain | grep -qxF "worktree $locked_path" \
    || fail "잠긴 worktree 등록이 사라짐: $locked_path"

  # 잠금을 풀면 같은 MERGED 후보가 실제로 정리돼야 한다 — 가드가 잠금이 아닌 다른 이유로
  # 항상 막고 있었다면 여기서 드러난다.
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -C "$repo_root" worktree unlock "$locked_path" >/dev/null 2>&1 \
    || fail "fixture unlock 실패: $locked_path"

  rc=0
  unlocked_out=$(
    HOME="$home_dir" \
    CODEX_HOME="$home_dir/.codex" \
    PATH="$gh_dir:$FIXTURE_DIR/bin:$PATH" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/wt"'" cleanup --auto
    ' 2>&1
  ) || rc=$?
  [[ "$rc" == "0" ]] || fail "unlock 후 cleanup --auto 비정상 종료 rc=$rc: $unlocked_out"
  assert_contains "$unlocked_out" "자동 정리 완료"
  [[ ! -d "$locked_path" ]] || fail "unlock 후에는 MERGED worktree가 정리돼야 함: $unlocked_out"
}

test_wt_cleanup_name_prefers_exact_relative_name() {
  # depth 2 이상 경로를 수집하게 되면서 마지막 경로 요소가 겹칠 수 있다. 이름 매칭이
  # basename 선착순이면 목록 정렬상 먼저 오는 nested 쪽이 선택되어, 사용자가 지목한
  # top-level 대신 다른 worktree가 지워진다 (`zz` vs `feat/zz`로 실측). 이름은 wt_base
  # 상대 경로이므로 정확 일치가 우선이어야 한다.
  local sandbox home_dir repo_root top_path nested_path output rc
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  top_path="$repo_root/.claude/worktrees/zz"
  nested_path="$repo_root/.claude/worktrees/feat/zz"
  add_fixture_worktree "$repo_root" "$top_path" "zz-top"
  add_fixture_worktree "$repo_root" "$nested_path" "zz-nested"

  rc=0
  output=$(
    HOME="$home_dir" \
    CODEX_HOME="$home_dir/.codex" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    WT_NONINTERACTIVE=1 \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/wt"'" cleanup zz --yes
    ' 2>&1
  ) || rc=$?
  [[ "$rc" == "0" ]] || fail "cleanup zz --yes 비정상 종료 rc=$rc: $output"
  assert_contains "$output" "정리 완료: 1개 삭제"
  [[ ! -d "$top_path" ]] || fail "이름이 정확히 일치하는 top-level worktree가 지워져야 함: $output"
  [[ -d "$nested_path" ]] || fail "지목하지 않은 nested worktree가 지워짐: $nested_path"
}

test_wt_cleanup_refuses_ambiguous_name() {
  # 정확 일치가 없고 마지막 경로 요소만 여러 개 맞으면 아무것도 지우지 않는다(fail-closed).
  # 선착순으로 하나를 고르면 사용자가 지목하지 않은 worktree가 조용히 사라진다.
  # 상대 경로로 정확히 지정하면 그 항목만 지워져야 한다.
  local sandbox home_dir repo_root feat_path bug_path amb_out exact_out rc
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  feat_path="$repo_root/.claude/worktrees/feat/zz"
  bug_path="$repo_root/.claude/worktrees/bug/zz"
  add_fixture_worktree "$repo_root" "$feat_path" "zz-feat"
  add_fixture_worktree "$repo_root" "$bug_path" "zz-bug"

  rc=0
  amb_out=$(
    HOME="$home_dir" \
    CODEX_HOME="$home_dir/.codex" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    WT_NONINTERACTIVE=1 \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/wt"'" cleanup zz --yes
    ' 2>&1
  ) || rc=$?
  [[ "$rc" == "0" ]] || fail "cleanup zz --yes 비정상 종료 rc=$rc: $amb_out"
  assert_contains "$amb_out" "정리 대상 모호: zz"
  assert_contains "$amb_out" "후보: bug/zz"
  assert_contains "$amb_out" "후보: feat/zz"
  assert_contains "$amb_out" "정리 완료: 0개 삭제"
  [[ -d "$feat_path" ]] || fail "모호한 이름으로 feat/zz가 지워짐"
  [[ -d "$bug_path" ]] || fail "모호한 이름으로 bug/zz가 지워짐"

  rc=0
  exact_out=$(
    HOME="$home_dir" \
    CODEX_HOME="$home_dir/.codex" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    WT_NONINTERACTIVE=1 \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/wt"'" cleanup feat/zz --yes
    ' 2>&1
  ) || rc=$?
  [[ "$rc" == "0" ]] || fail "cleanup feat/zz --yes 비정상 종료 rc=$rc: $exact_out"
  assert_contains "$exact_out" "정리 완료: 1개 삭제"
  [[ ! -d "$feat_path" ]] || fail "상대 경로로 지정한 worktree가 지워지지 않음: $exact_out"
  [[ -d "$bug_path" ]] || fail "지정하지 않은 bug/zz가 지워짐"
}

test_wt_pr_status_returns_verified_oid_unit() {
  # MERGED 판정의 근거는 "PR headRefOid == 그 시점 로컬 HEAD" 비교다. 그 비교에 사용한
  # OID 자체를 반환해야 하며, 판정 후 HEAD를 다시 읽어서는 안 된다 — 두 읽기 사이에
  # 생긴 커밋이 근거로 둔갑하면 삭제 직전 재검증이 그 커밋을 통과시킨다.
  local sandbox repo gh_dir head_oid raw
  sandbox=$(new_sandbox)
  repo="$sandbox/repo"
  gh_dir="$sandbox/gh-bin"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@example.invalid
  git -C "$repo" config user.name t
  git -C "$repo" commit -q --allow-empty -m first
  git -C "$repo" remote add origin https://example.invalid/x.git
  head_oid=$(git -C "$repo" rev-parse HEAD)
  install_merged_pr_mock "$gh_dir" "$head_oid"

  raw=$(
    set -euo pipefail
    PATH="$gh_dir:$PATH"
    source "$REPO_ROOT/modules/shared/scripts/lib/wt/git-state.sh"
    _wt_pr_status "feature-one" "$repo" "$repo"
  )

  [[ "$raw" == "MERGED $head_oid" ]] \
    || fail "MERGED와 검증 OID를 함께 반환해야 함: got='$raw' expected='MERGED $head_oid'"

  # 브랜치 이름이 재사용된 경우(로컬 HEAD가 PR OID와 다름)는 근거 없이 NONE이다.
  local reuse_raw
  git -C "$repo" commit -q --allow-empty -m second
  reuse_raw=$(
    set -euo pipefail
    PATH="$gh_dir:$PATH"
    source "$REPO_ROOT/modules/shared/scripts/lib/wt/git-state.sh"
    _wt_pr_status "feature-one" "$repo" "$repo"
  )
  [[ "$reuse_raw" == "NONE" ]] || fail "재사용 브랜치는 NONE이어야 하는데 '$reuse_raw'"
}

test_wt_tmux_session_state_classification_unit() {
  # 서버 부재와 조회 불능을 stderr errno 문구로 가른다. 이 분류가 한쪽으로 치우치면
  # 정상적인 서버 부재가 unknown이 되어 무확인 정리가 전부 막히거나(실제로 겪은 회귀),
  # 반대로 권한 오류가 absent로 통과해 접근 못 하는 활성 세션의 worktree가 지워진다.
  local sandbox bin state msg expect case_spec
  sandbox=$(new_sandbox)
  bin="$sandbox/bin"
  mkdir -p "$bin"

  for case_spec in \
    "no server running on /tmp/x|absent" \
    "error connecting to /tmp/x (No such file or directory)|absent" \
    "error connecting to /tmp/x (Connection refused)|absent" \
    "error connecting to /tmp/x (Permission denied)|unknown" \
    "server exited unexpectedly|unknown"
  do
    msg="${case_spec%|*}"
    expect="${case_spec##*|}"
    cat > "$bin/tmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$msg" >&2
exit 1
EOF
    chmod +x "$bin/tmux"

    state=$(
      PATH="$bin:$PATH" bash -c '
        set -euo pipefail
        source "$1/modules/shared/scripts/lib/wt/tmux.sh"
        _wt_tmux_session_state wt-example
      ' _ "$REPO_ROOT"
    )
    [[ "$state" == "$expect" ]] \
      || fail "tmux 상태 분류 오류: stderr='$msg' → '$state' (기대: '$expect')"
  done
}

test_wt_remove_worktree_guarded_rechecks_branch_unit() {
  # 무확인 삭제의 근거는 OID와 브랜치를 함께 묶는다. 그런데 후보 수집과 실제 제거 사이에는
  # tmux probe 같은 외부 호출이 끼어들어 시간이 흐른다. 그 사이 같은 커밋을 가리키는 다른
  # 브랜치로 전환되면 OID만 비교하는 재확인은 통과하고, 조회한 적 없는 브랜치의 worktree를
  # 지운 뒤 수집 시점 브랜치의 ref를 CAS 삭제하게 된다. 제거 직전 재확인이 브랜치 정체성도
  # 보는지 확인한다.
  local sandbox repo wt_path
  sandbox=$(new_sandbox)
  repo="$sandbox/repo"
  wt_path="$sandbox/wt"
  mkdir -p "$repo"

  (
    set -euo pipefail
    # git 격리 환경은 이 subshell 안으로 한정한다 — 함수 스코프에서 export하면 순차 실행
    # 모드에서 뒤따르는 테스트의 git 동작까지 바꾼다.
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    git -C "$repo" init -q
    git -C "$repo" config user.email t@example.invalid
    git -C "$repo" config user.name t
    git -C "$repo" commit -q --allow-empty -m first
    git -C "$repo" worktree add -q "$wt_path" -b feature
    local recorded_oid
    recorded_oid=$(git -C "$wt_path" rev-parse HEAD)

    for helper in ui git-state tmux bootstrap; do
      # shellcheck source=/dev/null
      source "$REPO_ROOT/modules/shared/scripts/lib/wt/$helper.sh"
    done
    # 이 테스트의 대상은 근거 재확인뿐이다. 삭제 경로의 나머지 부수 효과(helper 요구,
    # tmux, plugin 등록)는 stub으로 걷어내 재확인 결과만 관찰한다.
    _wt_require_state_helpers() { :; }
    _wt_has_active_process() { return 1; }
    _wt_tmux_session_state() { printf 'absent\n'; }
    _wt_tmux_close() { :; }
    _wt_tmux_session_close() { :; }
    _wt_remove_claude_local_plugins_for_worktree() { :; }

    # 같은 OID의 다른 브랜치로 전환된 상태 → 제거를 거부해야 한다
    git -C "$wt_path" switch -q -c sibling
    ! _remove_worktree "$wt_path" feature "$repo" guarded "$recorded_oid" >/dev/null 2>&1 || exit 21
    [[ -d "$wt_path" ]] || exit 22
    git -C "$repo" show-ref --verify --quiet refs/heads/feature || exit 23

    # 원래 브랜치로 돌아오면 근거가 다시 성립하므로 제거된다 (가드가 과잉 차단이 아님)
    git -C "$wt_path" switch -q feature
    _remove_worktree "$wt_path" feature "$repo" guarded "$recorded_oid" >/dev/null 2>&1 || exit 24
    [[ ! -d "$wt_path" ]] || exit 25
    ! git -C "$repo" show-ref --verify --quiet refs/heads/feature || exit 26
  ) || fail "_remove_worktree guarded 브랜치 재확인이 기대와 다르게 동작 (exit $?)"
}

test_wt_remove_worktree_guarded_keeps_reused_branch_unit() {
  # guarded는 브랜치를 plumbing(`update-ref -d`)으로 지운다. 그 명령은 porcelain
  # `git branch -D`와 달리 다른 worktree가 사용 중인 브랜치도 지운다. worktree 제거와
  # ref 삭제 사이에 다른 wt 실행이 같은 브랜치를 새 worktree에 체크아웃하면(커밋이 없어
  # OID는 그대로라 CAS도 통과한다) 사용 중인 ref가 사라진다. 그 창을 닫았는지 확인한다.
  local sandbox repo wt_path reused_path
  sandbox=$(new_sandbox)
  repo="$sandbox/repo"
  wt_path="$sandbox/wt"
  reused_path="$sandbox/wt-reused"
  mkdir -p "$repo"

  (
    set -euo pipefail
    # git 격리 환경은 이 subshell 안으로 한정한다 (위 테스트와 같은 이유).
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    git -C "$repo" init -q
    git -C "$repo" config user.email t@example.invalid
    git -C "$repo" config user.name t
    git -C "$repo" commit -q --allow-empty -m first
    git -C "$repo" worktree add -q "$wt_path" -b feature
    local recorded_oid
    recorded_oid=$(git -C "$wt_path" rev-parse HEAD)

    for helper in ui git-state tmux bootstrap; do
      # shellcheck source=/dev/null
      source "$REPO_ROOT/modules/shared/scripts/lib/wt/$helper.sh"
    done
    _wt_require_state_helpers() { :; }
    _wt_has_active_process() { return 1; }
    _wt_tmux_session_state() { printf 'absent\n'; }
    _wt_tmux_close() { :; }
    _wt_tmux_session_close() { :; }
    # 이 helper는 worktree 제거 성공 후 ref 삭제 전에 호출된다 — 경쟁 창을 주입할 지점이다.
    _wt_remove_claude_local_plugins_for_worktree() {
      git -C "$repo" worktree add -q "$reused_path" feature
    }

    _remove_worktree "$wt_path" feature "$repo" guarded "$recorded_oid" >/dev/null 2>&1 || exit 31
    # 재사용된 worktree와 그 ref는 살아 있어야 한다
    git -C "$repo" show-ref --verify --quiet refs/heads/feature || exit 32
    [[ -d "$reused_path" ]] || exit 33
  ) || fail "guarded 삭제가 재사용된 브랜치를 보호하지 못함 (exit $?)"
}

test_wt_remove_worktree_guarded_clears_branch_config_unit() {
  # porcelain `git branch -D`는 ref와 함께 branch.<name> 설정 섹션도 지운다. plumbing
  # 삭제는 ref만 지우므로, 정리한 뒤에도 낡은 upstream·rebase 설정이 남아 같은 이름의
  # 새 브랜치가 그것을 물려받는다. guarded가 그 정리까지 하는지 확인한다.
  local sandbox repo wt_path leftover
  sandbox=$(new_sandbox)
  repo="$sandbox/repo"
  wt_path="$sandbox/wt"
  mkdir -p "$repo"

  (
    set -euo pipefail
    # git 격리 환경은 이 subshell 안으로 한정한다 (위 테스트와 같은 이유).
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    git -C "$repo" init -q
    git -C "$repo" config user.email t@example.invalid
    git -C "$repo" config user.name t
    git -C "$repo" commit -q --allow-empty -m first
    git -C "$repo" worktree add -q "$wt_path" -b feature
    git -C "$repo" config branch.feature.remote origin
    git -C "$repo" config branch.feature.merge refs/heads/feature
    git -C "$repo" config branch.feature.rebase true
    local recorded_oid
    recorded_oid=$(git -C "$wt_path" rev-parse HEAD)

    for helper in ui git-state tmux bootstrap; do
      # shellcheck source=/dev/null
      source "$REPO_ROOT/modules/shared/scripts/lib/wt/$helper.sh"
    done
    _wt_require_state_helpers() { :; }
    _wt_has_active_process() { return 1; }
    _wt_tmux_session_state() { printf 'absent\n'; }
    _wt_tmux_close() { :; }
    _wt_tmux_session_close() { :; }
    _wt_remove_claude_local_plugins_for_worktree() { :; }

    _remove_worktree "$wt_path" feature "$repo" guarded "$recorded_oid" >/dev/null 2>&1 || exit 41
    ! git -C "$repo" show-ref --verify --quiet refs/heads/feature || exit 42
  ) || fail "_remove_worktree guarded 삭제가 실패 (exit $?)"

  # 이 조회도 같은 격리를 쓴다 — global config가 섞이면 잔존 판정이 흔들린다.
  leftover=$(env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -C "$repo" config --get-regexp '^branch\.feature\.' 2>/dev/null || true)
  [[ -z "$leftover" ]] || fail "guarded 삭제 후 branch.feature 설정이 남음: $leftover"
}

test_wt_remove_worktree_forced_refuses_locked_unit() {
  # forced는 `--force` 실패 시 `rm -rf`로 물러나던 경로다. git은 잠긴 worktree의 제거를
  # `--force`로도 거부하므로, 그 fallback은 디렉토리만 지우고 등록은 남겨 "등록만 남은
  # 유령"을 만들었다. 잠금은 tmux pane 기반 활성 판정에 잡히지 않는 독립 신호이므로 삭제
  # 전략보다 먼저 보고 거부해야 하며, 해제된 뒤에는 같은 호출이 정상 동작해야 한다.
  local sandbox repo wt_path
  sandbox=$(new_sandbox)
  repo="$sandbox/repo"
  mkdir -p "$repo"
  # porcelain 경로는 물리 경로다. macOS TMPDIR(/var→/private/var)에서 비정규 경로로
  # 조회하면 등록 블록이 매칭되지 않아 잠금 자체를 못 본다.
  repo="$(cd "$repo" && pwd -P)"
  wt_path="$(cd "$sandbox" && pwd -P)/wt"

  (
    set -euo pipefail
    # git 격리 환경은 이 subshell 안으로 한정한다 (위 단위 테스트들과 같은 이유).
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    git -C "$repo" init -q
    git -C "$repo" config user.email t@example.invalid
    git -C "$repo" config user.name t
    git -C "$repo" commit -q --allow-empty -m first
    git -C "$repo" worktree add -q "$wt_path" -b feature

    for helper in ui git-state tmux bootstrap; do
      # shellcheck source=/dev/null
      source "$REPO_ROOT/modules/shared/scripts/lib/wt/$helper.sh"
    done
    # 관찰 대상은 잠금 가드뿐이다. 나머지 부수 효과는 stub으로 걷어낸다.
    _wt_require_state_helpers() { :; }
    _wt_has_active_process() { return 1; }
    _wt_tmux_session_state() { printf 'absent\n'; }
    _wt_tmux_close() { :; }
    _wt_tmux_session_close() { :; }
    _wt_remove_claude_local_plugins_for_worktree() { :; }

    git -C "$repo" worktree lock --reason "bridge holds it" "$wt_path"

    local output
    output=$(_remove_worktree "$wt_path" feature "$repo" forced 2>&1) && exit 51
    [[ "$output" == *"잠긴 worktree"* ]] || exit 52
    [[ "$output" == *"bridge holds it"* ]] || exit 53
    [[ "$output" == *"git worktree unlock"* ]] || exit 54
    # rm -rf 미발생: 디렉토리·등록·브랜치가 모두 그대로여야 한다
    [[ -d "$wt_path" ]] || exit 55
    git -C "$repo" worktree list --porcelain | grep -qxF "worktree $wt_path" || exit 56
    git -C "$repo" show-ref --verify --quiet refs/heads/feature || exit 57

    # 심링크가 낀 경로로 불려도 잠금을 봐야 한다. 등록 조회는 경로 문자열 일치라
    # (macOS /var→/private/var) 물리 경로로 한 번 더 확인하지 않으면 가드가 조용히 뚫린다.
    ln -s "$(dirname "$wt_path")" "$(dirname "$wt_path")/link"
    output=$(_remove_worktree "$(dirname "$wt_path")/link/wt" feature "$repo" forced 2>&1) && exit 61
    [[ "$output" == *"잠긴 worktree"* ]] || exit 62
    [[ -d "$wt_path" ]] || exit 63

    # 해제되면 같은 호출이 성공한다 (가드가 과잉 차단이 아님)
    git -C "$repo" worktree unlock "$wt_path"
    _remove_worktree "$wt_path" feature "$repo" forced >/dev/null 2>&1 || exit 58
    [[ ! -d "$wt_path" ]] || exit 59
    ! git -C "$repo" worktree list --porcelain | grep -qxF "worktree $wt_path" || exit 60
  ) || fail "_remove_worktree forced가 잠긴 worktree를 기대와 다르게 처리 (exit $?)"
}

test_wt_remove_worktree_forced_keeps_path_when_remove_fails_unit() {
  # `git worktree remove --force` 거부는 잠금 외에도 생긴다(submodule·권한·I/O). 어떤
  # 사유든 디렉토리 삭제로 흉내내면 등록만 남은 유령이 되므로, 거부는 안내와 함께 그대로
  # 실패로 끝나야 한다 — 브랜치 삭제로도 넘어가면 안 된다. 거부 자체는 git 호출을 가로채
  # 재현한다 (사유와 무관하게 fallback이 없는지를 보는 것이 목적).
  local sandbox repo wt_path
  sandbox=$(new_sandbox)
  repo="$sandbox/repo"
  mkdir -p "$repo"
  repo="$(cd "$repo" && pwd -P)"
  wt_path="$(cd "$sandbox" && pwd -P)/wt"

  (
    set -euo pipefail
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    git -C "$repo" init -q
    git -C "$repo" config user.email t@example.invalid
    git -C "$repo" config user.name t
    git -C "$repo" commit -q --allow-empty -m first
    git -C "$repo" worktree add -q "$wt_path" -b feature

    for helper in ui git-state tmux bootstrap; do
      # shellcheck source=/dev/null
      source "$REPO_ROOT/modules/shared/scripts/lib/wt/$helper.sh"
    done
    _wt_require_state_helpers() { :; }
    _wt_has_active_process() { return 1; }
    _wt_tmux_session_state() { printf 'absent\n'; }
    _wt_tmux_close() { :; }
    _wt_tmux_session_close() { :; }
    _wt_remove_claude_local_plugins_for_worktree() { :; }

    # 강제 제거만 거부하고 나머지 git 호출(등록 조회 등)은 그대로 통과시킨다.
    git() {
      if [[ "$*" == *"worktree remove --force"* ]]; then
        printf 'fatal: mock refusal\n' >&2
        return 128
      fi
      command git "$@"
    }

    local output
    output=$(_remove_worktree "$wt_path" feature "$repo" forced 2>&1) && exit 71
    [[ "$output" == *"worktree를 제거할 수 없습니다"* ]] || exit 72
    [[ "$output" == *"git 메시지: fatal: mock refusal"* ]] || exit 73
    [[ -d "$wt_path" ]] || exit 74
    command git -C "$repo" worktree list --porcelain | grep -qxF "worktree $wt_path" || exit 75
    command git -C "$repo" show-ref --verify --quiet refs/heads/feature || exit 76
  ) || fail "_remove_worktree forced가 제거 실패를 rm -rf로 대신하지 않는지 확인 실패 (exit $?)"
}

test_wt_remove_worktree_refuses_unknown_lock_state_unit() {
  # 잠금 조회 자체가 실패하면(등록 목록을 못 읽음) 삭제를 중단한다(fail-closed).
  # 이 분기가 fail-open으로 되돌아가면 잠긴 worktree를 지울 수 있고, 반대로 과잉 차단으로
  # 회귀하면 모든 cleanup이 막힌다 — 어느 쪽도 다른 테스트가 잡지 못한다.
  local sandbox repo wt_path
  sandbox=$(new_sandbox)
  repo="$sandbox/repo"
  mkdir -p "$repo"
  repo="$(cd "$repo" && pwd -P)"
  wt_path="$(cd "$sandbox" && pwd -P)/wt"

  (
    set -euo pipefail
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    git -C "$repo" init -q
    git -C "$repo" config user.email t@example.invalid
    git -C "$repo" config user.name t
    git -C "$repo" commit -q --allow-empty -m first
    git -C "$repo" worktree add -q "$wt_path" -b feature

    for helper in ui git-state tmux bootstrap; do
      # shellcheck source=/dev/null
      source "$REPO_ROOT/modules/shared/scripts/lib/wt/$helper.sh"
    done
    _wt_require_state_helpers() { :; }
    _wt_has_active_process() { return 1; }
    _wt_tmux_session_state() { printf 'absent\n'; }
    _wt_tmux_close() { :; }
    _wt_tmux_session_close() { :; }
    _wt_remove_claude_local_plugins_for_worktree() { :; }

    # 등록 목록 조회만 실패시킨다 — 잠금 상태를 "확인하지 못한" 상태 그 자체.
    git() {
      if [[ "$*" == *"worktree list --porcelain"* ]]; then
        printf 'fatal: mock list failure\n' >&2
        return 128
      fi
      command git "$@"
    }

    local output
    output=$(_remove_worktree "$wt_path" feature "$repo" forced 2>&1) && exit 61
    [[ "$output" == *"잠금 상태를 확인하지 못해 삭제를 중단합니다"* ]] || exit 62
    [[ -d "$wt_path" ]] || exit 63
    command git -C "$repo" worktree list --porcelain | grep -qxF "worktree $wt_path" || exit 64
    command git -C "$repo" show-ref --verify --quiet refs/heads/feature || exit 65
  ) || fail "_remove_worktree가 잠금 상태 unknown을 fail-closed로 다루는지 확인 실패 (exit $?)"
}

test_wt_remove_worktree_failure_notes_registration_state_unit() {
  # 제거 실패 안내는 등록 상태로 갈린다. registered 분기는 기존 테스트가 덮으므로 여기서는
  # 나머지 둘을 태운다 — absent(부분 제거)는 "브랜치는 남겼다 + git worktree add로 복구"라는
  # 복구 절차가 문구 자체로 계약이고, 확인 실패 분기는 상태를 단정하지 않는 것이 계약이다.
  local sandbox repo wt_path marker
  sandbox=$(new_sandbox)
  repo="$sandbox/repo"
  mkdir -p "$repo"
  repo="$(cd "$repo" && pwd -P)"
  wt_path="$(cd "$sandbox" && pwd -P)/wt"
  marker="$(cd "$sandbox" && pwd -P)/remove-attempted"

  (
    set -euo pipefail
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    git -C "$repo" init -q
    git -C "$repo" config user.email t@example.invalid
    git -C "$repo" config user.name t
    git -C "$repo" commit -q --allow-empty -m first
    git -C "$repo" worktree add -q "$wt_path" -b feature

    for helper in ui git-state tmux bootstrap; do
      # shellcheck source=/dev/null
      source "$REPO_ROOT/modules/shared/scripts/lib/wt/$helper.sh"
    done
    _wt_require_state_helpers() { :; }
    _wt_has_active_process() { return 1; }
    _wt_tmux_session_state() { printf 'absent\n'; }
    _wt_tmux_close() { :; }
    _wt_tmux_session_close() { :; }
    _wt_remove_claude_local_plugins_for_worktree() { :; }

    # 제거는 거부하되, 제거를 시도한 뒤의 등록 조회에서는 이 경로가 사라진 것처럼 보이게
    # 한다 = "등록은 풀렸는데 경로 삭제가 끝나지 않은" 부분 제거 상태. 잠금 가드가 보는
    # 제거 이전 조회는 그대로 통과해야 하므로 marker로 시점을 가른다.
    git() {
      if [[ "$*" == *"worktree remove"* ]]; then
        : > "$marker"
        printf 'fatal: mock refusal\n' >&2
        return 128
      fi
      if [[ "$*" == *"worktree list --porcelain"* && -f "$marker" ]]; then
        command git "$@" | grep -vF "worktree $wt_path" || true
        return 0
      fi
      command git "$@"
    }

    local output
    output=$(_remove_worktree "$wt_path" feature "$repo" forced 2>&1) && exit 71
    [[ "$output" == *"부분 제거: wt (등록은 해제됐지만 경로 삭제가 끝나지 않았습니다)"* ]] || exit 72
    [[ "$output" == *"git worktree add"* ]] || exit 73
    [[ -d "$wt_path" ]] || exit 74
    command git -C "$repo" show-ref --verify --quiet refs/heads/feature || exit 75
  ) || fail "_remove_worktree 실패 안내의 absent 분기 확인 실패 (exit $?)"

  rm -f "$marker"

  (
    set -euo pipefail
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

    for helper in ui git-state tmux bootstrap; do
      # shellcheck source=/dev/null
      source "$REPO_ROOT/modules/shared/scripts/lib/wt/$helper.sh"
    done
    _wt_require_state_helpers() { :; }
    _wt_has_active_process() { return 1; }
    _wt_tmux_session_state() { printf 'absent\n'; }
    _wt_tmux_close() { :; }
    _wt_tmux_session_close() { :; }
    _wt_remove_claude_local_plugins_for_worktree() { :; }

    # 같은 시점 구분으로, 이번에는 제거 이후 등록 조회 자체가 실패하게 한다 =
    # "제거도 실패했고 등록 상태도 확인하지 못한" 분기.
    git() {
      if [[ "$*" == *"worktree remove"* ]]; then
        : > "$marker"
        printf 'fatal: mock refusal\n' >&2
        return 128
      fi
      if [[ "$*" == *"worktree list --porcelain"* && -f "$marker" ]]; then
        printf 'fatal: mock list failure\n' >&2
        return 128
      fi
      command git "$@"
    }

    local output
    output=$(_remove_worktree "$wt_path" feature "$repo" forced 2>&1) && exit 81
    [[ "$output" == *"등록 상태도 확인하지 못했습니다"* ]] || exit 82
    [[ "$output" == *"git worktree list --porcelain"* ]] || exit 83
    [[ -d "$wt_path" ]] || exit 84
  ) || fail "_remove_worktree 실패 안내의 등록 상태 확인 실패 분기 확인 실패 (exit $?)"
}

test_wt_head_unchanged_guard_unit() {
  # MERGED 판정은 조회 시점 HEAD를 근거로 하므로, 조회와 삭제 사이에 새 커밋이 생기면
  # 그 판정이 stale해진다. _wt_head_unchanged는 그 창을 닫는 가드이며, 확인 불가한
  # 입력(기록 없음/빈 기록/git 실패)에서는 fail-closed여야 한다.
  local sandbox repo head_file
  sandbox=$(new_sandbox)
  repo="$sandbox/repo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@example.invalid
  git -C "$repo" config user.name t
  git -C "$repo" commit -q --allow-empty -m first
  head_file="$sandbox/recorded.head"

  (
    set -euo pipefail
    source "$REPO_ROOT/modules/shared/scripts/lib/wt/git-state.sh"

    local branch
    branch=$(git -C "$repo" branch --show-current)

    # 기록이 없으면 확인 불가 → fail-closed
    ! _wt_head_unchanged "$repo" "$head_file" || exit 11

    # 기록(<oid> <branch>)이 현재 상태와 같으면 통과
    printf '%s %s\n' "$(git -C "$repo" rev-parse HEAD)" "$branch" > "$head_file"
    _wt_head_unchanged "$repo" "$head_file" || exit 12

    # 기록 이후 새 커밋이 생기면 차단
    git -C "$repo" commit -q --allow-empty -m second
    ! _wt_head_unchanged "$repo" "$head_file" || exit 13

    # OID가 같아도 다른 브랜치로 전환됐으면 차단 — 근거는 브랜치 정체성까지 포함한다
    printf '%s %s\n' "$(git -C "$repo" rev-parse HEAD)" "$branch" > "$head_file"
    git -C "$repo" switch -q -c other-branch
    ! _wt_head_unchanged "$repo" "$head_file" || exit 15
    git -C "$repo" switch -q "$branch"
    _wt_head_unchanged "$repo" "$head_file" || exit 16

    # 빈 기록도 fail-closed
    : > "$head_file"
    ! _wt_head_unchanged "$repo" "$head_file" || exit 14

    # 형식이 어긋난 기록은 브랜치 검사를 건너뛰는 우회로가 되므로 통과시키지 않는다.
    # OID만 있는 기록 (구분자 없음)
    git -C "$repo" rev-parse HEAD > "$head_file"
    ! _wt_head_unchanged "$repo" "$head_file" || exit 17
    # 브랜치가 빈 기록 (구분자는 있으나 값이 없음)
    printf '%s \n' "$(git -C "$repo" rev-parse HEAD)" > "$head_file"
    ! _wt_head_unchanged "$repo" "$head_file" || exit 18
  ) || fail "_wt_head_unchanged 가드가 기대와 다르게 동작 (exit $?)"
}

test_wt_cleanup_auto_reports_current_merged_exclusion() {
  # #1186의 침묵 경로: --auto는 현재 worktree를 제외하면서 아무 말도 하지 않아
  # "자동 정리 완료"만 보였다. 제외 사실과 해결 방법을 알려야 한다.
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

  install_merged_pr_mock "$gh_dir" "$head_oid"

  output=$(
    env -u TMUX \
      HOME="$home_dir" \
      CODEX_HOME="$home_dir/.codex" \
      PATH="$gh_dir:$FIXTURE_DIR/bin:$PATH" \
      WT_NONINTERACTIVE=1 \
      bash -c '
      set -euo pipefail
      cd "'"$target_path"'"
      "'"$home_dir/.local/bin/wt"'" cleanup --auto
    ' 2>&1 || true
  )

  assert_contains "$output" "현재 worktree라 여기서는 삭제할 수 없어 제외했습니다: feature_one (PR MERGED)"
  assert_contains "$output" "저장소 루트에서 실행하세요"
  [[ -d "$target_path" ]] || fail "현재 worktree는 보존돼야 함: $target_path"
}
