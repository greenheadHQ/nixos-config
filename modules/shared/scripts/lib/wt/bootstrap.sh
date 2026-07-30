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
  _wt_prepare_claude_settings "$src_settings" "$dst_claude_dir"

  # .codex/ 디렉토리 복사 (기존 제거 후 복사 — 중첩 방지)
  local src_codex="$git_root/.codex"
  if [[ -L "$src_codex" ]]; then
    _warn "원본 .codex가 symlink라 worktree 복사를 건너뜁니다"
  elif [[ -d "$src_codex" ]]; then
    rm -rf "$wt_path/.codex"
    cp -r "$src_codex" "$wt_path/.codex"
    _wt_sanitize_copied_codex_config "$wt_path/.codex/config.toml" \
      || {
        _warn "worktree .codex/config.toml 정리 실패 — 복사된 config를 제거하고 계속합니다"
        rm -rf -- "$wt_path/.codex/config.toml"
      }
  fi

  # .claude/plans/: tracked README.md(디렉토리 정책 문서, #756/#773)는 보존하고,
  # 새어든 untracked/ignored transient plan buffer만 정리한다. worktree는 git
  # checkout이라 ignored buffer(.claude/plans/*)가 따라오지 않아 평소엔 no-op이지만,
  # 과거 `rm -rf .claude/plans`는 유일하게 checkout되는 tracked README.md까지 지워
  # worktree마다 deleted 부산물 + `git add -A` 시 정책 문서 소실 위험을 만들었다.
  if [ -d "$wt_path/.claude/plans" ]; then
    git -C "$wt_path" clean -fdX -- .claude/plans >/dev/null 2>&1 || true
  fi

  _wt_trust_codex_project "$wt_path"
  _wt_inherit_claude_local_plugins "$wt_path" "$git_root"
}

_wt_prepare_claude_settings() {
  local src_settings="$1"
  local dst_claude_dir="$2"
  local dst_settings="$dst_claude_dir/settings.local.json"

  if [[ -L "$dst_claude_dir" || ( -e "$dst_claude_dir" && ! -d "$dst_claude_dir" ) ]]; then
    _die "worktree .claude가 regular directory가 아니라 bootstrap 중단"
  fi

  if [[ -L "$src_settings" ]]; then
    _warn "원본 .claude/settings.local.json이 symlink라 worktree 복사를 건너뜁니다"
    [[ -e "$dst_settings" || -L "$dst_settings" ]] && _wt_remove_claude_settings_file "$dst_settings"
  elif [[ -f "$src_settings" ]]; then
    mkdir -p "$dst_claude_dir"
    _wt_remove_claude_settings_file "$dst_settings"
    cp "$src_settings" "$dst_settings"
  elif [[ -e "$dst_settings" || -L "$dst_settings" ]]; then
    _wt_remove_claude_settings_file "$dst_settings"
  fi
}

_wt_remove_claude_settings_file() {
  local settings_file="$1"
  if [[ -d "$settings_file" && ! -L "$settings_file" ]]; then
    _die "worktree .claude/settings.local.json이 directory라 bootstrap 중단"
  fi
  rm -f "$settings_file" || _die "worktree .claude/settings.local.json 제거 실패"
}

_wt_sanitize_copied_codex_config() {
  local config_file="$1"
  local helper

  helper=$(_wt_codex_trust_helper) \
    || _die "Codex trust helper를 찾지 못해 copied Codex config 정리 불가"

  local python_bin="${WT_PYTHON:-python3}"
  "$python_bin" "$helper" sanitize-copied-codex-config "$config_file"
}

_wt_codex_trust_helper() {
  local helper="${WT_LIB_DIR:-}/codex-trust.py"
  [[ -f "$helper" ]] || return 1
  printf '%s\n' "$helper"
}

_wt_codex_config() {
  printf '%s\n' "${CODEX_HOME:-$HOME/.codex}/config.toml"
}

_wt_trust_codex_project() {
  local wt_path="$1"
  local helper

  helper=$(_wt_codex_trust_helper) \
    || _die "Codex trust helper를 찾지 못해 project trust 등록 불가"

  local python_bin="${WT_PYTHON:-python3}"
  "$python_bin" "$helper" trust-project \
    --config "$(_wt_codex_config)" \
    "$wt_path" \
    || _warn "Codex project trust 등록 실패 — Codex에서 worktree 신뢰를 다시 물을 수 있습니다"
}

_wt_plugin_manifest_helper() {
  local helper="${WT_LIB_DIR:-}/plugin-manifest.py"
  [[ -f "$helper" ]] || return 1
  printf '%s\n' "$helper"
}

_wt_require_state_helpers() {
  _wt_codex_trust_helper >/dev/null \
    || _die "Codex trust helper를 찾지 못해 wt 상태 변경 불가"
  _wt_plugin_manifest_helper >/dev/null \
    || _die "Claude plugin manifest helper를 찾지 못해 wt 상태 변경 불가"
}

_wt_claude_plugin_manifest() {
  printf '%s\n' "$HOME/.claude/plugins/installed_plugins.json"
}

