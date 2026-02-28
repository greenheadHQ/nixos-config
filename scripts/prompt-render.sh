#!/usr/bin/env bash
set -euo pipefail

# prompt-render: preset 템플릿의 코드 블록을 추출하고 placeholder를 치환하여 출력/clipboard 복사
#
# Usage:
#   prompt-render.sh --preset <name-or-path> [--var KEY=VALUE ...] [--non-interactive] [--stdout-only] [--format text|json]
#   prompt-render.sh --list-presets [--format json]
#
# Exit codes (text 모드):
#   0 — 성공 (clipboard 실패 시에도 stdout 출력 성공이면 0)
#   1 — usage 오류 (--preset 미입력, 잘못된 인자, --var에 preset에 없는 키 전달)
#   2 — 누락 변수 (--non-interactive에서 미해결 placeholder 존재, 대화형에서 빈 입력)
#   3 — preset 미발견 (후보 목록 출력)
#
# JSON 모드 계약 (--format json):
#   항상 exit 0. 성공/실패는 JSON의 ok 필드로 판단.
#   stdout에 순수 JSON만 출력 (stderr 없음).
#   예외: 인자 파싱 에러(--var/--format 값 누락 등)는 jq 초기화 전에 발생하므로
#         text 모드와 동일하게 stderr + non-zero exit 반환. iOS Shortcut에서는
#         인자를 프로그래밍적으로 구성하므로 이 경로는 도달하지 않는다.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PRESETS_DIR="${PROMPT_PRESETS_DIR:-${SCRIPT_DIR}/prompts/presets}"

# --- 헬퍼 함수 ---

# 첫 번째 ```text``` 블록에서 템플릿 추출
_extract_template() {
  awk '/^```text$/{found++; next} found==1 && /^```$/{exit} found==1{print}' "$1"
}

# 템플릿에서 {PLACEHOLDER} 변수명 추출 (중괄호 포함, 정렬 + 중복 제거)
_extract_vars() {
  echo "$1" | grep -oE '\{[A-Z0-9_]+\}' | sort -u || true
}

# JSON 모드: 응답 생성 후 exit 0
_json_exit() {
  trap - ERR
  local ok="$1" preset_name="$2" rendered="$3" error_msg="$4"
  local missing_json="${5:-[]}" invalid_json="${6:-[]}"
  jq -nc \
    --argjson ok "$ok" \
    --arg preset "$preset_name" \
    --arg rendered "$rendered" \
    --argjson missing "$missing_json" \
    --argjson invalid "$invalid_json" \
    --arg error "$error_msg" \
    '{ok: $ok, preset: $preset, rendered: $rendered, missing: $missing, invalid: $invalid, error: $error}' \
    || echo '{"ok":false,"preset":"","rendered":"","missing":[],"invalid":[],"error":"json generation failed"}'
  exit 0
}

preset=""
declare -a var_keys=()
declare -a var_vals=()
non_interactive=false
stdout_only=false
format="text"
list_presets=false

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
    --format)
      [[ $# -lt 2 ]] && { echo "Error: --format requires a value" >&2; exit 1; }
      format="$2"; shift 2 ;;
    --list-presets)
      list_presets=true; shift ;;
    *)
      echo "Error: unknown argument: $1" >&2
      echo "Usage: prompt-render.sh --preset <name-or-path> [--var KEY=VALUE ...] [--non-interactive] [--stdout-only] [--format text|json]" >&2
      echo "       prompt-render.sh --list-presets [--format json]" >&2
      exit 1 ;;
  esac
done

if [[ "$format" != "text" && "$format" != "json" ]]; then
  echo "Error: --format must be 'text' or 'json', got: $format" >&2
  exit 1
fi

# --- JSON 모드 초기화 ---
if [[ "$format" == "json" ]]; then
  # jq 가용성 체크 (실제 실행으로 확인 — shadow jq 테스트와 호환)
  if ! jq --version &>/dev/null; then
    echo '{"ok":false,"preset":"","rendered":"","missing":[],"invalid":[],"error":"jq not found"}'
    exit 0
  fi
  set -E
  shopt -s inherit_errexit 2>/dev/null || true
  trap '_json_exit false "${preset:-}" "" "unexpected error"' ERR
fi

# --- --list-presets ---
if [[ "$list_presets" == true ]]; then
  presets=()
  if [[ -d "$PRESETS_DIR" ]]; then
    while IFS= read -r f; do
      presets+=("$(basename "$f" .md)")
    done < <(find "$PRESETS_DIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort)
  fi
  if [[ "$format" == "json" ]]; then
    if [[ ${#presets[@]} -gt 0 ]]; then
      printf '%s\n' "${presets[@]}" | jq -Rnc '[inputs] | {ok: true, presets: .}'
    else
      jq -nc '{ok: true, presets: []}'
    fi
    exit 0
  else
    if [[ ${#presets[@]} -gt 0 ]]; then
      printf '%s\n' "${presets[@]}"
    fi
    exit 0
  fi
fi

# --- --preset 필수 체크 ---
if [[ -z "$preset" ]]; then
  if [[ "$format" == "json" ]]; then
    _json_exit false "" "" "--preset is required"
  fi
  echo "Error: --preset is required" >&2
  echo "Usage: prompt-render.sh --preset <name-or-path> [--var KEY=VALUE ...] [--non-interactive] [--stdout-only] [--format text|json]" >&2
  exit 1
fi

# --- Preset 해석 ---
if [[ -f "$preset" ]]; then
  preset_file="$preset"
elif [[ -f "${PRESETS_DIR}/${preset}.md" ]]; then
  preset_file="${PRESETS_DIR}/${preset}.md"
else
  if [[ "$format" == "json" ]]; then
    _json_exit false "$preset" "" "preset not found: $preset"
  fi
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

# --- 코드 블록 추출 ---
template=$(_extract_template "$preset_file")

if [[ -z "$template" ]]; then
  if [[ "$format" == "json" ]]; then
    _json_exit false "$preset" "" "no text code block found in preset: $preset_file"
  fi
  echo "Error: no \`\`\`text code block found in preset: $preset_file" >&2
  exit 1
fi

# --- Placeholder 수집 ---
placeholders=$(_extract_vars "$template")

# --- --var 키 검증 ---
for i in "${!var_keys[@]}"; do
  key="${var_keys[$i]}"
  if [[ -z "$placeholders" ]] || ! echo "$placeholders" | grep -qF "{${key}}"; then
    if [[ "$format" == "json" ]]; then
      invalid_json=$(echo "$key" | jq -Rnc '[inputs]')
      _json_exit false "$preset" "" "invalid --var key '${key}' — not found in preset placeholders" "[]" "$invalid_json"
    fi
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
remaining=$(_extract_vars "$template")

if [[ -n "$remaining" ]]; then
  if [[ "$non_interactive" == true ]]; then
    missing=$(echo "$remaining" | sed 's/[{}]//g' | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')
    if [[ "$format" == "json" ]]; then
      missing_json=$(echo "$remaining" | sed 's/[{}]//g' | jq -Rnc '[inputs | select(length > 0)]')
      _json_exit false "$preset" "" "missing variables: $missing" "$missing_json" "[]"
    fi
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
if [[ "$format" == "json" ]]; then
  _json_exit true "$preset" "$template" ""
fi

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
