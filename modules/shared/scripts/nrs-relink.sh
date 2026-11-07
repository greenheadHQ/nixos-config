#!/usr/bin/env bash
# nrs-relink: worktree 심링크 전환/복원 CLI
# standalone 스크립트 — rebuild-common.sh를 source하지 않음
#
# 사용법:
#   nrs-relink relink       # ~/.claude/* 등을 현재 worktree로 전환
#   nrs-relink restore      # nix store 체인으로 복원
#   nrs-relink status       # 현재 심링크 상태 표시
#   nrs-relink fix-dangling  # dangling 감지 시에만 조건부 restore (#294)

set -euo pipefail

MAIN_REPO="@flakePath@"
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

# Git이 경로 뒤에 덧붙인 개행만 제거하여 경로 끝의 개행을 보존한다.
_capture_path() {
    local captured
    captured=$("$@" && printf '\001') || return 1
    REPLY=${captured%$'\001'}
    REPLY=${REPLY%$'\n'}
}

# BSD readlink는 target 자체가 개행으로 끝나면 출력 개행을 더하지 않는다.
# -n으로 출력 구분자를 없애고 sentinel만 제거해야 GNU/BSD 모두 경로를 보존한다.
_capture_link_target() {
    local captured
    captured=$(readlink -n "$1" && printf '\001') || return 1
    REPLY=${captured%$'\001'}
}

