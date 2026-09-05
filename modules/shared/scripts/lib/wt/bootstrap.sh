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

# worktree 제거 성공 직후의 Codex trust 해제. wt는 생성 시 worktree 경로를
# `~/.codex/config.toml`의 `[projects."<경로>"]`에 등록하는데, 제거 때 지우지 않으면
# 사라진 경로의 trust 항목이 계속 쌓인다.
#
# 넘기는 경로는 반드시 제거 전에 확보한 canonical 경로다 — 등록 키가 trust 시점의
# resolve 결과이고, 디렉토리가 사라진 뒤에는 그 값을 다시 만들 수 없다.
#
# 실패해도 중단하지 않는다: 호출 시점에 worktree는 이미 사라졌고, 남는 부작용은
# config의 stale 항목 하나뿐이라 되돌릴 것이 없다.
_wt_untrust_codex_project() {
  local canonical_wt_path="$1"
  local helper

  # 존재 보장은 제거 전 _wt_require_state_helpers가 이미 했다. 그래도 여기서 _die하지
  # 않는 이유는 위와 같다 (제거 뒤라 중단이 아무것도 되돌리지 못한다).
  helper=$(_wt_codex_trust_helper) || {
    _warn "Codex trust helper를 찾지 못해 project trust 해제를 건너뜁니다"
    return 0
  }

  local python_bin="${WT_PYTHON:-python3}"
  "$python_bin" "$helper" untrust-project \
    --config "$(_wt_codex_config)" \
    "$canonical_wt_path" \
    || _warn "Codex project trust 해제 실패 — $(_wt_codex_config)에 stale 항목이 남습니다 (일괄 정리 절차: cheat wt의 'Codex trust 정리')"
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


# ── worktree 경로 반환 ───────────────────────────────────────────────────────

# create/reuse/recreate의 종착점. 대화형·비대화형 구분 없이 경로 한 줄을 stdout에 낸다.
# 예전에는 여기서 tmux 윈도우/세션을 만들고 Claude까지 띄웠지만, 그 UI 상태가 CLI 플래그와
# 핸들러 시그니처를 관통해 worktree 관리와 무관한 결합을 만들었다. 이동은 셸 래퍼(또는
# `cd "$(wt ...)"`)의 몫으로 남기고, 여기는 계약 한 줄만 지킨다.
_wt_emit_worktree_path() {
  printf '%s\n' "$1"
}

# ── worktree 제거 (tmux 윈도우 포함) ─────────────────────────────────────────

# 비강제 `git worktree remove`가 실패한 뒤 이 경로가 아직 worktree로 등록돼 있는가.
# git은 사전 검사(정리되지 않은 변경·잠금·submodule)에서 거부하면 아무것도 건드리지
# 않지만, 검사를 통과한 뒤 디렉토리 삭제가 실패하면(권한·I/O) 관리 디렉토리 등록 해제는
# 그대로 진행하고 실패를 알린다. 그래서 "실패했으니 무변경"이 성립하지 않는다.
# stdout: registered | absent | unknown (tmux 상태 probe와 같은 삼상태 계약)
_wt_worktree_registration_state() {
  local git_root="$1" wt_path="$2" canonical_wt_path="$3"
  local list
  list=$(git -C "$git_root" worktree list --porcelain 2>/dev/null) || { printf 'unknown\n'; return 0; }
  if printf '%s\n' "$list" | grep -qxF -e "worktree $wt_path" -e "worktree $canonical_wt_path"; then
    printf 'registered\n'
  else
    printf 'absent\n'
  fi
}

# 잠금 때문에 파괴적 작업을 중단했을 때의 안내. 제거(bootstrap)와 재생성(create)이 같은
# 문구·같은 해제 명령을 쓰도록 한곳에 둔다. label에는 호출 문맥("스킵: x", "재생성 불가: x")을
# 넘긴다 — 잠금 사유와 unlock 명령은 여기서 붙인다.
_wt_warn_locked() {
  local label="$1" git_root="$2" probe_path="$3"
  local reason
  reason=$(_wt_lock_reason "$git_root" "$probe_path")
  if [[ -n "$reason" ]]; then
    _warn "$label (잠긴 worktree — 사유: $reason)"
  else
    _warn "$label (잠긴 worktree)"
  fi
  _warn "  잠근 주체를 확인하고 해제한 뒤 다시 실행하세요: git worktree unlock $(printf '%q' "$probe_path")"
}

# `git worktree remove` 실패 뒤의 안내. guarded(비강제)와 forced(강제)가 같은 분류·같은
# 문구를 쓰도록 한곳에 둔다 — 경로별로 복제하면 등록 상태별 안내가 갈라진다.
# retry_hint만 호출자가 넘긴다: guarded는 "--yes로 강제"를 안내할 수 있지만, forced는
# 이미 `--force`로 시도한 뒤라 그 안내가 성립하지 않는다 (빈 문자열이면 생략).
_wt_warn_remove_failure() {
  local name="$1" branch="$2" git_root="$3" wt_path="$4" canonical_wt_path="$5"
  local remove_err="$6" retry_hint="${7:-}"
  local _safe_wt_path _safe_wt_branch
  printf -v _safe_wt_path '%q' "$wt_path"
  printf -v _safe_wt_branch '%q' "$branch"

  # 실패를 무변경으로 단정하지 않는다 (위 _wt_worktree_registration_state 주석 참조).
  case "$(_wt_worktree_registration_state "$git_root" "$wt_path" "$canonical_wt_path")" in
    registered)
      _warn "스킵: $name (worktree를 제거할 수 없습니다 — 정리되지 않은 변경, 잠금, submodule 등)"
      [[ -n "$retry_hint" ]] && _warn "  $retry_hint"
      ;;
    absent)
      _warn "부분 제거: $name (등록은 해제됐지만 경로 삭제가 끝나지 않았습니다)"
      _warn "  남은 경로를 직접 확인하고 지우세요: ${_safe_wt_path}"
      _warn "  브랜치 $branch 는 지우지 않았습니다 — 복구: git worktree add ${_safe_wt_path} ${_safe_wt_branch}"
      ;;
    *)
      _warn "스킵: $name (worktree 제거가 실패했고 등록 상태도 확인하지 못했습니다)"
      _warn "  경로와 등록을 함께 확인하세요: git worktree list --porcelain"
      _warn "  브랜치 $branch 는 지우지 않았습니다"
      ;;
  esac

  # git이 남긴 사유는 분류만으로는 알 수 없다(잠금인지 submodule인지 권한인지). 여러 줄로
  # 오면 한 줄로 접어 안내 블록의 모양을 유지한다.
  if [[ -n "$remove_err" ]]; then
    _warn "  git 메시지: $(printf '%s' "$remove_err" | tr '\n' ' ')"
  fi
  return 0
}

