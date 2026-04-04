# shellcheck shell=bash
# ── Bootstrap ────────────────────────────────────────────────────────────────

_bootstrap_worktree() {
  local wt_path="$1"
  local git_root="$2"

  # 중첩 회귀 가드
  if [[ -d "$wt_path/.claude/.claude" ]] || [[ -d "$wt_path/.codex/.codex" ]]; then
    _die "중첩 .claude/.claude 또는 .codex/.codex 감지 — bootstrap 중단"
  fi

  # .claude/settings.local.json 복사 (파일 단위)
  local src_settings="$git_root/.claude/settings.local.json"
  local dst_claude_dir="$wt_path/.claude"
  if [[ -f "$src_settings" ]]; then
    mkdir -p "$dst_claude_dir"
    cp "$src_settings" "$dst_claude_dir/settings.local.json"
  fi

  # .codex/ 디렉토리 복사 (기존 제거 후 복사 — 중첩 방지)
  local src_codex="$git_root/.codex"
  if [[ -d "$src_codex" ]]; then
    rm -rf "$wt_path/.codex"
    cp -r "$src_codex" "$wt_path/.codex"
  fi

  # .claude/plans/ 제거 (worktree에서는 불필요)
  rm -rf "$wt_path/.claude/plans"

  # Claude → Codex projection 재실행 (plugin-aware worktree bootstrap 복구)
  local script_dir codex_sync_sh=""
  script_dir="${WT_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
  local repo_local_sync_sh="$script_dir/codex-sync.sh"
  local deployed_sync_bin="$script_dir/codex-sync"

  if [[ -x "$deployed_sync_bin" ]]; then
    codex_sync_sh="$deployed_sync_bin"
  elif [[ -f "$repo_local_sync_sh" ]]; then
    codex_sync_sh="$repo_local_sync_sh"
  else
    codex_sync_sh="$(command -v codex-sync 2>/dev/null || true)"
  fi

  if [[ -n "$codex_sync_sh" ]]; then
    if [[ "$codex_sync_sh" == "$repo_local_sync_sh" ]]; then
      bash "$codex_sync_sh" "$wt_path" || _warn "codex-sync 실패 — 수동으로 'codex-sync $wt_path'를 실행하세요"
    elif ! "$codex_sync_sh" "$wt_path"; then
      _warn "codex-sync 실패 — 수동으로 'codex-sync $wt_path'를 실행하세요"
    fi
  else
    _warn "codex-sync 스크립트를 찾지 못해 Codex projection을 건너뜁니다"
  fi
}

# ── worktree 열기 (tmux 또는 stdout) ─────────────────────────────────────────

_open_worktree() {
  local wt_path="$1" window_name="$2" stay="$3" run_claude="$4" use_tmux_session="${5:-false}"

  # --tmux: tmux 밖에서만 세션 모드 활성화 (tmux 안이면 윈도우 모드로 fallback — 의도적 정책)
  if [[ "$use_tmux_session" == "true" ]] && [[ -z "${TMUX:-}" ]]; then
    local session_name
    session_name=$(_wt_session_name "$window_name")
    _wt_tmux_session_open "$wt_path" "$session_name" "$stay" "$run_claude"
    return
  fi

  if [[ -n "${TMUX:-}" ]]; then
    local window_id open_rc=0
    window_id=$(_wt_tmux_open "$wt_path" "$window_name" "$stay") || open_rc=$?

    # tmux 연결 실패 (stale TMUX 환경변수 등) → fallback: 경로 stdout 출력
    if (( open_rc == 1 )); then
      _info "경고: tmux 윈도우 생성 실패 — 경로로 fallback합니다"
      [[ "$run_claude" == "true" ]] && _info "경고: --claude는 tmux 윈도우가 필요합니다"
      echo "$wt_path"
      return
    fi

    # --claude: 새 윈도우에서만 claude 실행 (open_rc == 0)
    # 기존 윈도우(open_rc == 2)에는 send-keys 하지 않음 — 실행 중인 프로세스에 주입 방지
    # send-keys로 큐잉 — 셸 초기화 완료 후 버퍼에서 읽어 실행 (레이스 안전)
    if [[ "$run_claude" == "true" ]] && [[ -n "${window_id:-}" ]]; then
      if (( open_rc == 0 )); then
        tmux send-keys -t "$window_id" \
          "claude --dangerously-skip-permissions --mcp-config ~/.claude/mcp.json" Enter
      else
        _info "기존 윈도우 — --claude 스킵 (실행 중인 프로세스 보호)"
      fi
    fi
  else
    # tmux 밖: 경로 stdout 출력 (래퍼가 cd)
    [[ "$run_claude" == "true" ]] && _info "경고: --claude는 tmux 세션 안에서만 동작합니다"
    if [[ "$stay" == "true" ]]; then
      # --stay: 현재 디렉토리 유지, 경로만 안내
      _info "worktree 경로: $wt_path"
    else
      echo "$wt_path"
    fi
  fi
}

# ── worktree 제거 (tmux 윈도우 포함) ─────────────────────────────────────────

_remove_worktree() {
  local wt_path="$1" branch="$2" git_root="$3"
  local name
  name=$(basename "$wt_path")

  # cwd 가드: 현재 셸이 삭제 대상 worktree 안에 있으면 중단
  local current_dir
  current_dir=$(pwd -P)
  if [[ "$current_dir" == "$wt_path" || "$current_dir" == "$wt_path/"* ]]; then
    _info "스킵: $name — 현재 작업 디렉토리가 이 worktree 안에 있습니다"
    return 1
  fi

  # 활성 프로세스 가드: tmux 윈도우에 실행 중인 프로세스(nvim, claude 등)가 있으면 중단
  if _wt_has_active_process "$wt_path"; then
    return 1
  fi

  # tmux 윈도우 닫기 (실패해도 worktree는 삭제)
  _wt_tmux_close "$wt_path" || true

  # tmux 세션 정리 (wt- 접두사 세션, 연결된 클라이언트 있으면 삭제 중단)
  local session_name
  session_name=$(_wt_session_name "$name")
  _wt_tmux_session_close "$session_name" || {
    _info "스킵: $name — 연결된 tmux 세션이 있어 삭제하지 않습니다"
    return 1
  }

  # worktree 제거
  git -C "$git_root" worktree remove --force "$wt_path" 2>/dev/null || rm -rf "$wt_path"

  # 브랜치 삭제 (detached가 아닌 경우)
  if [[ "$branch" != "detached" ]]; then
    git -C "$git_root" branch -D "$branch" 2>/dev/null || true
  fi

  _info "삭제: $name ($branch)"

  # worktree 삭제 후 dangling 심링크 자동 복원 (#294)
  "$HOME/.local/bin/nrs-relink" fix-dangling >/dev/null 2>&1 || \
      _info "⚠️  심링크 복원 실패 (치명적이지 않음, 수동 nrs 필요)"
}
