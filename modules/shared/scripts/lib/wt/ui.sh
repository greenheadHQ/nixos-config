# shellcheck shell=bash
_has_fzf() { command -v fzf &>/dev/null; }

# 비대화형 여부: WT_NONINTERACTIVE가 set이거나 stdin이 tty가 아니면 비대화형.
# LLM/스크립트/파이프(예: claude Bash tool)에서 fzf·read 프롬프트가 hang하거나
# EOF로 빈 입력을 받아 의도와 다르게 자동 취소되는 것을 막는 게이트.
_wt_interactive() {
  [[ -z "${WT_NONINTERACTIVE:-}" ]] && [[ -t 0 ]]
}

# worktree 내부에서도 항상 main repo root를 정확히 찾음
_get_repo_root() {
  local common_dir
  common_dir="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
  # common_dir: main repo → ".git" (상대), worktree → "/repo/.git" (절대)
  # 어느 경우든 dirname이 repo root를 반환
  (cd "$(dirname "$common_dir")" && pwd -P)
}

# 브랜치명을 디렉토리명으로 변환 (슬래시 → 언더스코어)
_sanitize_name() {
  echo "${1//\//_}"
}

# 커밋 타임스탬프 → 상대 시간 (2d, 1w 등)
_relative_age() {
  local timestamp="$1"
  local now
  now=$(date +%s)
  local diff=$(( now - timestamp ))

  if (( diff < 3600 )); then
    echo "$((diff / 60))m"
  elif (( diff < 86400 )); then
    echo "$((diff / 3600))h"
  elif (( diff < 604800 )); then
    echo "$((diff / 86400))d"
  elif (( diff < 2592000 )); then
    echo "$((diff / 604800))w"
  else
    echo "$((diff / 2592000))mo"
  fi
}

_die() {
  echo "error: $*" >&2
  exit 1
}

# CIR: echo → printf ANSI 선택 — echo "$*"는 간결하지만 스타일링 불가.
#   printf + 인라인 ANSI가 외부 TUI 바이너리 fork 없이 즉시 출력되어 가장 효율적.
_info() {
  printf '\033[38;5;179m› \033[38;5;245m%s\033[0m\n' "$*" >&2
}

_warn() {
  printf '\033[38;5;215m! \033[38;5;245m%s\033[0m\n' "$*" >&2
}

# y/N 확인 프롬프트
# 비대화형: WT_ASSUME_YES(--yes로 set)면 승인, 아니면 안전하게 거부 + 안내.
_confirm() {
  local msg="$1"
  [[ -n "${WT_ASSUME_YES:-}" ]] && return 0
  if ! _wt_interactive; then
    _warn "비대화형: 확인 필요 — '$msg'. 승인하려면 --yes (또는 WT_ASSUME_YES=1)."
    return 1
  fi
  printf "%s (y/N): " "$msg" >&2
  local yn
  read -r yn
  [[ "$yn" =~ ^[yY] ]]
}

# 단일 선택 (대화형 전용: fzf 또는 번호 입력)
# 비대화형에서는 선택 불가 → 호출자가 명시 플래그로 결정해야 한다(예: create의 --if-exists).
_choose() {
  local header="${1:-선택}"
  shift
  local options=("$@")

  if ! _wt_interactive; then
    _warn "비대화형: '$header' 선택 불가 — 명시 플래그(예: --if-exists)로 결정하세요."
    return 1
  fi

  if _has_fzf; then
    printf '%s\n' "${options[@]}" | fzf --no-multi --height ~$((${#options[@]} + 4)) \
      --prompt "선택> " --header "$header"
  else
    echo "$header:" >&2
    local i=1
    for opt in "${options[@]}"; do
      echo "  $i) $opt" >&2
      ((i++))
    done
    printf '번호 [1-%s]: ' "${#options[@]}" >&2
    local choice_num
    read -r choice_num
    if [[ "$choice_num" =~ ^[0-9]+$ ]] && (( choice_num >= 1 && choice_num <= ${#options[@]} )); then
      echo "${options[$((choice_num - 1))]}"
    else
      return 1
    fi
  fi
}