_wt_inherit_claude_local_plugins() {
  local wt_path="$1"
  local git_root="$2"
  local helper

  helper=$(_wt_plugin_manifest_helper) \
    || _die "Claude plugin manifest helper를 찾지 못해 local plugin inheritance 불가"

  local python_bin="${WT_PYTHON:-python3}"
  "$python_bin" "$helper" inherit-local \
    --settings "$git_root/.claude/settings.local.json" \
    --manifest "$(_wt_claude_plugin_manifest)" \
    --source-root "$git_root" \
    --target-root "$wt_path" \
    || _warn "Claude local plugin inheritance 실패 — manifest를 변경하지 않았습니다"
}

_wt_remove_claude_local_plugins_for_worktree() {
  local wt_path="$1"
  local canonical_wt_path="${2:-$wt_path}"
  local helper

  helper=$(_wt_plugin_manifest_helper) \
    || _die "Claude plugin manifest helper를 찾지 못해 local plugin cleanup 불가"

  local python_bin="${WT_PYTHON:-python3}"
  "$python_bin" "$helper" remove-local \
    --manifest "$(_wt_claude_plugin_manifest)" \
    --target-root "$wt_path" \
    --target-root-before-removal "$canonical_wt_path" \
    || {
      _warn "Claude local plugin cleanup 실패 — manifest를 변경하지 않았습니다"
      return 1
    }
}


# ── worktree 열기 (tmux 또는 stdout) ─────────────────────────────────────────

_open_worktree() {
  local wt_path="$1" window_name="$2" stay="$3" run_claude="$4" use_tmux_session="${5:-false}"

  # --tmux: tmux 밖 + 대화형에서만 세션 모드 (tmux 안이면 윈도우 모드 fallback — 의도적 정책)
  # 비대화형(LLM/스크립트)은 exec tmux attach 불가 → 무시하고 경로 stdout으로 fallback
  if [[ "$use_tmux_session" == "true" ]] && [[ -z "${TMUX:-}" ]]; then
    if _wt_interactive; then
      local session_name
      session_name=$(_wt_session_name "$window_name")
      _wt_tmux_session_open "$wt_path" "$session_name" "$stay" "$run_claude"
      return
    fi
    _warn "비대화형: --tmux 무시 (경로 출력으로 fallback)"
  fi

  # tmux 윈도우 생성/전환은 대화형 한정 (정책: _wt_tmux_ui_allowed) — 비대화형
  # create/reuse는 tmux 화면을 건드리지 않고 아래 else의 경로 stdout 출력을 따른다.
  if _wt_tmux_ui_allowed; then
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
          "claude --dangerously-skip-permissions" Enter
      else
        _info "기존 윈도우 — --claude 스킵 (실행 중인 프로세스 보호)"
      fi
    fi
  else
    # tmux 밖 또는 비대화형: 경로 stdout 출력 (래퍼가 cd)
    if [[ "$run_claude" == "true" ]]; then
      if [[ -n "${TMUX:-}" ]]; then
        _info "경고: --claude는 비대화형에서 정책상 무시됩니다 (tmux UI 비활성)"
      else
        _info "경고: --claude는 tmux 세션 안에서만 동작합니다"
      fi
    fi
    if [[ "$stay" == "true" ]] && _wt_interactive; then
      # --stay (대화형): 현재 디렉토리 유지, 경로만 안내 — stdout에 내면 래퍼가 cd해버린다
      _info "worktree 경로: $wt_path"
    else
      # 비대화형은 --stay여도 stdout 경로 출력 계약을 지킨다 (래퍼는 self-gate로 우회됨)
      echo "$wt_path"
    fi
  fi
}

# ── worktree 제거 (tmux 윈도우 포함) ─────────────────────────────────────────

