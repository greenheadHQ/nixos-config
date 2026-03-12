#!/usr/bin/env bash
set -euo pipefail

# cheat + fzf 브라우징 (title/content 모드 전환)
# 사용처: tmux prefix+C (display-popup), nvim <leader>C (Snacks.terminal), 터미널 직접 실행
#
# display-popup 셸의 PATH 불완전 방지를 위해 절대 경로 resolve
cheat_cmd="$(command -v cheat 2>/dev/null || echo cheat)"
fzf_cmd="$(command -v fzf 2>/dev/null || echo fzf)"

# SELF: 배포 환경(~/.local/bin)과 개발 환경(worktree 직접 실행) 모두 지원
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# --preview TITLE: cheatsheet 내용을 구문 강조하여 출력
# 섹션 헤더 → bold cyan, 키바인딩 → bold yellow, 설명/본문 → 기본색
if [[ "${1:-}" == "--preview" ]]; then
  "$cheat_cmd" "${2:?title required}" 2>/dev/null | awk '
    /^[^[:space:]]/ && NF > 0 {
      printf "\033[1;36m%s\033[0m\n", $0; next
    }
    /^[[:space:]]+[^[:space:]]/ {
      n = match($0, /[^[:space:]]/)
      indent = substr($0, 1, n - 1)
      rest = substr($0, n)
      m = match(rest, /  /)
      if (m > 0) {
        printf "%s\033[1;33m%s\033[0m%s\n", indent, substr(rest, 1, m - 1), substr(rest, m)
      } else { print }
      next
    }
    { print }
  '
  exit 0
fi

