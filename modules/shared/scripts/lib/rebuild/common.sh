# shellcheck shell=bash
log_info() { echo -e "${GREEN}$1${NC}"; }
log_warn() { echo -e "${YELLOW}$1${NC}"; }
log_error() { echo -e "${RED}$1${NC}"; }

#───────────────────────────────────────────────────────────────────────────────
# Worktree 감지: 현재 디렉토리가 FLAKE_PATH 저장소의 worktree이면 FLAKE_PATH 전환
# source 시점에 실행 (main()의 cd "$FLAKE_PATH"보다 먼저)
# 심링크 타깃(nixosConfigPath)은 항상 메인 레포 — 여기서는 flake 빌드 경로만 전환
#───────────────────────────────────────────────────────────────────────────────
detect_worktree() {
    local git_toplevel
    git_toplevel=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
    [[ "$git_toplevel" == "$FLAKE_PATH" ]] && return 0

    # worktree의 git-common-dir이 메인 레포의 .git을 가리키는지 검증
    local git_common_dir
    git_common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || return 0
    local abs_common_dir
    abs_common_dir=$(cd "$git_common_dir" 2>/dev/null && pwd) || return 0
    [[ "$abs_common_dir" != "${FLAKE_PATH}/.git" ]] && return 0

    log_warn "⚠️  Worktree detected: $git_toplevel"
    FLAKE_PATH="$git_toplevel"
}

#───────────────────────────────────────────────────────────────────────────────
# mkOutOfStoreSymlink 엔트리 추출 (awk 단일 파서, 매치 없어도 항상 exit 0)
# 사용: extract_oos_entries "main:path/to.nix"  (git show)
#       extract_oos_entries "/abs/path/to.nix"   (파일시스템)
# DA Fix #1: grep|grep 파이프라인은 매치 없을 때 exit 1 → set -euo pipefail 하에서 nrs abort.
#            awk 단일 파서로 전환하여 항상 exit 0 보장.
# DA Fix R2-2: .mkOutOfStoreSymlink 패턴으로 문자열 리터럴 내 오탐 방지 + trailing comment strip.
#───────────────────────────────────────────────────────────────────────────────
extract_oos_entries() {
    local source="$1"
    local content

    if [[ "$source" == *:* ]]; then
        content=$(git -C "$FLAKE_PATH" show "$source" 2>/dev/null) || return 0
    else
        [[ -f "$source" ]] || return 0
        content=$(cat "$source") || return 0
    fi

    printf '%s\n' "$content" | awk '
        /^[[:space:]]*#/ { next }
        /\.mkOutOfStoreSymlink[[:space:]]/ {
            sub(/;[[:space:]]*#.*$/, "")
            sub(/.*\.mkOutOfStoreSymlink[[:space:]]*/, "")
            sub(/;[[:space:]]*$/, "")
            if ($0 != "") print
        }
    ' | sort -u
}

#───────────────────────────────────────────────────────────────────────────────
# 인수 파싱 (OFFLINE_FLAG, FORCE_FLAG, CORES_FLAG 설정)
#───────────────────────────────────────────────────────────────────────────────
# shellcheck disable=SC2034  # Public flags are consumed by callers/helpers after parse_args.
parse_args() {
    OFFLINE_FLAG=""
    FORCE_FLAG=false
    CORES_FLAG=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --offline) OFFLINE_FLAG="--offline" ;;
            --force)   FORCE_FLAG=true ;;
            --cores)
                [[ -z "${2:-}" || "$2" =~ ^-- ]] && { log_error "--cores requires a number"; exit 1; }
                [[ ! "$2" =~ ^[0-9]+$ ]] && { log_error "--cores: positive integer required"; exit 1; }
                (( 10#$2 < 1 )) && { log_error "--cores: positive integer required"; exit 1; }
                CORES_FLAG="--cores $2"; shift ;;
            *) log_error "Unknown argument: $1"; exit 1 ;;
        esac
        shift
    done
}
