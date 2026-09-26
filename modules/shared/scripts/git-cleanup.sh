#!/usr/bin/env bash
# git-cleanup: 사용하지 않는 로컬 브랜치 정리
# 사용법: git cleanup [--dry-run] [--help]

set -euo pipefail

# 로케일 고정 (git 출력의 [gone] 등이 다른 언어로 표시되는 것 방지)
export LC_ALL=C

PROTECTED_BRANCHES="main master develop stage"
STALE_DAYS=30
DRY_RUN=false

# 데이터 저장 배열
declare -a gone_branches=()
declare -a stale_branches=()
declare -a protected_branches=()
declare -a active_branches=()
current_branch=""

show_help() {
    cat << 'EOF'
사용법: git cleanup [옵션]

사용하지 않는 로컬 브랜치를 정리합니다.

옵션:
  --dry-run    삭제 대상만 표시하고 실제 삭제하지 않음
  --help       이 도움말 표시

삭제 기준:
  ✅ gone   - 원격에서 삭제된 브랜치 (삭제 권장)
  ⚠️ stale  - 30일 이상 된 로컬 전용 브랜치 (주의 필요)

보호 브랜치 (삭제 불가):
  main, master, develop, stage, 현재 체크아웃된 브랜치
EOF
}

# 옵션 파싱
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true ;;
        --help|-h) show_help; exit 0 ;;
        *)
            echo "알 수 없는 옵션: $1" >&2
            echo "사용법: git cleanup [--dry-run] [--help]" >&2
            exit 1
            ;;
    esac
    shift
done

check_git_repo() {
    if ! git rev-parse --git-dir &>/dev/null; then
        echo "❌ git 저장소가 아닙니다." >&2
        exit 1
    fi
}

fetch_and_prune() {
    echo "🔄 Fetching and pruning remote branches..."
    if ! git fetch --prune --quiet 2>/dev/null; then
        echo "⚠️  원격 저장소 연결 실패 - 로컬 정보로 계속 진행"
    fi
}

get_stale_timestamp() {
    # BSD/GNU date는 "N일 전" 옵션 문법(-v vs -d)이 서로 달라 절대경로나 옵션으로 구현을
    # 구분하려 하면(예: /usr/bin/date 존재 여부) 실제 시스템 구성과 맞지 않을 수 있다
    # (#1376). 대신 두 구현이 공통으로 지원하는 `date +%s`로 현재 epoch만 얻고, 30일은
    # 고정 초 차이(30*86400초)로 셸 산술로 뺀다 — 달력 계산이 없으므로 시간대·일광절약시간
    # 경계와 무관하다.
    local now
    now=$(date +%s) || {
        echo "❌ 현재 시각(epoch)을 가져오지 못했습니다: 'date +%s' 실행 실패" >&2
        exit 1
    }
    if [[ ! "$now" =~ ^[0-9]+$ ]]; then
        echo "❌ 현재 시각(epoch) 계산 실패: 'date +%s' 출력이 숫자가 아닙니다 (출력: $now)" >&2
        exit 1
    fi
    echo $(( now - STALE_DAYS * 86400 ))
}

is_protected() {
    local branch="$1"
    for protected in $PROTECTED_BRANCHES; do
        if [[ "$branch" == "$protected" ]]; then
            return 0
        fi
    done
    return 1
}

collect_branches() {
    current_branch=$(git branch --show-current)
    local stale_timestamp
    stale_timestamp=$(get_stale_timestamp)

    # git branch -vv 출력 파싱
    while IFS= read -r line; do
        # 앞의 기호와 공백 제거
        # * = 현재 브랜치, + = 다른 worktree에서 체크아웃된 브랜치
        line="${line#\* }"
        line="${line#+ }"
        line="${line#  }"

        # 브랜치 이름 추출 (첫 번째 단어)
        local branch
        branch=$(echo "$line" | awk '{print $1}')

        # 유효하지 않은 브랜치명 건너뛰기 (특수문자만 있는 경우 등)
        if [[ ! "$branch" =~ ^[a-zA-Z0-9] ]]; then
            continue
        fi

        [[ -z "$branch" ]] && continue

        # 현재 브랜치인 경우
        if [[ "$branch" == "$current_branch" ]]; then
            continue  # 현재 브랜치는 별도 표시
        fi

        # 보호 브랜치인 경우
        if is_protected "$branch"; then
            protected_branches+=("$branch")
            continue
        fi

        # gone 상태 확인 (원격 트래킹이 삭제됨)
        if echo "$line" | grep -q '\[.*: gone\]'; then
            # 원격 트래킹 정보 추출
            local remote_info
            remote_info=$(echo "$line" | grep -oE '\[[^]]+: gone\]' | tr -d '[]' | sed 's/: gone//')
            gone_branches+=("${branch}|${remote_info}")
            continue
        fi

        # 원격 트래킹이 있는 브랜치 (active)
        if echo "$line" | grep -qE '\[origin/'; then
            active_branches+=("$branch")
            continue
        fi

        # 원격 트래킹이 없는 로컬 전용 브랜치 - stale 여부 확인
        local commit_timestamp
        commit_timestamp=$(git log -1 --format=%ct "$branch" 2>/dev/null || echo "0")

        if [[ "$commit_timestamp" -lt "$stale_timestamp" ]]; then
            # stale 브랜치 - 경과 일수 계산
            local now_timestamp days_ago
            now_timestamp=$(date +%s)
            days_ago=$(( (now_timestamp - commit_timestamp) / 86400 ))
            stale_branches+=("${branch}|${days_ago}")
        else
            active_branches+=("$branch")
        fi
    done < <(git branch -vv)
}