# 이 브랜치를 체크아웃하고 있는 worktree가 남아 있는가.
# guarded의 ref 삭제는 plumbing(`update-ref -d`)이라 porcelain `git branch -D`가 하던
# "다른 worktree가 사용 중이면 거부" 검사를 받지 못한다 — 이 환경 git 2.54 실측으로
# 사용 중인 브랜치도 exit 0으로 지운다. 그 검사를 여기서 되살린다.
# stdout: in-use | free | unknown (확인 실패는 free로 흘리지 않는다)
_wt_branch_checkout_state() {
  local git_root="$1" branch="$2"
  local list
  list=$(git -C "$git_root" worktree list --porcelain 2>/dev/null) || { printf 'unknown\n'; return 0; }
  if printf '%s\n' "$list" | grep -qxF "branch refs/heads/$branch"; then
    printf 'in-use\n'
  else
    printf 'free\n'
  fi
}

# 호출 형태 (mode는 필수, 폐쇄 집합):
#   _remove_worktree <wt_path> <branch> <git_root> forced
#   _remove_worktree <wt_path> <branch> <git_root> guarded <expected_oid>
#
# mode는 제거 전략을 고른다. "승인 여부"를 직접 뜻하지 않는다 — 어떤 전략을 쓸지는
# 호출자가 정책으로 판단하며, 이 함수는 그 결정을 실행만 한다:
#   forced   — 강제 제거(`--force`)와 `branch -D`. 되돌릴 수 없다.
#              호출자가 쓰는 경우: 확인 프롬프트 통과, `--yes`, 그리고 clean한
#              비-MERGED를 이름으로 지정한 기존 경로.
#              `--force`가 거부되면 그대로 실패한다. 과거엔 `rm -rf` fallback이 있었으나,
#              git이 거부한 대상(대표적으로 잠긴 worktree)을 디렉토리만 지워 흉내내면
#              등록만 남은 유령 worktree가 된다 — 강제는 "사전 검사를 뚫는다"는 뜻이
#              아니라 "정리되지 않은 변경을 감수한다"는 뜻이다.
#   guarded  — 비강제 제거 + ref CAS. expected_oid가 필수다.
#              호출자가 쓰는 경우: 위험을 알릴 기회가 없던 MERGED 무확인 삭제.
#              거부 시점별 상태가 다르다 — 비강제 remove가 사전 검사에서 거부되면
#              아무것도 건드리지 않고 끝나고(mutation 경계), 검사를 통과한 뒤 삭제가
#              실패하면 등록만 해제된 부분 제거로 끝날 수 있다(등록 상태를 보고 안내를
#              가른다). 그 뒤 ref CAS가 거부되면 worktree는 이미 제거된 상태에서
#              브랜치만 남는다(복구 명령을 안내한다).
#
# guarded에서 강제 옵션을 쓰지 않는 이유: 호출자의 dirty 판정은 후보 수집 시점 값이라
# 그 뒤 생긴 변경을 모른다. 비강제 remove는 정리되지 않은 변경이나 잠금이 있으면 git이
# 거부하므로 그 거부를 그대로 존중한다. 브랜치 삭제도 `update-ref -d <ref> <oid>`로
# expected_oid일 때만 지워, 창 안에서 커밋이 생기면 ref가 남는다 — worktree 디렉토리가
# 사라져도 `git worktree add`로 되살릴 수 있다.
_remove_worktree() {
  local wt_path="$1" branch="$2" git_root="$3" mode="${4:-}" expected_oid="${5:-}"
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

  # 잠금 가드 (mode와 무관): git lock은 "다른 주체가 이 worktree를 붙잡고 있다"는 신호를
  # tmux pane과 독립적으로 낸다. 활성 판정을 pane 유무(_wt_has_active_process)에만 맡기면
  # pane 없이 살아 있는 주체(예: worktree를 잠근 브리지 프로세스)를 활성으로 보지 못한다.
  # 그래서 잠금을 독립 신호로 승격해 삭제 전략(forced/guarded)보다 먼저 본다 — 해제는
  # 잠근 주체가 `git worktree unlock`으로 해야 하며, `--yes`는 그 권한을 대신하지 않는다.
  # 확인하지 못한 상태(unknown)도 지우지 않는다: 되돌릴 수 없는 작업에서 "잠기지 않았다"를
  # 확인 없이 가정하지 않는다(fail-closed, tmux 세션 probe와 같은 정책).
  #
  # 심링크가 낀 경로 대응은 조회 헬퍼(_wt_effective_lock_state)가 소유한다 — create.sh의
  # 재생성 경로도 같은 헬퍼를 써야 두 파괴적 경로의 잠금 판정이 갈라지지 않는다.
  local lock_state lock_probe_path
  read -r lock_state lock_probe_path <<< "$(_wt_effective_lock_state "$git_root" "$wt_path")"
  case "$lock_state" in
    unlocked) ;;
    locked)
      _wt_warn_locked "스킵: $name" "$git_root" "$lock_probe_path"
      return 1
      ;;
    *)
      _warn "스킵: $name (잠금 상태를 확인하지 못해 삭제를 중단합니다)"
      return 1
      ;;
  esac

  _wt_require_state_helpers

  # canonical path는 제거 전에 확보한다 — 제거 후에는 디렉토리가 없어 구할 수 없다.
  local canonical_wt_path session_name
  canonical_wt_path="$(cd "$wt_path" && pwd -P)" || canonical_wt_path="$wt_path"
  session_name=$(_wt_session_name "$name")

  # ref 유지 안내에 쓰는 shell-quoted 사본. 제거 실패 쪽 안내는 _wt_warn_remove_failure가
  # 같은 규칙으로 따로 만든다 (두 경로가 그 함수를 공유하므로 인용 규칙은 한 벌로 유지된다).
  local _safe_wt_path _safe_wt_branch
  printf -v _safe_wt_path '%q' "$wt_path"
  printf -v _safe_wt_branch '%q' "$branch"

  if [[ "$mode" == "guarded" ]]; then
    # 무확인 삭제에서는 worktree 제거 성공을 mutation 경계로 삼는다. tmux 창 종료와
    # plugin 등록 해제는 되돌릴 수 없어서, 그것들을 먼저 하고 나서 제거가 거부되면
    # worktree는 남고 작업 문맥만 사라진 부분 정리가 된다. 제거를 앞에 두면 거부가
    # 대부분 사전 검사에서 나므로 아무것도 건드리지 않은 채 끝난다 — lock·submodule처럼
    # 미리 예측하기 어려운 거부 사유도 이 검사에 함께 걸린다.
    #
    # 무확인 삭제에서는 대상 tmux 세션이 존재하는 것만으로 물러난다. 클라이언트 유무를
    # 확인해도 그 직후 attach할 수 있고, 세션 종료는 제거 뒤라(부분 정리 방지) 그 사이를
    # 막을 수단이 없다. idle shell은 활성 프로세스 가드에도 걸리지 않으므로, 위험을
    # 알릴 기회가 없던 삭제에서는 세션 자체를 스킵 조건으로 삼는 편이 안전하다.
    #
    # "세션 없음"과 "상태를 못 읽음"의 구분은 tmux.sh의 삼상태 probe가 소유한다.
    case "$(_wt_tmux_session_state "$session_name")" in
      present)
        _info "스킵: $name — tmux 세션이 남아 있습니다 (세션 종료 후 다시 실행하거나 --yes)"
        return 1
        ;;
      unknown)
        _warn "스킵: $name (tmux 상태를 확인하지 못해 무확인 삭제를 중단합니다)"
        return 1
        ;;
    esac

    # 근거 재확인은 제거 직전에 둔다. tmux probe 같은 외부 호출은 시간이 걸리고, 그 사이
    # HEAD나 체크아웃 브랜치가 바뀌면 확인한 적 없는 대상을 지우게 된다. 브랜치까지 보는
    # 이유는 _wt_head_unchanged와 같다 — 같은 커밋을 가리키는 다른 브랜치로 전환되면 OID
    # 비교만으로는 통과하고, 그 worktree를 지운 뒤 수집 시점 브랜치의 ref를 CAS 삭제한다.
    local now_head now_branch
    if ! now_head=$(git -C "$wt_path" rev-parse HEAD 2>/dev/null); then
      _warn "스킵: $name (HEAD를 읽지 못해 삭제 근거를 재확인할 수 없습니다)"
      return 1
    fi
    if [[ "$now_head" != "$expected_oid" ]]; then
      _warn "스킵: $name (삭제 판정 이후 HEAD가 바뀌었습니다 — 다시 실행해 확인하세요)"
      return 1
    fi
    now_branch=$(_wt_branch "$wt_path")
    if [[ "$now_branch" != "$branch" ]]; then
      _warn "스킵: $name (삭제 판정 이후 체크아웃 브랜치가 바뀌었습니다 — 다시 실행해 확인하세요)"
      return 1
    fi

    # stderr를 버리지 않고 캡처한다 — 등록 상태 분류만으로는 거부 사유(잠금·submodule·
    # 권한)를 알 수 없어 안내에 함께 싣는다.
    local remove_err remove_rc=0
    remove_err=$(git -C "$git_root" worktree remove "$wt_path" 2>&1 >/dev/null) || remove_rc=$?
    if (( remove_rc != 0 )); then
      _wt_warn_remove_failure "$name" "$branch" "$git_root" "$wt_path" "$canonical_wt_path" \
        "$remove_err" "확인하고 강제로 지우려면: wt cleanup $(printf '%q' "$name") --yes"
      return 1
    fi

    # 제거에 성공했으므로 이제 부수 상태를 정리한다. 여기서 실패해도 worktree는 이미
    # 사라졌으니 중단하지 않고 알리기만 한다.
    _wt_tmux_close "$wt_path" || true
    _wt_tmux_session_close "$session_name" || _info "참고: $name — tmux 세션이 남아 있습니다 (연결된 클라이언트 또는 상태 확인 실패)"
    _wt_remove_claude_local_plugins_for_worktree "$wt_path" "$canonical_wt_path" \
      || _warn "참고: $name — Claude local plugin 등록을 정리하지 못했습니다"
    _wt_untrust_codex_project "$canonical_wt_path"
  else
    # forced는 main과 같은 순서를 유지한다 (호출자가 승인을 받은 경우와 clean 비-MERGED
    # 기존 경로가 여기로 온다). 아래 세션 종료가 실패하면 worktree 제거 전에 중단하므로
    # tmux 창만 닫힌 부분 정리가 남을 수 있다 — 기존부터 있던 동작이라 그대로 둔다.
    # guarded가 제거를 앞으로 당긴 것은 그 경로에만 적용되는 정책이다.
    _wt_tmux_close "$wt_path" || true
    _wt_tmux_session_close "$session_name" || {
      _info "스킵: $name — tmux 세션을 정리하지 못했습니다 (연결된 클라이언트 또는 상태 확인 실패)"
      return 1
    }
    _wt_remove_claude_local_plugins_for_worktree "$wt_path" "$canonical_wt_path" || return 1
    # `rm -rf` fallback은 제거했다. git이 `--force`로도 거부하는 대상(잠금 등)을 디렉토리만
    # 지워 흉내내면 등록은 남고 실체만 사라진 유령 worktree가 생긴다 — 실제로 잠긴 브리지
    # worktree에서 그렇게 만들어졌다. 실패는 guarded와 같은 등록 상태 분류로 안내하고 여기서
    # 멈춘다 (브랜치 삭제로 넘어가지 않는다).
    local remove_err remove_rc=0
    remove_err=$(git -C "$git_root" worktree remove --force "$wt_path" 2>&1 >/dev/null) || remove_rc=$?
    if (( remove_rc != 0 )); then
      _wt_warn_remove_failure "$name" "$branch" "$git_root" "$wt_path" "$canonical_wt_path" "$remove_err"
      return 1
    fi
    _wt_untrust_codex_project "$canonical_wt_path"
  fi

  # 브랜치 삭제 (detached가 아닌 경우)
  local branch_kept=false
  if [[ "$branch" != "detached" ]]; then
    if [[ "$mode" == "guarded" ]]; then
      # worktree 제거와 여기 사이에는 저장소 잠금이 없다. 그 틈에 다른 wt 실행이 아직
      # 남아 있는 이 브랜치를 새 worktree에 체크아웃할 수 있고, 커밋이 없으면 OID가 같아
      # CAS도 통과한다. porcelain이 하던 사용 중 검사를 삭제 직전에 되살려 그 창을 닫는다
      # (완전한 직렬화는 저장소 잠금이 필요하며, 그 보호는 forced 경로에도 원래 없다).
      local checkout_state
      checkout_state=$(_wt_branch_checkout_state "$git_root" "$branch")
      # --no-deref: update-ref는 기본적으로 symbolic ref를 따라간다. 그 사이 이 ref가
      # 같은 OID를 가리키는 symbolic ref로 바뀌면 CAS는 통과하면서 엉뚱한 대상 브랜치를
      # 지울 수 있다. OID 비교는 값만 보고 ref의 정체성 변경은 못 잡는다.
      if [[ "$checkout_state" == "in-use" ]]; then
        _warn "브랜치 유지: $branch (다른 worktree가 이 브랜치를 사용 중입니다)"
        branch_kept=true
      elif [[ "$checkout_state" != "free" ]]; then
        _warn "브랜치 유지: $branch (사용 중인지 확인하지 못해 ref를 지우지 않았습니다)"
        branch_kept=true
      elif ! git -C "$git_root" update-ref --no-deref -d "refs/heads/$branch" "$expected_oid" 2>/dev/null; then
        _warn "브랜치 유지: $branch (삭제 판정 이후 새 커밋이 생겨 ref를 지우지 않았습니다)"
        _warn "  복구: git worktree add ${_safe_wt_path} ${_safe_wt_branch}"
        branch_kept=true
      else
        # branch -D는 ref와 함께 branch.<name> 설정 섹션도 지운다. plumbing 삭제는 ref만
        # 지우므로, 정리해도 낡은 upstream·rebase 설정이 남아 같은 이름의 새 브랜치가
        # 그것을 물려받는다. (reflog는 update-ref -d도 함께 지운다 — 실측 확인.)
        git -C "$git_root" config --remove-section "branch.$branch" >/dev/null 2>&1 || true
      fi
    else
      git -C "$git_root" branch -D "$branch" 2>/dev/null || true
    fi
  fi

  # 후처리는 한곳에서만 한다 — 경로별로 복제하면 메시지와 실패 처리가 갈라진다.
  if [[ "$branch_kept" == "true" ]]; then
    _info "삭제: $name (worktree만)"
  else
    _info "삭제: $name ($branch)"
  fi

  # worktree 삭제 후 dangling 심링크 자동 복원 (#294). 실패를 삼키면 사용자가
  # dangling 심링크와 필요한 수동 조치를 모른 채 성공 메시지만 받는다.
  "$HOME/.local/bin/nrs-relink" fix-dangling >/dev/null 2>&1 \
    || _warn "심링크 복원 실패 — 수동 nrs 필요"
}
