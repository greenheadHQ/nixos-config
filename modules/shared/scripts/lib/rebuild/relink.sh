# shellcheck shell=bash
#───────────────────────────────────────────────────────────────────────────────
# Worktree 심링크 제거: 지정 패턴에 매칭되는 심링크를 $HOME/.claude, .codex에서 제거
# 사용처: maybe_relink_or_restore() (main: stale 제거), nrs.sh (worktree: pre-rebuild 제거)
#───────────────────────────────────────────────────────────────────────────────
_remove_worktree_symlinks() {
    local pattern="$1" label="${2:-worktree}"
    local _wt_cleaned=0
    while IFS= read -r -d '' _link; do
        local _lt
        _lt=$(readlink "$_link" 2>/dev/null) || continue
        if [[ "$_lt" == "$pattern"* ]]; then
            rm -f "$_link"
            ((++_wt_cleaned))
        fi
    done < <(find "$HOME/.claude" "$HOME/.codex" -maxdepth 3 -type l -print0 2>/dev/null)
    if [[ $_wt_cleaned -gt 0 ]]; then
        log_info "  ✓ Removed $_wt_cleaned ${label} symlink(s)"
        return 0  # 제거 발생
    fi
    return 1  # 제거 없음
}

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
    log_info "🔗 Removing worktree symlinks before rebuild..."
    _remove_worktree_symlinks "$FLAKE_PATH/" "worktree" || true
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
        # Main repo: worktree 심링크가 잔존하면 nix store 체인으로 복원

        # Phase 1: stale 워크트리 심링크 제거
        # nrs-relink restore는 현재 HMF 기반이라, 워크트리에서 새로 추가된 엔트리를 모름.
        # 워크트리 경로를 직접 가리키는 심링크는 nrs-relink relink이 생성한 것이므로
        # main에서는 항상 stale → 제거하면 HM activation이 새 심링크를 정상 생성.
        #
        # === Change Intent Record ===
        # v1 (PR #239): probe 3개(settings.json, mcp.json, config.toml) 기반 복원 도입.
        #    기존 엔트리 전환/복원은 충분했으나, 워크트리에서 새로 추가된 엔트리는 현재
        #    HMF에 없어 nrs-relink restore가 인식 불가 → HM clobber 에러 발생.
        # v2 (후속): 대안 검토:
        #    (a) probe 목록 확장 → 새 엔트리가 추가될 때마다 수동 관리 필요, 근본 해결 아님
        #    (b) nrs-relink restore가 ./result의 새 HMF 참조 → 플랫폼별 경로 해석 복잡
        #    (c) dangling 심링크만 제거 → 워크트리가 살아있으면 dangling 아니라 탐지 실패
        #    (d) 워크트리 경로 패턴 매칭으로 직접 제거 → 채택
        #    trade-off: .claude/worktrees/ 외부에 수동 생성된 워크트리는 탐지 불가하지만,
        #              wt 스크립트가 .claude/worktrees/에만 생성하므로 실용적으로 충분.
        # v3: ~/.codex/config.toml을 HM out-of-store symlink에서 activation
        #    seed+merge 기반 regular file로 전환. probe 대상에서 제외하여 이제 probe 2개
        #    (settings.json, mcp.json)로 축소.
        # v4 (#511 followup): NO_CHANGES 경로 ~/.codex/config.toml drift 자동 복구 도입.
        #    이 함수(maybe_relink_or_restore)는 symlink/relink 책임만 유지하고, 이전 v3
        #    하단의 config.toml 경고 가드는 lib/rebuild/codex.sh 의
        #    repair_codex_config_drift_no_changes() 가 대체한다. no-op 계약과 self-heal
        #    범위의 authoritative 설명은 sync-codex-config.py docstring 참고.
        # v5 (이번 변경): chrome-devtools MCP 제거로 ~/.claude/mcp.json out-of-store symlink가
        #    더 이상 생성되지 않아 probe에서 제외. 대신 CLAUDE.md를 추가한다 — settings.json은
        #    hostType "work"에서 mkIf로 심링크 배치가 제외되어 비심링크(무효 probe)가 되므로,
        #    모든 호스트에서 가드 없이 OOS 심링크인 CLAUDE.md를 work-호환 canary로 둔다.
        #    probe 2개(settings.json, CLAUDE.md).
        if _remove_worktree_symlinks "$MAIN_FLAKE_PATH/.claude/worktrees/" "stale worktree"; then
            # stale worktree 심링크가 제거되면 probe 파일(settings.json 등)도 사라져
            # Phase 2의 probe 탐지가 실패할 수 있음. NO_CHANGES 경로에서는 HM activation이
            # 실행되지 않아 심링크가 영구 유실됨 → 무조건 restore 실행.
            log_info "🔗 Restoring symlinks to nix store chain..."
            "$HOME/.local/bin/nrs-relink" restore || log_warn "⚠️  nrs-relink restore failed (non-fatal)"
        else
            # Phase 2: 기존 엔트리 nix store 체인 복원 (Phase 1 미작동 시 fallback)
            # NO_CHANGES 경로에서는 rebuild가 스킵되어 HM activation이 실행되지 않고,
            # --force rebuild에서도 동일 generation이면 HM이 심링크를 재생성하지 않으므로
            # 명시적 복원이 필요
            # 다중 probe: sed -i 등으로 대표 파일이 일반 파일로 바뀌거나, relink skip으로
            # store-link mismatch가 발생한 경우를 방어. settings.json은 work 호스트에서
            # 비심링크이므로, 전 호스트 OOS 심링크인 CLAUDE.md를 함께 둬 work canary를 보장한다.
            local _needs_restore=false
            local _p
            for _p in "$HOME/.claude/settings.json" "$HOME/.claude/CLAUDE.md"; do
                [[ ! -L "$_p" ]] && continue
                local _target
                _target=$(readlink "$_p" 2>/dev/null) || continue
                if [[ "$_target" != /nix/store/* ]]; then
                    _needs_restore=true
                    break
                fi
            done
            if [[ "$_needs_restore" == true ]]; then
                log_info "🔗 Restoring symlinks to nix store chain..."
                "$HOME/.local/bin/nrs-relink" restore || log_warn "⚠️  nrs-relink restore failed (non-fatal)"
            fi
        fi
        # ~/.codex/config.toml 의 legacy symlink / missing / mode drift / content drift 는
        # lib/rebuild/codex.sh 의 repair_codex_config_drift_no_changes() 가 nrs.sh
        # NO_CHANGES 분기에서 atomic write 로 직접 복구한다 (v4 CIR 참고).
    fi
}
