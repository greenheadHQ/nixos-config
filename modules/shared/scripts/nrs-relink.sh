#!/usr/bin/env bash
# nrs-relink: worktree 심링크 전환/복원 CLI
# standalone 스크립트 — rebuild-common.sh를 source하지 않음
#
# 사용법:
#   nrs-relink relink   # ~/.claude/* 등을 현재 worktree로 전환
#   nrs-relink restore  # nix store 체인으로 복원
#   nrs-relink status   # 현재 심링크 상태 표시

set -euo pipefail

MAIN_REPO="@flakePath@"
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

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
# 출력: home_rel|repo_rel (파이프 구분)
#───────────────────────────────────────────────────────────────────────────────
_discover_oos_entries() {
    local hmf="$1" main_repo="$2"
    find "$hmf" -type l -print0 2>/dev/null | while IFS= read -r -d '' link; do
        local final_target
        final_target=$(readlink -f "$link" 2>/dev/null) || continue
        # main repo 하위 파일만 (nix store 내부 심링크는 제외)
        [[ "$final_target" == "$main_repo"/* ]] || continue
        local home_rel="${link#"$hmf"/}"
        local repo_rel="${final_target#"$main_repo"/}"
        echo "${home_rel}|${repo_rel}"
    done
}

#───────────────────────────────────────────────────────────────────────────────
# relink: worktree 경로로 심링크 전환
#───────────────────────────────────────────────────────────────────────────────
cmd_relink() {
    # worktree 여부 검증
    local git_toplevel
    git_toplevel=$(git rev-parse --show-toplevel 2>/dev/null) || {
        echo -e "${YELLOW}Git repository not found${NC}" >&2
        exit 1
    }

    if [[ "$git_toplevel" == "$MAIN_REPO" ]]; then
        echo -e "${YELLOW}Not in a worktree (main repo). Nothing to relink.${NC}"
        return 0
    fi

    local worktree="$git_toplevel"

    local hmf
    hmf=$(_discover_hmf) || {
        echo -e "${YELLOW}Could not discover home-manager-files store path${NC}" >&2
        exit 1
    }

    local relinked=0 skipped=0
    while IFS='|' read -r home_rel repo_rel; do
        [[ -z "$home_rel" ]] && continue
        local wt_target="$worktree/$repo_rel"
        if [[ -e "$wt_target" || -L "$wt_target" ]]; then
            ln -sfn "$wt_target" "$HOME/$home_rel"
            ((++relinked))
        else
            echo -e "${YELLOW}  skip: $home_rel (not in worktree)${NC}"
            ((++skipped))
        fi
    done < <(_discover_oos_entries "$hmf" "$MAIN_REPO")

    echo -e "${GREEN}Relinked $relinked symlink(s) to worktree${NC}"
    if [[ $skipped -gt 0 ]]; then
        echo -e "${YELLOW}  ($skipped skipped — not present in worktree)${NC}"
    fi
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

    local restored=0
    while IFS='|' read -r home_rel repo_rel; do
        [[ -z "$home_rel" ]] && continue
        ln -sfn "$hmf/$home_rel" "$HOME/$home_rel"
        ((++restored))
    done < <(_discover_oos_entries "$hmf" "$MAIN_REPO")

    echo -e "${GREEN}Restored $restored symlink(s) to nix store chain${NC}"
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
    while IFS='|' read -r home_rel repo_rel; do
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
# Entry point
#───────────────────────────────────────────────────────────────────────────────
case "${1:-}" in
    relink)  cmd_relink ;;
    restore) cmd_restore ;;
    status)  cmd_status ;;
    *)
        echo "Usage: nrs-relink {relink|restore|status}" >&2
        exit 1
        ;;
esac
