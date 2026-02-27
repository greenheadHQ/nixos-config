#!/usr/bin/env bash
set -euo pipefail

# prompt-render: preset 템플릿의 코드 블록을 추출하고 placeholder를 치환하여 출력/clipboard 복사
#
# Usage:
#   prompt-render.sh --preset <name-or-path> [--var KEY=VALUE ...] [--non-interactive] [--stdout-only]
#
# Exit codes:
#   0 — 성공 (clipboard 실패 시에도 stdout 출력 성공이면 0)
#   1 — usage 오류 (--preset 미입력, 잘못된 인자, --var에 preset에 없는 키 전달)
#   2 — 누락 변수 (--non-interactive에서 미해결 placeholder 존재, 대화형에서 빈 입력)
#   3 — preset 미발견 (후보 목록 출력)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PRESETS_DIR="${PROMPT_PRESETS_DIR:-${SCRIPT_DIR}/prompts/presets}"

preset=""
declare -a var_keys=()
declare -a var_vals=()
non_interactive=false
stdout_only=false

# --- 인자 파싱 ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --preset)
      [[ $# -lt 2 ]] && { echo "Error: --preset requires a value" >&2; exit 1; }
      preset="$2"; shift 2 ;;
    --var)
      [[ $# -lt 2 ]] && { echo "Error: --var requires KEY=VALUE" >&2; exit 1; }
      if [[ "$2" != *=* ]]; then
        echo "Error: --var format must be KEY=VALUE, got: $2" >&2; exit 1
      fi
      key="${2%%=*}"
      val="${2#*=}"
      if [[ -z "${val//[[:space:]]/}" ]]; then
        echo "Error: empty value for --var key '${key}'" >&2; exit 1
      fi
      var_keys+=("$key")
      var_vals+=("$val")
      shift 2 ;;
    --non-interactive)
      non_interactive=true; shift ;;
    --stdout-only)
      stdout_only=true; shift ;;
    *)
      echo "Error: unknown argument: $1" >&2
      echo "Usage: prompt-render.sh --preset <name-or-path> [--var KEY=VALUE ...] [--non-interactive] [--stdout-only]" >&2
      exit 1 ;;
  esac
done

if [[ -z "$preset" ]]; then
  echo "Error: --preset is required" >&2
  echo "Usage: prompt-render.sh --preset <name-or-path> [--var KEY=VALUE ...] [--non-interactive] [--stdout-only]" >&2
  exit 1
fi

# --- Preset 해석 ---
if [[ -f "$preset" ]]; then
  preset_file="$preset"
elif [[ -f "${PRESETS_DIR}/${preset}.md" ]]; then
  preset_file="${PRESETS_DIR}/${preset}.md"
else
  echo "Error: preset not found: $preset" >&2
  echo "" >&2
  echo "Available presets:" >&2
  if [[ -d "$PRESETS_DIR" ]]; then
    find "$PRESETS_DIR" -maxdepth 1 -type f -name '*.md' -exec basename {} .md \; 2>/dev/null | sort | sed 's/^/  /' >&2
  else
    echo "  (preset directory not found: $PRESETS_DIR)" >&2
  fi
  exit 3
fi

# --- 코드 블록 추출 (첫 번째 ```text``` 블록만) ---
template=$(awk '/^```text$/{found++; next} found==1 && /^```$/{exit} found==1{print}' "$preset_file")

if [[ -z "$template" ]]; then
  echo "Error: no \`\`\`text code block found in preset: $preset_file" >&2
  exit 1
fi

# --- Placeholder 수집 ---
placeholders=$(echo "$template" | grep -oE '\{[A-Z0-9_]+\}' | sort -u || true)

# --- --var 키 검증 ---
for i in "${!var_keys[@]}"; do
  key="${var_keys[$i]}"
  if [[ -z "$placeholders" ]] || ! echo "$placeholders" | grep -qF "{${key}}"; then
    echo "Error: invalid --var key '${key}' — not found in preset placeholders" >&2
    if [[ -n "$placeholders" ]]; then
      echo "Valid placeholders: $(echo "$placeholders" | tr '\n' ' ')" >&2
    else
      echo "This preset has no placeholders" >&2
    fi
    exit 1
  fi
done

# --- --var로 전달된 키를 먼저 치환 ---
# bash 5.x의 patsub_replacement 안전 치환 (& 문자 보호)
shopt -u patsub_replacement 2>/dev/null || true

for i in "${!var_keys[@]}"; do
  key="${var_keys[$i]}"
  val="${var_vals[$i]}"
  template="${template//\{${key}\}/${val}}"
done

# --- 미해결 변수 처리 ---
remaining=$(echo "$template" | grep -oE '\{[A-Z0-9_]+\}' | sort -u || true)

if [[ -n "$remaining" ]]; then
  if [[ "$non_interactive" == true ]]; then
    missing=$(echo "$remaining" | sed 's/[{}]//g' | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')
    echo "Error: missing variables: $missing" >&2
    exit 2
  fi

  # 대화형 입력
  echo "Variables to fill:" >&2
  while IFS= read -r placeholder; do
    [[ -z "$placeholder" ]] && continue
    key="${placeholder//[\{\}]/}"
    read -rp "  {${key}}: " value </dev/tty
    if [[ -z "${value// /}" ]]; then
      echo "Error: empty value for {${key}}" >&2
      exit 2
    fi
    template="${template//\{${key}\}/${value}}"
  done <<< "$remaining"
fi

# --- 출력 ---
printf '%s\n' "$template"

# --- Clipboard ---
if [[ "$stdout_only" == true ]]; then
  exit 0
fi

clipboard_cmd=""
if command -v pbcopy &>/dev/null; then
  clipboard_cmd="pbcopy"
elif command -v wl-copy &>/dev/null; then
  clipboard_cmd="wl-copy"
elif command -v xclip &>/dev/null; then
  clipboard_cmd="xclip -selection clipboard"
fi

if [[ -n "$clipboard_cmd" ]]; then
  if printf '%s\n' "$template" | $clipboard_cmd 2>/dev/null; then
    echo "✓ clipboard에 복사됨" >&2
  else
    echo "⚠ clipboard 복사 실패 (stdout 출력은 정상)" >&2
  fi
else
  echo "⚠ clipboard 도구 없음 (pbcopy/wl-copy/xclip) — stdout 출력만 수행" >&2
fi