# 인자: wt_path, branch, git_root, [mode], [expected_oid]
#
# mode는 "이 삭제를 사용자가 승인했는가"를 나타내며, 삭제 정책을 결정한다:
#   forced  (기본) — 사용자가 dirty/미push를 확인하고 승인했거나 기존 동작 경로.
#                    강제 제거와 `branch -D`를 그대로 쓴다. 잃을 것을 알고 요청한 삭제다.
#   guarded        — 사용자 확인을 건너뛴 삭제(MERGED 판정 기반). expected_oid가 필수이며
#                    비강제 제거 + ref CAS만 사용해, 승인 없이는 아무것도 잃지 않는다.
#
# guarded에서 강제 옵션을 쓰지 않는 이유: 호출자의 dirty 판정은 후보 수집 시점 값이라
# 그 뒤 생긴 변경을 모른다. 비강제 remove는 정리되지 않은 변경이나 잠금이 있으면 git이
# 거부하므로 그 거부를 그대로 존중한다. 브랜치 삭제도 `update-ref -d <ref> <oid>`로
# expected_oid일 때만 지워, 창 안에서 커밋이 생기면 ref가 남는다 — worktree 디렉토리가
# 사라져도 `git worktree add`로 되살릴 수 있다.
_remove_worktree() {
  local wt_path="$1" branch="$2" git_root="$3" mode="$4" expected_oid="${5:-}"
  local name
  name=$(basename "$wt_path")

  # mode는 폐쇄 집합이다. 미지정이나 오타를 기본값으로 흘리면 가장 파괴적인 정책이
  # 조용히 선택되므로, 알 수 없는 값은 여기서 거부한다.
  case "$mode" in
    forced|guarded) ;;
    *) _warn "스킵: $name (알 수 없는 삭제 모드: ${mode:-<없음>})"; return 1 ;;
  esac

  if [[ "$mode" == "guarded" && -z "$expected_oid" ]]; then
    _warn "스킵: $name (무확인 삭제인데 근거 OID가 없습니다)"
    return 1
  fi

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

  _wt_require_state_helpers

  # canonical path는 제거 전에 확보한다 — 제거 후에는 디렉토리가 없어 구할 수 없다.
  local canonical_wt_path session_name
  canonical_wt_path="$(cd "$wt_path" && pwd -P)" || canonical_wt_path="$wt_path"
  session_name=$(_wt_session_name "$name")

  if [[ "$mode" == "guarded" ]]; then
    # 무확인 삭제에서는 worktree 제거 성공을 mutation 경계로 삼는다. tmux 창 종료와
    # plugin 등록 해제는 되돌릴 수 없어서, 그것들을 먼저 하고 나서 제거가 거부되면
    # worktree는 남고 작업 문맥만 사라진 부분 정리가 된다. 제거를 앞에 두면 거부될 때
    # 아무것도 건드리지 않은 상태로 끝난다 — lock·submodule처럼 미리 예측하기 어려운
    # 거부 사유도 이 경계에서 함께 걸린다.
    local now_head
    if ! now_head=$(git -C "$wt_path" rev-parse HEAD 2>/dev/null); then
      _warn "스킵: $name (HEAD를 읽지 못해 삭제 근거를 재확인할 수 없습니다)"
      return 1
    fi
    if [[ "$now_head" != "$expected_oid" ]]; then
      _warn "스킵: $name (삭제 판정 이후 HEAD가 바뀌었습니다 — 다시 실행해 확인하세요)"
      return 1
    fi

    if ! git -C "$git_root" worktree remove "$wt_path" 2>/dev/null; then
      _warn "스킵: $name (worktree를 제거할 수 없습니다 — 정리되지 않은 변경, 잠금, submodule 등)"
      _warn "  확인하고 강제로 지우려면: wt cleanup $(printf '%q' "$name") --yes"
      return 1
    fi

    # 제거에 성공했으므로 이제 부수 상태를 정리한다. 여기서 실패해도 worktree는 이미
    # 사라졌으니 중단하지 않고 알리기만 한다.
    _wt_tmux_close "$wt_path" || true
    _wt_tmux_session_close "$session_name" || _info "참고: $name — 연결된 tmux 세션이 남아 있습니다"
    _wt_remove_claude_local_plugins_for_worktree "$wt_path" "$canonical_wt_path" \
      || _warn "참고: $name — Claude local plugin 등록을 정리하지 못했습니다"
  else
    # 승인된 삭제는 기존 순서를 유지한다 — 강제 제거라 거부되지 않으므로 부수 정리를
    # 먼저 해도 부분 정리로 끝나지 않는다.
    _wt_tmux_close "$wt_path" || true
    _wt_tmux_session_close "$session_name" || {
      _info "스킵: $name — 연결된 tmux 세션이 있어 삭제하지 않습니다"
      return 1
    }
    _wt_remove_claude_local_plugins_for_worktree "$wt_path" "$canonical_wt_path" || return 1
    git -C "$git_root" worktree remove --force "$wt_path" 2>/dev/null || rm -rf "$wt_path"
  fi

  # 브랜치 삭제 (detached가 아닌 경우)
  if [[ "$branch" != "detached" ]]; then
    if [[ "$mode" == "guarded" ]]; then
      if ! git -C "$git_root" update-ref -d "refs/heads/$branch" "$expected_oid" 2>/dev/null; then
        local _safe_path _safe_branch
        printf -v _safe_path '%q' "$wt_path"
        printf -v _safe_branch '%q' "$branch"
        _warn "브랜치 유지: $branch (삭제 판정 이후 새 커밋이 생겨 ref를 지우지 않았습니다)"
        _warn "  복구: git worktree add ${_safe_path} ${_safe_branch}"
        _info "삭제: $name (worktree만)"
        "$HOME/.local/bin/nrs-relink" fix-dangling >/dev/null 2>&1 || true
        return 0
      fi
    else
      git -C "$git_root" branch -D "$branch" 2>/dev/null || true
    fi
  fi

  _info "삭제: $name ($branch)"

  # worktree 삭제 후 dangling 심링크 자동 복원 (#294)
  "$HOME/.local/bin/nrs-relink" fix-dangling >/dev/null 2>&1 || \
      _info "⚠️  심링크 복원 실패 (치명적이지 않음, 수동 nrs 필요)"
}
