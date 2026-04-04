# shellcheck shell=bash
#───────────────────────────────────────────────────────────────────────────────
# Worktree symlink guard: worktree nrs 실행 시 main과의 mkOutOfStoreSymlink
# 엔트리 불일치를 사전 감지하고 차단
# - main에 추가된 엔트리가 worktree에 없으면 Home Manager가 해당 symlink을 삭제
# - --force로 우회 가능
#───────────────────────────────────────────────────────────────────────────────
worktree_symlink_guard() {
    [[ "$FLAKE_PATH" == "$MAIN_FLAKE_PATH" ]] && return 0

    log_info "🔍 Checking mkOutOfStoreSymlink consistency with main..."

    local merge_base
    merge_base=$(git -C "$FLAKE_PATH" merge-base HEAD main 2>/dev/null) || {
        log_warn "⚠️  symlink guard: cannot find merge-base with main. Skipping."
        return 0
    }

    local changed_nix_files
    changed_nix_files=$(git -C "$FLAKE_PATH" diff --name-only "$merge_base" main -- '*.nix' 2>/dev/null) || {
        log_warn "⚠️  symlink guard: git diff failed. Skipping."
        return 0
    }
    # DA R1 Fix: 플랫폼별 경로 필터 — darwin nrs가 nixos-only 파일에 차단되지 않도록
    local platform_filter
    case "$REBUILD_CMD" in
        darwin-rebuild)  platform_filter='^(modules/darwin/|modules/shared/|libraries/)' ;;
        nixos-rebuild)   platform_filter='^(modules/nixos/|modules/shared/|libraries/)' ;;
        *)               platform_filter='.' ;;
    esac
    changed_nix_files=$(printf '%s\n' "$changed_nix_files" | grep -E "$platform_filter" || true)

    local all_missing="" missing_count=0

    while IFS= read -r nix_file; do
        [[ -z "$nix_file" ]] && continue
        local main_entries base_entries
        main_entries=$(extract_oos_entries "main:$nix_file")
        [[ -z "$main_entries" ]] && continue

        # 3-way 비교: merge-base 대비 main에서 진짜 새로 추가된 엔트리만 플래그
        # (DA R4 Fix: worktree가 의도적으로 제거한 엔트리를 오탐하지 않도록)
        base_entries=$(extract_oos_entries "$merge_base:$nix_file")
        local new_on_main
        if [[ -z "$base_entries" ]]; then
            new_on_main="$main_entries"
        elif ! new_on_main=$(comm -23 <(printf '%s\n' "$main_entries") <(printf '%s\n' "$base_entries")); then
            new_on_main="$main_entries"
        fi
        [[ -z "$new_on_main" ]] && continue

        # Known limitation: main에서 .nix 파일이 rename된 경우, 새 경로가 worktree에
        # 없어 false positive 발생 가능. .nix 모듈 rename은 극히 드물고 --force로 우회 가능.
        local wt_entries
        if [[ ! -f "$FLAKE_PATH/$nix_file" ]]; then
            wt_entries=""
        else
            wt_entries=$(extract_oos_entries "$FLAKE_PATH/$nix_file")
        fi

        # 빈 wt_entries 특수 처리: printf '%s\n' ""는 빈 줄 1개를 comm에 전달하여
        # 실제 엔트리와 빈 문자열 간 오비교 발생. comm 실패 시 fail-closed (안전 우선).
        local only_in_main
        if [[ -z "$wt_entries" ]]; then
            only_in_main="$new_on_main"
        elif ! only_in_main=$(comm -23 <(printf '%s\n' "$new_on_main") <(printf '%s\n' "$wt_entries")); then
            only_in_main="$new_on_main"
        fi

        if [[ -n "$only_in_main" ]]; then
            while IFS= read -r entry; do
                [[ -z "$entry" ]] && continue
                all_missing+="    $nix_file → $entry"$'\n'
                ((++missing_count))
            done <<< "$only_in_main"
        fi
    done <<< "$changed_nix_files"

    # ── 역방향 검사: worktree-only entry 탐지 (정보성) ──────────────────
    # worktree에만 추가된 mkOutOfStoreSymlink entry를 감지하여 사용자에게 알린다.
    # _remove_worktree_symlinks()가 pre-rebuild에서 자동 처리하므로 차단하지 않는다.
    # merge_base..HEAD: worktree 브랜치에서 변경된 .nix 파일 (정방향의 merge_base..main과 반대)
    #
    # === Change Intent Record ===
    # v1 (6039360, PR #223): worktree_symlink_guard() 최초 도입 — 정방향 검사만
    # v2 (543acd7, PR #291): _remove_worktree_symlinks() 도입 — worktree-only 자동 제거
    # v3 (PR #293 초기): 역방향 검사를 missing_count==0 블록 내부에 배치
    #    → 설계 전제: "정방향 dirty면 역방향 정보는 noise"
    # v4 (PR #293): early return(L118/L128) 제거 — 빈 changed_nix_files에서도 역방향 도달
    # v5 (PR #293 최종): hoisting — 역방향을 missing_count 블록 밖으로 이동
    #    → v3 전제 기각: --force 시 자동 정리 대상의 가시성 확보 불가,
    #      차단 검사가 정보성 검사를 게이트하는 semantic coupling,
    #      "No drift" 직후 역방향 발견의 인지 부조화
    #    trade-off: missing_count>0일 때도 역방향 git diff 추가 실행되나,
    #              로컬 git 명령 1회로 무시 가능한 비용
    local wt_changed_nix_files
    wt_changed_nix_files=$(git -C "$FLAKE_PATH" diff --name-only "$merge_base" HEAD -- '*.nix' 2>/dev/null) || {
        log_warn "⚠️  symlink guard (reverse): git diff failed. Skipping."
        wt_changed_nix_files=""
    }
    wt_changed_nix_files=$(printf '%s\n' "$wt_changed_nix_files" | grep -E "$platform_filter" || true)

    if [[ -n "$wt_changed_nix_files" ]]; then
        local all_wt_only="" wt_only_count=0

        while IFS= read -r nix_file; do
            [[ -z "$nix_file" ]] && continue
            [[ ! -f "$FLAKE_PATH/$nix_file" ]] && continue

            local wt_entries base_entries main_entries
            wt_entries=$(extract_oos_entries "$FLAKE_PATH/$nix_file")
            [[ -z "$wt_entries" ]] && continue

            base_entries=$(extract_oos_entries "$merge_base:$nix_file")
            # wt에만 있는 엔트리 = worktree에서 새로 추가된 것 (base에는 없음)
            local new_in_wt
            if [[ -z "$base_entries" ]]; then
                new_in_wt="$wt_entries"
            elif ! new_in_wt=$(comm -23 <(printf '%s\n' "$wt_entries") <(printf '%s\n' "$base_entries")); then
                new_in_wt="$wt_entries"
            fi
            [[ -z "$new_in_wt" ]] && continue

            main_entries=$(extract_oos_entries "main:$nix_file")
            # new_in_wt 중 main에도 없는 것 = worktree-only entry
            local only_in_wt
            if [[ -z "$main_entries" ]]; then
                only_in_wt="$new_in_wt"
            elif ! only_in_wt=$(comm -23 <(printf '%s\n' "$new_in_wt") <(printf '%s\n' "$main_entries")); then
                only_in_wt="$new_in_wt"
            fi

            if [[ -n "$only_in_wt" ]]; then
                while IFS= read -r entry; do
                    [[ -z "$entry" ]] && continue
                    all_wt_only+="    $nix_file → $entry"$'\n'
                    ((++wt_only_count))
                done <<< "$only_in_wt"
            fi
        done <<< "$wt_changed_nix_files"

        if [[ $wt_only_count -gt 0 ]]; then
            log_info "  ℹ️  $wt_only_count worktree-only mkOutOfStoreSymlink entry(s) detected:"
            echo -n "$all_wt_only"
            echo "  (These will be auto-handled by pre-rebuild symlink cleanup)"
        fi
    fi

    # ── 정방향 결과 처리 ──────────────────────────────────────────────
    if [[ $missing_count -eq 0 ]]; then
        log_info "  ✓ No mkOutOfStoreSymlink drift."
        return 0
    fi

    if [[ "$FORCE_FLAG" == true ]]; then
        log_warn "⚠️  $missing_count mkOutOfStoreSymlink entry(s) missing vs main (--force, proceeding):"
        echo -n "$all_missing"
        echo ""
        return 0
    fi

    log_error "❌ Worktree would remove $missing_count mkOutOfStoreSymlink entry(s) from main:"
    echo -n "$all_missing"
    echo ""
    echo "  These entries were added to main after this worktree branched."
    echo "  Home Manager will silently remove these symlinks during switch."
    echo ""
    echo "  Fix:  git merge main    # incorporate main's changes"
    echo "        git rebase main   # or rebase onto main"
    echo "  Skip: nrs --force       # override (symlinks WILL be removed)"
    exit 1
}