_safe_relative_path() {
    [[ -n "$1" && "$1" != /* && "/$1/" != *'/../'* && "/$1/" != *'/./'* && "$1" != *'//'* ]]
}

# 성공한 전체 NUL 목록만 사용한다. 중간 출력 뒤 Git 실패는 어떤 삭제/교체도 허용하지 않는다.
_load_worktrees() {
    WORKTREE_ROOTS=()
    WORKTREES_VERIFIED=false
    local listing record root main_common candidate_common candidate_top
    _capture_path git -C "$MAIN_REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || return 1
    main_common=$REPLY
    listing=$(mktemp "${TMPDIR:-/tmp}/nrs-worktrees.XXXXXX") || return 1
    if ! git -C "$MAIN_REPO" worktree list --porcelain -z > "$listing" 2>/dev/null; then
        rm -f "$listing"
        return 1
    fi
    while IFS= read -r -d '' record; do
        [[ "$record" == 'worktree '* ]] || continue
        root=${record#worktree }
        [[ "$root" == /* && "$root" != "$MAIN_REPO" && "/$root/" != *'/../'* && "/$root/" != *'/./'* ]] || continue
        if [[ -e "$root" || -L "$root" ]]; then
            _capture_path git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || continue
            candidate_common=$REPLY
            _capture_path git -C "$root" rev-parse --show-toplevel 2>/dev/null || continue
            candidate_top=$REPLY
            [[ "$candidate_common" == "$main_common" && "$candidate_top" == "$root" ]] || continue
        fi
        WORKTREE_ROOTS+=("$root")
    done < "$listing"
    rm -f "$listing"
    WORKTREES_VERIFIED=true
}

# 현재 HMF의 정확한 home→repo 매핑에 대응하는 worktree 링크만 관리한다.
# 같은 worktree 아래의 다른 사용자 링크와 일반 파일은 이 계약에 포함되지 않는다.
_is_worktree_target() {
    local target="$1" repo_rel="$2" home_path="$3" wanted_root="${4:-}" root
    for root in ${WORKTREE_ROOTS[@]+"${WORKTREE_ROOTS[@]}"}; do
        [[ -z "$wanted_root" || "$root" == "$wanted_root" ]] || continue
        [[ "$target" == "$root/$repo_rel" ]] || continue
        [[ -d "$root" || ! -e "$home_path" ]] || continue
        return 0
    done
    # 이전 설치가 남긴 내부 worktree 경로는 HMF 매핑과 저장소 소유권을 재확인한다.
    [[ "${WORKTREES_VERIFIED:-false}" == true ]] || return 1
    [[ "$target" == "$MAIN_REPO/.claude/worktrees/"*"/$repo_rel" ]] || return 1
    root=${target%"/$repo_rel"}
    [[ -z "$wanted_root" || "$root" == "$wanted_root" ]] || return 1
    [[ "/$root/" != *'/../'* && "/$root/" != *'/./'* ]] || return 1
    if [[ ! -e "$root" && ! -L "$root" ]]; then
        [[ ! -e "$home_path" ]]
        return
    fi
    local main_common candidate_common
    _capture_path git -C "$MAIN_REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || return 1
    main_common=$REPLY
    _capture_path git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || return 1
    candidate_common=$REPLY
    [[ "$candidate_common" == "$main_common" ]] || return 1
    _capture_path git -C "$root" rev-parse --show-toplevel 2>/dev/null || return 1
    [[ "$REPLY" == "$root" ]]
}

_home_parent_is_real() {
    local parent="${1%/*}" allow_missing="${2:-false}"
    while [[ "$parent" != "$HOME" ]]; do
        [[ "$parent" == "$HOME/"* ]] || return 1
        if [[ -e "$parent" || -L "$parent" ]]; then
            [[ -d "$parent" && ! -L "$parent" ]] || return 1
        else
            [[ "$allow_missing" == true ]] || return 1
        fi
        parent=${parent%/*}
    done
}

# 현재 HMF 매핑에 필요한 부모만 위에서부터 생성한다. mkdir -p로 기존
# symlink를 따라가지 않으며, 각 생성 전후 실제 디렉터리 경계를 재확인한다.
_create_home_parents() {
    local home_path="$1" parent="${1%/*}" count=0
    local missing=()
    _home_parent_is_real "$home_path" true || return 1
    while [[ "$parent" != "$HOME" && ! -e "$parent" && ! -L "$parent" ]]; do
        missing[count]=$parent
        ((++count))
        parent=${parent%/*}
    done
    while [[ "$count" -gt 0 ]]; do
        count=$((count - 1))
        parent=${missing[count]}
        _home_parent_is_real "$parent" || return 1
        if ! mkdir "$parent"; then
            [[ -d "$parent" && ! -L "$parent" ]] || return 1
        fi
        [[ -d "$parent" && ! -L "$parent" ]] || return 1
    done
    _home_parent_is_real "$home_path"
}

_can_replace_entry() {
    local home_rel="$1" repo_rel="$2" hmf="$3" home_path="$HOME/$1" allow_missing="${4:-false}" target
    _safe_relative_path "$home_rel" && _safe_relative_path "$repo_rel" || return 1
    _home_parent_is_real "$home_path" "$allow_missing" || return 1
    if [[ ! -L "$home_path" ]]; then
        [[ ! -e "$home_path" ]] # 일반 파일/디렉터리/특수 파일은 보존한다.
        return
    fi
    _capture_link_target "$home_path" || return 1
    target=$REPLY
    [[ "$target" == "$hmf/$home_rel" || "$target" == "$MAIN_REPO/$repo_rel" ]] && return 0
    _is_worktree_target "$target" "$repo_rel" "$home_path"
}

#───────────────────────────────────────────────────────────────────────────────
# Discovery: home-manager-files nix store 경로 추출
#───────────────────────────────────────────────────────────────────────────────
_discover_hmf() {
    # 방법 1: HM gcroots (relink 후에도 안정적, HM activation이 관리)
    local gc="$HOME/.local/state/home-manager/gcroots/current-home"
    if [[ -L "$gc" ]]; then
        local gen hmf
        gen=$(readlink "$gc")
        hmf=$(readlink "$gen/home-files" 2>/dev/null) || true
        if [[ "$hmf" == /nix/store/*-home-manager-files ]]; then
            echo "$hmf"
            return 0
        fi
    fi
    # 방법 2: fallback — 임의의 HM 관리 심링크를 probe로 역추적
    local probe
    for probe in "$HOME/.claude/settings.json" "$HOME/.config/git/config"; do
        [[ -L "$probe" ]] || continue
        local target
        target=$(readlink "$probe")
        if [[ "$target" == /nix/store/*-home-manager-files/* ]]; then
            echo "${target%%-home-manager-files/*}-home-manager-files"
            return 0
        fi
    done
    return 1
}

#───────────────────────────────────────────────────────────────────────────────
# HMF 내의 모든 out-of-store 심링크 발견
# 출력: home_rel, repo_rel 두 NUL 필드 (개행/파이프가 포함된 경로 보존)
#───────────────────────────────────────────────────────────────────────────────
_discover_oos_entries() {
    local hmf="$1" main_repo="$2"
    find "$hmf" -type l -print0 2>/dev/null | while IFS= read -r -d '' link; do
        # CIR: readlink -f → hop-by-hop 루프 선택 — readlink -f는 부모 디렉토리가 없으면 실패하여
        #      worktree-only 새 디렉토리의 파일을 발견하지 못함 (#332)
        local current="$link" final_target="" hop=0
        local max_hops=10  # nix store 체인은 2-3 hop; 10은 안전 마진
        while [[ $hop -lt $max_hops ]]; do
            local target
            _capture_link_target "$current" 2>/dev/null || break
            target=$REPLY
            # 중간 hop은 nix store 절대 심링크. 첫 $main_repo/* match를 OOS 매핑으로 사용.
            if [[ "$target" == "$main_repo"/* ]]; then
                final_target="$target"
                break
            fi
            current="$target"
            ((++hop))
        done
        [[ -n "$final_target" ]] || continue
        local home_rel="${link#"$hmf"/}"
        local repo_rel="${final_target#"$main_repo"/}"
        if ! _safe_relative_path "$home_rel" || ! _safe_relative_path "$repo_rel"; then
            continue
        fi
        printf '%s\0%s\0' "$home_rel" "$repo_rel"
    done
}

# process substitution으로 생산자 종료 상태를 잃지 않도록 전체 열거를 먼저
# 확인한다. 실패한 부분 목록은 검사·복원·relink 어느 경로에서도 사용하지 않는다.
_load_oos_entries() {
    local hmf="$1" listing home_rel repo_rel
    OOS_HOME_RELS=()
    OOS_REPO_RELS=()
    OOS_ENTRY_COUNT=0
    listing=$(mktemp "${TMPDIR:-/tmp}/nrs-oos-entries.XXXXXX") || return 1
    if ! _discover_oos_entries "$hmf" "$MAIN_REPO" > "$listing"; then
        rm -f "$listing"
        echo "Could not enumerate home-manager-files mappings; preserving existing entries" >&2
        return 1
    fi
    while IFS= read -r -d '' home_rel && IFS= read -r -d '' repo_rel; do
        OOS_HOME_RELS[OOS_ENTRY_COUNT]=$home_rel
        OOS_REPO_RELS[OOS_ENTRY_COUNT]=$repo_rel
        ((++OOS_ENTRY_COUNT))
    done < "$listing"
    rm -f "$listing"
}

#───────────────────────────────────────────────────────────────────────────────
# Post-relink: HMF 내 OOS 심링크 체인 무결성 검증 (non-blocking)
# 현재 HM mkOutOfStoreSymlink는 2-hop 체인: HMF → /nix/store/hm_xxx → $MAIN_REPO/...
# 이 함수는 각 hop의 대상이 유효한지 확인하고, 손상 시 경고 + 복구 명령을 안내한다.
#───────────────────────────────────────────────────────────────────────────────
_check_oos_chain() {
    local hmf="$1" main_repo="$2"
    local corrupted=0
    while IFS= read -r -d '' link; do
        local store_link
        # readlink 실패 = 경로 소멸 또는 읽기 불가; best-effort skip
        store_link=$(readlink "$link" 2>/dev/null) || continue

        # L1: HMF entry는 반드시 /nix/store/*를 가리켜야 함
        if [[ "$store_link" != /nix/store/* ]]; then
            echo -e "${RED}  nix store corruption: ${link#"$hmf"/} -> $store_link${NC}" >&2
            echo -e "${YELLOW}  Fix: sudo nix-store --repair-path $hmf${NC}" >&2
            ((++corrupted))
            continue
        fi

        # L2: mkOutOfStoreSymlink derivation만 검사 (regular file은 non-OOS이므로 skip)
        if [[ -L "$store_link" ]]; then
            local store_target
            # readlink 실패 = derivation 경로 소멸 또는 읽기 불가; best-effort skip
            store_target=$(readlink "$store_link" 2>/dev/null) || continue
            if [[ "$store_target" != "$main_repo"/* ]]; then
                echo -e "${RED}  nix store corruption: ${link#"$hmf"/} -> $store_target${NC}" >&2
                echo -e "${YELLOW}  Fix: sudo nix-store --repair-path $store_link${NC}" >&2
                ((++corrupted))
            fi
        fi
    done < <(find "$hmf" -type l -print0 2>/dev/null)

    if [[ $corrupted -gt 0 ]]; then
        echo -e "${RED}  $corrupted corrupted nix store symlink(s) detected${NC}" >&2
    fi
    return 0
}

#───────────────────────────────────────────────────────────────────────────────
# relink: worktree 경로로 심링크 전환
#───────────────────────────────────────────────────────────────────────────────
cmd_relink() {
    # worktree 여부 검증
    local git_toplevel
    _capture_path git rev-parse --show-toplevel 2>/dev/null || {
        echo -e "${YELLOW}Git repository not found${NC}" >&2
        exit 1
    }

    git_toplevel=$REPLY

    if [[ "$git_toplevel" == "$MAIN_REPO" ]]; then
        echo -e "${YELLOW}Not in a worktree (main repo). Nothing to relink.${NC}"
        return 0
    fi

    local worktree="$git_toplevel" root registered=false
    _load_worktrees || {
        echo "Could not verify registered worktrees" >&2
        return 1
    }
    for root in ${WORKTREE_ROOTS[@]+"${WORKTREE_ROOTS[@]}"}; do
        [[ "$root" != "$worktree" ]] || registered=true
    done
    [[ "$registered" == true ]] || {
        echo "Current repository is not a registered worktree of the configured main repository" >&2
        return 1
    }

    local hmf
    hmf=$(_discover_hmf) || {
        echo -e "${YELLOW}Could not discover home-manager-files store path${NC}" >&2
        exit 1
    }

    _load_oos_entries "$hmf" || return 1
    local relinked=0 skipped=0 entry_index home_rel repo_rel
    for ((entry_index=0; entry_index<OOS_ENTRY_COUNT; entry_index++)); do
        home_rel=${OOS_HOME_RELS[entry_index]}
        repo_rel=${OOS_REPO_RELS[entry_index]}
        [[ -z "$home_rel" ]] && continue
        local wt_target="$worktree/$repo_rel"
        if [[ -e "$wt_target" || -L "$wt_target" ]] && _can_replace_entry "$home_rel" "$repo_rel" "$hmf"; then
            ln -sfn "$wt_target" "$HOME/$home_rel"
            ((++relinked))
        else
            echo -e "${YELLOW}  skip: $home_rel (not in worktree)${NC}"
            ((++skipped))
        fi
    done

    echo -e "${GREEN}Relinked $relinked symlink(s) to worktree${NC}"
    if [[ $skipped -gt 0 ]]; then
        echo -e "${YELLOW}  ($skipped skipped — not present in worktree)${NC}"
    fi

    # Post-relink: nix store 심링크 체인 무결성 검증 (warn only, non-blocking)
    _check_oos_chain "$hmf" "$MAIN_REPO"
}

#───────────────────────────────────────────────────────────────────────────────
# restore: nix store 체인으로 복원
#───────────────────────────────────────────────────────────────────────────────
cmd_restore() {
    local hmf
    hmf=$(_discover_hmf) || {
        echo -e "${YELLOW}Could not discover home-manager-files store path${NC}" >&2
        exit 1
    }

    if ! _load_worktrees; then
        WORKTREE_ROOTS=()
        echo "Could not verify registered worktrees; preserving unverified links" >&2
    fi
    _load_oos_entries "$hmf" || return 1
    local restored=0 preserved=0 entry_index home_rel repo_rel
    for ((entry_index=0; entry_index<OOS_ENTRY_COUNT; entry_index++)); do
        home_rel=${OOS_HOME_RELS[entry_index]}
        repo_rel=${OOS_REPO_RELS[entry_index]}
        [[ -z "$home_rel" ]] && continue
        if ! _can_replace_entry "$home_rel" "$repo_rel" "$hmf" true; then
            ((++preserved))
            continue
        fi
        _create_home_parents "$HOME/$home_rel" || return 1
        # 부모 생성 사이에 나타난 사용자 entry도 덮어쓰지 않는다.
        _can_replace_entry "$home_rel" "$repo_rel" "$hmf" || return 1
        ln -sfn "$hmf/$home_rel" "$HOME/$home_rel"
        ((++restored))
    done

    echo -e "${GREEN}Restored $restored symlink(s) to nix store chain${NC}"
    if [[ "$preserved" -gt 0 ]]; then
        echo "Preserved $preserved user or unverified entry(s); inspect nrs-relink status" >&2
    fi
    _warn_remaining_worktree_links
}

_warn_remaining_worktree_links() {
    local link target root wanted_root="${1:-}"
    while IFS= read -r -d '' link; do
        _capture_link_target "$link" 2>/dev/null || continue
        target=$REPLY
        for root in ${WORKTREE_ROOTS[@]+"${WORKTREE_ROOTS[@]}"}; do
            [[ -z "$wanted_root" || "$root" == "$wanted_root" ]] || continue
            [[ "$target" == "$root/"* ]] || continue
            printf 'Preserved worktree link; inspect before resolving an activation conflict: %q\n' "$link" >&2
            break
        done
    done < <(find "$HOME/.claude" "$HOME/.codex" -maxdepth 3 -type l -print0 2>/dev/null)
}

# rebuild 내부용 읽기 검사: 복원이 필요한 검증된 링크나 누락 entry를 찾는다.
# rc 0 = 복원 필요, 1 = 필요 없음, 2 = 근거 조회 실패. 이 단계는 홈을 변경하지 않는다.
cmd_needs_restore() {
    local hmf home_rel repo_rel home_path target entry_index needed=false
    hmf=$(_discover_hmf) || return 2
    _load_oos_entries "$hmf" || return 2
    if ! _load_worktrees; then
        WORKTREE_ROOTS=()
        echo "Could not verify registered worktrees; preserving unverified links" >&2
    fi
    for ((entry_index=0; entry_index<OOS_ENTRY_COUNT; entry_index++)); do
        home_rel=${OOS_HOME_RELS[entry_index]}
        repo_rel=${OOS_REPO_RELS[entry_index]}
        home_path="$HOME/$home_rel"
        if ! _can_replace_entry "$home_rel" "$repo_rel" "$hmf" true; then
            if [[ -L "$home_path" ]]; then
                printf 'Preserved unverified link: %q\n' "$home_path" >&2
            fi
            continue
        fi
        if [[ ! -L "$home_path" ]]; then
            needed=true
        elif _capture_link_target "$home_path"; then
            target=$REPLY
            [[ "$target" == "$hmf/$home_rel" ]] || needed=true
        fi
    done
    [[ "$needed" == false ]] || return 0
    _warn_remaining_worktree_links
    [[ "$WORKTREES_VERIFIED" == true ]] || return 2
    return 1
}

#───────────────────────────────────────────────────────────────────────────────
# status: 현재 심링크 상태 표시
#───────────────────────────────────────────────────────────────────────────────
cmd_status() {
    local hmf
    hmf=$(_discover_hmf) || {
        echo -e "${YELLOW}Could not discover home-manager-files store path${NC}" >&2
        exit 1
    }

    local count=0
    while IFS= read -r -d '' home_rel && IFS= read -r -d '' repo_rel; do
        [[ -z "$home_rel" ]] && continue
        local home_path="$HOME/$home_rel"

        if [[ ! -L "$home_path" ]]; then
            echo -e "  ${YELLOW}[NOT SYMLINK]${NC} $home_rel"
        elif [[ ! -e "$home_path" ]]; then
            echo -e "  ${YELLOW}[DANGLING]${NC}    $home_rel"
        else
            # direct readlink (1-hop)로 판정: nix store → [main], 그 외 → [worktree]
            local direct_target
            direct_target=$(readlink "$home_path" 2>/dev/null) || direct_target=""

            if [[ "$direct_target" == /nix/store/* ]]; then
                echo -e "  ${GREEN}[main]${NC}        $home_rel"
            else
                echo -e "  ${YELLOW}[worktree]${NC}    $home_rel → $direct_target"
            fi
        fi
        ((++count))
    done < <(_discover_oos_entries "$hmf" "$MAIN_REPO")

    if [[ $count -eq 0 ]]; then
        echo -e "${YELLOW}No out-of-store symlinks found${NC}"
    else
        echo -e "\n  Total: $count entries"
    fi
}

#───────────────────────────────────────────────────────────────────────────────
# fix-dangling: dangling 감지 시에만 조건부 restore (#294)
# PostToolUse hook에서 호출. precmd는 성능상 인라인 canary 사용 (동일 로직).
#───────────────────────────────────────────────────────────────────────────────
cmd_fix_dangling() {
    # settings.json과 CLAUDE.md를 빠른 자동 복구의 대표 canary로 사용한다 (#1381).
    # 재빌드 경로는 needs-restore에서 전체 HMF 매핑을 확인한다:
    # settings.json은 hostType "work"에서 mkIf로 심링크 배치가 제외되어 비-symlink(무효
    # canary)가 될 수 있으므로, 전 호스트 OOS 심링크인 CLAUDE.md를 함께 검사한다.
    # 모든 OOS 심링크가 동시에 relink/restore되므로, 하나만 dangling이면 전체가 dangling.
    # nrs-relink restore가 전체 OOS 심링크를 일괄 복원한다.
    #
    # 이 목록은 _repair_claude_symlinks(modules/shared/programs/shell/default.nix)의
    # 인라인 canary와 동일해야 한다 —
    # tests/suites/rebuild-nrs.sh:test_fix_dangling_probe_lists_match_between_cli_and_inline이
    # 두 목록의 일치를 고정한다.
    local _probe
    for _probe in "$HOME/.claude/settings.json" "$HOME/.claude/CLAUDE.md"; do
        if [[ -L "$_probe" && ! -e "$_probe" ]]; then
            cmd_restore
            return
        fi
    done
}

#───────────────────────────────────────────────────────────────────────────────
# Entry point
#───────────────────────────────────────────────────────────────────────────────
case "${1:-}" in
    relink)       cmd_relink ;;
    restore)      cmd_restore ;;
    status)       cmd_status ;;
    needs-restore) cmd_needs_restore ;;
    fix-dangling) cmd_fix_dangling ;;
    *)
        echo "Usage: nrs-relink {relink|restore|status|fix-dangling}" >&2
        exit 1
        ;;
esac
