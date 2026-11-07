# shellcheck shell=bash
rebuild_is_main_flake() {
    [[ "$FLAKE_PATH" == "$MAIN_FLAKE_PATH" ]]
}

_nrs_should_skip_worktree_relink() {
    [[ "${NRS_ALLOW_WORKTREE_RELINK:-}" == "1" ]] && return 1
    [[ ! -t 0 ]] && return 0
    [[ "${CODEX_PROGRAMMATIC:-}" == "1" ]] && return 0
    [[ "${CLAUDECODE:-}" == "1" ]] && return 0
    return 1
}

prepare_worktree_symlinks_for_rebuild() {
    log_info "🔗 Restoring verified worktree symlinks before rebuild..."
    # 기존 entry를 nix store chain으로 복원 (rebuild 실패 시에도 안전)
    "$HOME/.local/bin/nrs-relink" restore || log_warn "⚠️  nrs-relink restore failed (non-fatal)"
}

#───────────────────────────────────────────────────────────────────────────────
# Worktree 심링크 전환/복원: worktree에서는 relink, main에서는 잔존 심링크 복원
# nrs.sh의 NO_CHANGES 및 rebuild 경로 양쪽에서 호출
#───────────────────────────────────────────────────────────────────────────────
maybe_relink_or_restore() {
    if ! rebuild_is_main_flake; then
        # === Change Intent Record ===
        # v6 (#996): 비대화형/에이전트 worktree nrs에서 post-switch relink가
        #    $HOME의 OOS 심링크를 리뷰 전 worktree로 전환해 host 활성본과 tracked file을
        #    교차 오염시키는 사고가 실측됨(2026-07-06).
        #    채택: stdin 비TTY 또는 기존 에이전트 신호(CODEX_PROGRAMMATIC/CLAUDECODE)면
        #    relink만 skip하고 nrs 흐름은 계속 진행. 명시 opt-in
        #    NRS_ALLOW_WORKTREE_RELINK=1은 기존 동작을 유지한다.
        #    trade-off: 파이프/자동화에서 의도적 worktree relink가 필요하면 env opt-in이
        #              필요하지만, 대화형 TTY 사용자의 기존 워크플로는 변경하지 않는다.
        if _nrs_should_skip_worktree_relink; then
            log_info "🔗 Skipping worktree relink in non-interactive/agent context (set NRS_ALLOW_WORKTREE_RELINK=1 to allow)."
            return 0
        fi
        log_info "🔗 Relinking symlinks to worktree..."
        "$HOME/.local/bin/nrs-relink" relink || log_warn "⚠️  nrs-relink failed (non-fatal)"
    else
        # HMF와 Git 등록 목록으로 복원 필요 여부를 읽기만 한다. 선삭제하지 않으므로
        # 중간 실패가 아직 복원하지 못한 링크를 유실시키지 않는다. 누락된 canary도
        # HMF의 home→repo 매핑으로 찾아 NO_CHANGES 경로에서 복원한다.
        local restore_status=0
        "$HOME/.local/bin/nrs-relink" needs-restore || restore_status=$?
        if [[ "$restore_status" -eq 0 ]]; then
            log_info "🔗 Restoring symlinks to nix store chain..."
            "$HOME/.local/bin/nrs-relink" restore || log_warn "⚠️  nrs-relink restore failed (non-fatal)"
        elif [[ "$restore_status" -ne 1 ]]; then
            log_warn "⚠️  Worktree link evidence unavailable; preserving existing links."
        fi
        # ~/.codex/config.toml 의 legacy symlink / missing / mode drift / content drift 는
        # lib/rebuild/codex.sh 의 repair_codex_config_drift_no_changes() 가 nrs.sh
        # NO_CHANGES 분기에서 atomic write 로 직접 복구한다.
    fi
}
