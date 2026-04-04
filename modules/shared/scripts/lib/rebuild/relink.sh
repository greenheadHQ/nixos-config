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

#───────────────────────────────────────────────────────────────────────────────
# Worktree 심링크 전환/복원: worktree에서는 relink, main에서는 잔존 심링크 복원
# nrs.sh의 NO_CHANGES 및 rebuild 경로 양쪽에서 호출
#───────────────────────────────────────────────────────────────────────────────
maybe_relink_or_restore() {
    if [[ "$FLAKE_PATH" != "$MAIN_FLAKE_PATH" ]]; then
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
        # v2 (이번 변경): 대안 검토:
        #    (a) probe 목록 확장 → 새 엔트리가 추가될 때마다 수동 관리 필요, 근본 해결 아님
        #    (b) nrs-relink restore가 ./result의 새 HMF 참조 → 플랫폼별 경로 해석 복잡
        #    (c) dangling 심링크만 제거 → 워크트리가 살아있으면 dangling 아니라 탐지 실패
        #    (d) 워크트리 경로 패턴 매칭으로 직접 제거 → 채택
        #    trade-off: .claude/worktrees/ 외부에 수동 생성된 워크트리는 탐지 불가하지만,
        #              wt 스크립트가 .claude/worktrees/에만 생성하므로 실용적으로 충분.
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
            # 다중 probe: sed -i 등으로 대표 파일이 일반 파일로 바뀌거나,
            # relink skip으로 partial mismatch가 발생한 경우를 방어
            local _needs_restore=false
            local _p
            for _p in "$HOME/.claude/settings.json" "$HOME/.claude/mcp.json" "$HOME/.codex/config.toml"; do
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
    fi
}
