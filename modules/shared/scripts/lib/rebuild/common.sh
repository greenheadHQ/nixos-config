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
# Retired Codex hooks cleanup: 기존 worktree/checkout에 남은 repo-local hook
# 산출물과 알려진 user-level legacy hook entry를 rebuild 전에 정리한다.
#───────────────────────────────────────────────────────────────────────────────
_source_codex_legacy_hooks_helper() {
    declare -F codex_clear_retired_hook_artifacts >/dev/null && return 0

    local helper
    local -a candidates=()
    if [[ -n "${REBUILD_COMMON_LIB_DIR:-}" ]]; then
        candidates+=("$REBUILD_COMMON_LIB_DIR/codex-legacy-hooks.sh")
    fi
    candidates+=("$FLAKE_PATH/modules/shared/scripts/lib/rebuild/codex-legacy-hooks.sh")

    for helper in "${candidates[@]}"; do
        [[ -n "$helper" && -f "$helper" ]] || continue
        # shellcheck source=/dev/null
        source "$helper"
        declare -F codex_clear_retired_hook_artifacts >/dev/null && return 0
    done

    log_error "Codex legacy hook cleanup helper not found"
    return 1
}

_clear_retired_codex_hook_artifacts() {
    _source_codex_legacy_hooks_helper
    codex_clear_retired_hook_artifacts "$FLAKE_PATH" "$HOME"
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
# --help는 usage 출력 후 exit 0 — LLM/사용자가 사용법을 실행으로 발견할 수 있게 한다 (#1138).
#───────────────────────────────────────────────────────────────────────────────
_print_rebuild_usage() {
    # 진입점이 REBUILD_MODE=preview를 선언하면 (nrp) 실동작 없는 --force를
    # usage와 parser 양쪽에서 제외한다 (darwin nrp: NO_CHANGES 분기 없음,
    # nixos nrp: 항상 --warn-only). 배열 원소 하나 = 출력 행 하나.
    local mode="${REBUILD_MODE:-switch}"
    local synopsis desc
    local -a option_lines=('  --offline    오프라인 rebuild (substituter 미사용, 빠름)')
    if [[ "$mode" == "preview" ]]; then
        synopsis="[--offline] [--cores N]"
        desc="${REBUILD_CMD} preview wrapper (switch 없음)"
    else
        synopsis="[--offline] [--force] [--cores N]"
        desc="${REBUILD_CMD} wrapper (preview 포함)"
        option_lines+=('  --force      NO_CHANGES 스킵 우회 (darwin) / 소스 빌드 경고 무시 (nixos)')
    fi
    option_lines+=('  --cores N    빌드 코어 수 제한' '  -h, --help   이 도움말 출력 후 종료')
    printf 'Usage: %s %s\n\n%s\n\nOptions:\n' "${0##*/}" "$synopsis" "$desc"
    printf '%s\n' "${option_lines[@]}"
}

# shellcheck disable=SC2034  # Public flags are consumed by callers/helpers after parse_args.
parse_args() {
    OFFLINE_FLAG=""
    FORCE_FLAG=false
    CORES_FLAG=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --offline) OFFLINE_FLAG="--offline" ;;
            --force)
                # preview 진입점에서는 무동작 인터페이스이므로 usage와 동일하게 거부한다.
                if [[ "${REBUILD_MODE:-switch}" == "preview" ]]; then
                    log_error "--force is not supported by ${0##*/} (preview mode)" >&2
                    _print_rebuild_usage >&2
                    exit 1
                fi
                FORCE_FLAG=true ;;
            --cores)
                [[ -z "${2:-}" || "$2" =~ ^-- ]] && { log_error "--cores requires a number"; exit 1; }
                [[ ! "$2" =~ ^[0-9]+$ ]] && { log_error "--cores: positive integer required"; exit 1; }
                (( 10#$2 < 1 )) && { log_error "--cores: positive integer required"; exit 1; }
                CORES_FLAG="--cores $2"; shift ;;
            -h|--help) _print_rebuild_usage; exit 0 ;;
            *) log_error "Unknown argument: $1" >&2; _print_rebuild_usage >&2; exit 1 ;;
        esac
        shift
    done
}