# --preview-prompt FILE: preset markdown을 구문 강조하여 출력
# CIR: 프리뷰는 프리셋 고유 내용 + 모듈 목록만 표시 — 합성 전체(수백 줄)는 브라우징에 부적합
# frontmatter에서 모듈 목록을 추출하여 상단에 표시한 뒤, 프리셋 고유 내용만 출력
# 헤더 → bold cyan, blockquote → dim, 코드 펜스 → dim, {PLACEHOLDER} → bold yellow
if [[ "${1:-}" == "--preview-prompt" ]]; then
  file="${2:?file required}"
  # 모듈 목록 추출 (frontmatter)
  modules=$(awk '
    NR==1 && /^---[[:space:]]*$/ { in_fm=1; next }
    in_fm && /^---[[:space:]]*$/ { exit }
    in_fm && /^modules:/ { in_mod=1; next }
    in_mod && /^[[:space:]]*-[[:space:]]+/ {
      sub(/^[[:space:]]*-[[:space:]]+/, "")
      sub(/[[:space:]]*$/, "")
      printf "%s", (mod_count++ > 0 ? ", " : "") $0
      next
    }
    in_mod { exit }
  ' "$file" 2>/dev/null)
  # 모듈 목록 표시
  if [[ -n "$modules" ]]; then
    printf '\033[2m━━ 포함 모듈 ━━\033[0m\n'
    printf '\033[1;36m%s\033[0m\n' "$modules"
    printf '\033[2m━━━━━━━━━━━━━━━\033[0m\n\n'
  fi
  # frontmatter 이후 내용만 출력 (구문 강조)
  awk '
    NR==1 && /^---[[:space:]]*$/ { in_fm=1; next }
    in_fm && /^---[[:space:]]*$/ { in_fm=0; next }
    in_fm { next }
    /^```/ {
      printf "\033[2m%s\033[0m\n", $0
      in_code = !in_code; next
    }
    in_code {
      line = $0; result = ""
      while (match(line, /\{[A-Z0-9_]+\}/)) {
        result = result substr(line, 1, RSTART-1) "\033[1;33m" substr(line, RSTART, RLENGTH) "\033[0m"
        line = substr(line, RSTART + RLENGTH)
      }
      print result line; next
    }
    /^# / { printf "\033[1;36m%s\033[0m\n", $0; next }
    /^>/ { printf "\033[2m%s\033[0m\n", $0; next }
    { print }
  ' "$file" 2>/dev/null
  exit 0
fi

# --content: 모든 시트 내용을 title\t내용줄 형태로 출력
if [[ "${1:-}" == "--content" ]]; then
  "$cheat_cmd" -l | awk 'NR>1 {print $1}' | while read -r title; do
    "$cheat_cmd" "$title" 2>/dev/null | while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      printf '%s\t%s\n' "$title" "$line"
    done || true
  done
  exit 0
fi

# --toggle STATE_FILE: 상태 파일 기반 모드 전환 fzf 액션 출력
if [[ "${1:-}" == "--toggle" ]]; then
  state_file="${2:?STATE_FILE required}"
  if [[ "$(cat "$state_file")" == "title" ]]; then
    echo "content" > "$state_file"
    echo "reload($SELF --content)+change-header(  [content 모드] Ctrl-S: title 모드 전환)+change-prompt(content> )+change-nth(..)"
  else
    echo "title" > "$state_file"
    echo "reload($cheat_cmd -l | awk 'NR>1 {print \$1}')+change-header(  [title 모드] Ctrl-S: content 모드 전환)+change-prompt(title> )+change-nth(..)"
  fi
  exit 0
fi

# --prompts: prompt preset 브라우저
if [[ "${1:-}" == "--prompts" ]]; then
  presets_dir="${PROMPT_PRESETS_DIR:?PROMPT_PRESETS_DIR not set}"
  [[ -d "$presets_dir" ]] || { echo "Error: preset dir not found: $presets_dir" >&2; exit 1; }
  prompt_render_cmd="$(command -v prompt-render 2>/dev/null || echo "$HOME/.local/bin/prompt-render")"
  [[ -x "$prompt_render_cmd" ]] || { echo "Error: prompt-render not found. Is the Nix config applied?" >&2; exit 1; }
  selected="" fzf_rc=0
  selected=$(find "$presets_dir" -maxdepth 1 -type f -name '*.md' -exec basename {} .md \; 2>/dev/null \
    | sort \
    | "$fzf_cmd" \
        --ansi \
        --header "  [prompt presets] Enter: 렌더 실행" \
        --prompt "preset> " \
        --preview "$SELF --preview-prompt '${presets_dir}'/{}.md" \
        --preview-window=right:70%) || fzf_rc=$?
  # fzf exit: 0=선택, 1=no match, 130=Ctrl-C → 정상 종료; 그 외 → 오류 전파
  if [[ $fzf_rc -ne 0 && $fzf_rc -ne 1 && $fzf_rc -ne 130 ]]; then exit "$fzf_rc"; fi
  [[ -z "$selected" ]] && exit 0

  # CIR: 변수 없는 프리셋은 즉시 렌더링 — fzf 세션 재진입 없이 원클릭 완료
  render_output="" render_rc=0
  render_output=$("$prompt_render_cmd" --preset "$selected" --non-interactive --stdout-only 2>/dev/null) || render_rc=$?
  if [[ $render_rc -eq 0 ]]; then
    # 변수 없거나 모두 기본값으로 해결됨 → 바로 클립보드 복사
    clipboard_cmd=""
    if command -v pbcopy &>/dev/null; then clipboard_cmd="pbcopy"
    elif command -v wl-copy &>/dev/null; then clipboard_cmd="wl-copy"
    elif command -v xclip &>/dev/null; then clipboard_cmd="xclip -selection clipboard"
    fi
    if [[ -n "$clipboard_cmd" ]] && printf '%s\n' "$render_output" | $clipboard_cmd 2>/dev/null; then
      echo "✓ 클립보드 복사 완료: $selected"
    else
      printf '%s\n' "$render_output"
      echo "⚠ 클립보드 복사 실패 — stdout 출력: $selected" >&2
    fi
    exit 0
  fi

  # 변수 필요 (exit 2) → 대화형 UI로 전환
  exec "$prompt_render_cmd" --preset "$selected"
fi

# 기본: fzf 브라우저 실행
state_file="$(mktemp)"
echo "title" > "$state_file"
trap 'rm -f "$state_file"' EXIT

"$cheat_cmd" -l | awk 'NR>1 {print $1}' | "$fzf_cmd" \
  --ansi \
  --header "  [title 모드] Ctrl-S: content 모드 전환" \
  --prompt "title> " \
  --preview "$SELF --preview {1}" \
  --preview-window=right:70% \
  --bind "enter:become($SELF --preview {1} | less -FRX)" \
  --bind "ctrl-s:transform:$SELF --toggle $state_file"