display_branches() {
    local gone_count=${#gone_branches[@]}
    local stale_count=${#stale_branches[@]}

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🧹 Git Branch Cleanup"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # gone 브랜치 표시
    if [[ $gone_count -gt 0 ]]; then
        echo ""
        echo "── gone ($gone_count개) ──"
        for entry in "${gone_branches[@]}"; do
            IFS='|' read -r branch remote <<< "$entry"
            echo "  ✅ [gone] $branch ($remote)"
        done
    fi

    # stale 브랜치 표시
    if [[ $stale_count -gt 0 ]]; then
        echo ""
        echo "── stale ($stale_count개) ──"
        for entry in "${stale_branches[@]}"; do
            IFS='|' read -r branch days <<< "$entry"
            echo "  ⚠️ [stale] $branch (${days}일 경과)"
        done
    fi

    # 보호/현재 브랜치 표시
    if [[ ${#protected_branches[@]} -gt 0 || -n "$current_branch" ]]; then
        echo ""
        echo "── 보호됨 ──"
        for branch in "${protected_branches[@]}"; do
            echo "  🔒 $branch"
        done
        if [[ -n "$current_branch" ]]; then
            echo "  📍 $current_branch (현재)"
        fi
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [[ $gone_count -eq 0 && $stale_count -eq 0 ]]; then
        echo ""
        echo "✨ 정리할 브랜치가 없습니다."
    fi
}

delete_branch() {
    local branch="$1"

    # gone/stale 모두 -D로 강제 삭제
    # gone: 원격에서 이미 삭제됨 (PR 머지 후 삭제된 브랜치)
    # stale: 오래된 로컬 전용 브랜치
    if git branch -D "$branch" &>/dev/null; then
        echo "   ✅ 삭제됨: $branch"
    else
        echo "   ❌ 삭제 실패: $branch"
    fi
}

delete_all_gone() {
    local count=${#gone_branches[@]}
    if [[ $count -eq 0 ]]; then
        echo "삭제할 gone 브랜치가 없습니다."
        return
    fi

    echo -n "정말 ${count}개를 삭제하시겠습니까? [y/N]: "
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "❌ 취소되었습니다."
        return
    fi

    echo ""
    for entry in "${gone_branches[@]}"; do
        IFS='|' read -r branch _ <<< "$entry"
        delete_branch "$branch"
    done
}

delete_all_stale() {
    local count=${#stale_branches[@]}
    if [[ $count -eq 0 ]]; then
        echo "삭제할 stale 브랜치가 없습니다."
        return
    fi

    echo -n "정말 ${count}개를 삭제하시겠습니까? [y/N]: "
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "❌ 취소되었습니다."
        return
    fi

    echo ""
    for entry in "${stale_branches[@]}"; do
        IFS='|' read -r branch _ <<< "$entry"
        delete_branch "$branch"
    done
}

delete_interactive() {
    echo ""

    # gone 브랜치 순회
    for entry in "${gone_branches[@]}"; do
        IFS='|' read -r branch remote <<< "$entry"
        echo -n "$branch [gone] 삭제? [Y/n/q]: "
        read -r response
        response="${response:-y}"  # Enter = 기본값 y
        case "$response" in
            [Yy]) delete_branch "$branch" ;;
            [Nn]) echo "   ⏭️  건너뜀" ;;
            [Qq]) echo "❌ 중단됨"; return ;;
        esac
    done

    # stale 브랜치 순회
    for entry in "${stale_branches[@]}"; do
        IFS='|' read -r branch days <<< "$entry"
        echo -n "$branch [stale: ${days}일] 삭제? [Y/n/q]: "
        read -r response
        response="${response:-y}"
        case "$response" in
            [Yy]) delete_branch "$branch" ;;
            [Nn]) echo "   ⏭️  건너뜀" ;;
            [Qq]) echo "❌ 중단됨"; return ;;
        esac
    done

    echo ""
    echo "✅ 완료되었습니다."
}

show_menu() {
    local gone_count=${#gone_branches[@]}
    local stale_count=${#stale_branches[@]}

    echo ""
    echo "🗑️  삭제할 로컬 브랜치를 선택하세요:"

    # 0개인 옵션은 숨김
    if [[ $gone_count -gt 0 ]]; then
        echo "   [a] gone 상태 전체 삭제 (${gone_count}개)"
    fi
    if [[ $stale_count -gt 0 ]]; then
        echo "   [b] stale 상태 전체 삭제 (${stale_count}개)"
    fi
    echo "   [s] 하나씩 선택하여 삭제"
    echo "   [q] 취소"
    echo ""

    while true; do
        echo -n "선택: "
        read -r choice
        case "$choice" in
            a|A)
                if [[ $gone_count -gt 0 ]]; then
                    delete_all_gone
                    break
                else
                    echo "잘못된 선택입니다. 다시 선택하세요."
                fi
                ;;
            b|B)
                if [[ $stale_count -gt 0 ]]; then
                    delete_all_stale
                    break
                else
                    echo "잘못된 선택입니다. 다시 선택하세요."
                fi
                ;;
            s|S) delete_interactive; break ;;
            q|Q) echo "❌ 취소되었습니다."; break ;;
            *) echo "잘못된 선택입니다. 다시 선택하세요." ;;
        esac
    done
}

main() {
    check_git_repo
    fetch_and_prune
    collect_branches
    display_branches

    # 삭제 대상 없으면 종료
    if [[ ${#gone_branches[@]} -eq 0 && ${#stale_branches[@]} -eq 0 ]]; then
        exit 0
    fi

    # dry-run 모드면 여기서 종료
    if [[ "$DRY_RUN" == true ]]; then
        echo ""
        echo "ℹ️  --dry-run 모드: 실제 삭제 없이 종료합니다."
        exit 0
    fi

    show_menu
}

main
