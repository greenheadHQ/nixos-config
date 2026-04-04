# shellcheck shell=bash
_has_fzf() { command -v fzf &>/dev/null; }
_has_gum() { command -v gum &>/dev/null; }

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
#   gum style은 표시 전용에는 적합하나 매 호출마다 프로세스 fork 부담.
#   printf + 인라인 ANSI가 fork 없이 즉시 출력되어 가장 효율적.
_info() {
  printf '\033[38;5;179m› \033[38;5;245m%s\033[0m\n' "$*" >&2
}

_warn() {
  printf '\033[38;5;215m! \033[38;5;245m%s\033[0m\n' "$*" >&2
}

# y/N 확인 프롬프트 (gum confirm 대체)
_confirm() {
  local msg="$1"
  printf "%s (y/N): " "$msg" >&2
  local yn
  read -r yn
  [[ "$yn" =~ ^[yY] ]]
}

# 단일 선택 (fzf 사용, fallback: 번호 선택)
_choose() {
  local header="${1:-선택}"
  shift
  local options=("$@")

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
