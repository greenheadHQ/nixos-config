#!/usr/bin/env bash
set -euo pipefail

# prompt-render: preset 템플릿의 코드 블록을 추출하고 placeholder를 치환하여 출력/clipboard 복사
#
# Usage:
#   prompt-render.sh --preset <name-or-path> [--var KEY=VALUE ...] [--non-interactive] [--stdout-only] [--format text|json]
#   prompt-render.sh --list-presets [--format json]
#   prompt-render.sh --validate <name-or-path>
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
SELF="${SCRIPT_DIR}/$(basename "$0")"
PRESETS_DIR="${PROMPT_PRESETS_DIR:-${SCRIPT_DIR}/prompts/presets}"
# MODULES_DIR은 preset_file 해석 후 동적 결정 (아래 "Preset 해석" 섹션 참조)

# ============================================================================
# 내부 서브커맨드 (fzf 콜백용)
# ============================================================================

# __render_list VAR_FILE META_FILE — 변수 목록을 fzf 표시용으로 출력
if [[ "${1:-}" == "__render_list" ]]; then
  var_file="$2" meta_file="$3"
  while IFS='=' read -r key val; do
    [[ -z "$key" ]] && continue
    desc=""
    while IFS='|' read -r mn md _mo _mdf; do
      if [[ "$mn" == "$key" ]]; then desc="$md"; break; fi
    done < "$meta_file"
    if [[ -n "$val" ]]; then status="✓"; else status="…"; fi
    printf '%-20s = %-30s  %s  %s\n' "$key" "${val:-(미설정)}" "$status" "${desc:+($desc)}"
  done < "$var_file"
  exit 0
fi

# __edit_var VAR_FILE META_FILE KEY — 개별 변수 편집 (중첩 fzf 또는 read)
if [[ "${1:-}" == "__edit_var" ]]; then
  var_file="$2" meta_file="$3" key="$4"
  desc="" opts="" def=""
  while IFS='|' read -r mn md mo mdf; do
    if [[ "$mn" == "$key" ]]; then
      desc="$md"; opts="$mo"; def="$mdf"; break
    fi
  done < "$meta_file"
  # 현재 값
  current=""
  while IFS='=' read -r k v; do
    if [[ "$k" == "$key" ]]; then current="$v"; break; fi
  done < "$var_file"
  # options가 있으면 fzf로 선택
  if [[ -n "$opts" ]]; then
    header="${key}"
    [[ -n "$desc" ]] && header+=" — ${desc}"
    new_val=$(fzf --height=10 --header="$header" --prompt="선택> " --no-sort < <(echo "$opts" | tr ',' '\n')) || exit 0
  else
    prompt="${key}"
    [[ -n "$desc" ]] && prompt+=" ($desc)"
    prompt+=": "
    printf '%s' "$prompt" >/dev/tty
    read -re -i "${current:-$def}" new_val </dev/tty
  fi
  [[ -z "$new_val" ]] && exit 0
  # 값 업데이트
  tmpf="$(mktemp)"
  while IFS='=' read -r k v; do
    if [[ "$k" == "$key" ]]; then echo "${k}=${new_val}"; else echo "${k}=${v}"; fi
  done < "$var_file" > "$tmpf"
  mv "$tmpf" "$var_file"
  exit 0
fi

# __preview VAR_FILE TPL_FILE — 현재 변수 값으로 치환한 템플릿 프리뷰
if [[ "${1:-}" == "__preview" ]]; then
  var_file="$2" tpl_file="$3"
  # CIR: 본 렌더 경로와 동일한 & 문자 안전 치환 적용 — preview/render 불일치 방지
  shopt -u patsub_replacement 2>/dev/null || true
  result="$(cat "$tpl_file")"
  while IFS='=' read -r key val; do
    [[ -z "$key" || -z "$val" ]] && continue
    result="${result//\{${key}\}/${val}}"
  done < "$var_file"
  printf '%s\n' "$result"
  exit 0
fi

# ============================================================================
# 헬퍼 함수
# ============================================================================

# 첫 번째 ```text``` 블록에서 템플릿 추출
_extract_template() {
  awk '/^```text$/{found++; next} found==1 && /^```$/{exit} found==1{print}' "$1"
}

# 템플릿에서 {PLACEHOLDER} 변수명 추출 (중괄호 포함, 정렬 + 중복 제거)
_extract_vars() {
  echo "$1" | grep -oE '\{[A-Z0-9_]+\}' | sort -u || true
}

# ```vars``` 블록에서 변수 메타데이터 추출 (NAME|desc|options|default 형식)
_extract_vars_meta() {
  awk '/^```vars[[:space:]]*$/{found=1; next} found && /^```$/{exit} found{print}' "$1"
}

# 템플릿에서 변수가 등장하는 첫 줄을 추출, 대상 변수를 ___로, 다른 {VAR}를 변수명으로 치환
_extract_var_context() {
  local template="$1" var_name="$2"
  echo "$template" | grep -m1 -F "{${var_name}}" \
    | sed "s/{${var_name}}/___/g" \
    | sed 's/{\([A-Z0-9_]*\)}/\1/g'
}

# CIR: YAML frontmatter 파싱 — 순수 awk. yq 의존성 없이 고정된 modules: 배열만 추출.
_extract_frontmatter_modules() {
  awk '
    NR==1 && /^---[[:space:]]*$/ { in_fm=1; next }
    in_fm && /^---[[:space:]]*$/ { exit }
    in_fm && /^modules:/ { in_mod=1; next }
    in_mod && /^[[:space:]]*-[[:space:]]+/ {
      sub(/^[[:space:]]*-[[:space:]]+/, "")
      sub(/[[:space:]]*$/, "")
      print
      next
    }
    in_mod { exit }
  ' "$1"
}

# CIR: 모듈 조합 — modules 디렉토리에서 각 모듈의 ```text``` 블록을 순서대로 합성
_compose_modules() {
  local modules_str="$1"
  [[ -z "$modules_str" ]] && return 0
  while IFS= read -r mod; do
    [[ -z "$mod" ]] && continue
    local mod_file="${MODULES_DIR}/${mod}.md"
    if [[ ! -f "$mod_file" ]]; then
      echo "Error: module not found: ${mod} (${mod_file})" >&2
      return 1
    fi
    _extract_template "$mod_file"
    echo ""
  done <<< "$modules_str"
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

# ============================================================================
# 인자 파싱
# ============================================================================

preset=""
declare -a var_keys=()
declare -a var_vals=()
non_interactive=false
stdout_only=false
format="text"
list_presets=false
validate_mode=false

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
    --validate)
      validate_mode=true
      if [[ $# -ge 2 && "${2:0:1}" != "-" ]]; then
        preset="$2"; shift 2
      else
        shift
      fi
      ;;
    *)
      echo "Error: unknown argument: $1" >&2
      echo "Usage: prompt-render.sh --preset <name-or-path> [--var KEY=VALUE ...] [--non-interactive] [--stdout-only] [--format text|json]" >&2
      echo "       prompt-render.sh --list-presets [--format json]" >&2
      echo "       prompt-render.sh --validate <name-or-path>" >&2
      exit 1 ;;
  esac
done

if [[ "$format" != "text" && "$format" != "json" ]]; then
  echo "Error: --format must be 'text' or 'json', got: $format" >&2
  exit 1
fi

# ============================================================================
# JSON 모드 초기화
# ============================================================================

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

# ============================================================================
# --list-presets
# ============================================================================

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

# ============================================================================
# --preset / --validate 필수 체크
# ============================================================================

if [[ -z "$preset" ]]; then
  if [[ "$format" == "json" ]]; then
    _json_exit false "" "" "--preset is required"
  fi
  echo "Error: --preset is required" >&2
  echo "Usage: prompt-render.sh --preset <name-or-path> [--var KEY=VALUE ...] [--non-interactive] [--stdout-only] [--format text|json]" >&2
  exit 1
fi

# ============================================================================
# Preset 해석
# ============================================================================

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

# CIR: modules/ 경로는 실제 preset 파일 위치의 형제 디렉토리로 결정
# — name 기반(PRESETS_DIR 해석)이든 path 기반(직접 지정)이든 동일 로직
# 기존: PRESETS_DIR 고정 → 외부 path preset에서 module not found 발생
MODULES_DIR="$(cd "$(dirname "$preset_file")/.." 2>/dev/null && pwd)/modules"

# ============================================================================
# YAML frontmatter 파싱 + 모듈 조합
# ============================================================================

frontmatter_modules=$(_extract_frontmatter_modules "$preset_file")
preset_template=$(_extract_template "$preset_file")
vars_meta=$(_extract_vars_meta "$preset_file")

# 모듈 텍스트 조합 + 프리셋 텍스트 합성
module_text=""
if [[ -n "$frontmatter_modules" ]]; then
  _compose_errfile="$(mktemp)"
  module_text=$(_compose_modules "$frontmatter_modules" 2>"$_compose_errfile") || {
    _compose_err="$(cat "$_compose_errfile")"
    rm -f "$_compose_errfile"
    # CIR: validate 모드에서는 여기서 hard-fail하지 않고 validate 경로로 넘김
    # — validate는 자체 module 존재 확인이 있으므로, 일관된 {ok, errors, warnings} 스키마 유지
    if [[ "$validate_mode" != true ]]; then
      if [[ "$format" == "json" ]]; then
        _json_exit false "$preset" "" "${_compose_err:-module composition failed}"
      fi
      [[ -n "$_compose_err" ]] && printf '%s\n' "$_compose_err" >&2
      exit 1
    fi
  }
  rm -f "$_compose_errfile"
fi

if [[ -n "$module_text" && -n "$preset_template" ]]; then
  template="${module_text}
${preset_template}"
elif [[ -n "$module_text" ]]; then
  template="$module_text"
elif [[ -n "$preset_template" ]]; then
  template="$preset_template"
else
  # CIR: validate 모드에서는 조기 종료하지 않고 validate 섹션으로 위임
  # — 모듈 조합 실패 시 여기서 "no text block" 에러로 종료하면
  #   validate 섹션의 "module not found" 검사에 도달하지 못함
  if [[ "$validate_mode" == true ]]; then
    template=""
  else
    if [[ "$format" == "json" ]]; then
      _json_exit false "$preset" "" "no text code block found in preset: $preset_file"
    fi
    echo "Error: no \`\`\`text code block found in preset: $preset_file" >&2
    exit 1
  fi
fi

# ============================================================================
# --validate 모드
# ============================================================================

if [[ "$validate_mode" == true ]]; then
  errors=0
  declare -a error_msgs=()
  declare -a warn_msgs=()

  # 0. 빈 template 경고 (모듈 조합 실패로 인해 도달 가능)
  if [[ -z "$template" ]]; then
    error_msgs+=("no text content — module composition may have failed")
    errors=$((errors + 1))
  fi

  # 1. frontmatter modules 존재 및 내용 확인
  if [[ -n "$frontmatter_modules" ]]; then
    while IFS= read -r mod; do
      [[ -z "$mod" ]] && continue
      mod_file="${MODULES_DIR}/${mod}.md"
      if [[ ! -f "$mod_file" ]]; then
        error_msgs+=("module not found: ${mod}")
        errors=$((errors + 1))
      else
        mod_text=$(_extract_template "$mod_file")
        if [[ -z "$mod_text" ]]; then
          error_msgs+=("module has no text block: ${mod} (${mod_file})")
          errors=$((errors + 1))
        fi
      fi
    done <<< "$frontmatter_modules"
  fi

  # 2. {PLACEHOLDER}와 vars 블록 불일치 검출
  placeholders=$(_extract_vars "$template")
  if [[ -n "$placeholders" ]]; then
    while IFS= read -r ph; do
      [[ -z "$ph" ]] && continue
      key="${ph//[\{\}]/}"
      if [[ -n "$vars_meta" ]]; then
        if ! echo "$vars_meta" | grep -q "^${key}|"; then
          warn_msgs+=("placeholder ${ph} has no vars metadata")
        fi
      else
        warn_msgs+=("placeholder ${ph} found but no vars block defined")
      fi
    done <<< "$placeholders"
  fi

  # 3. vars 블록에 정의됐지만 템플릿에 없는 변수
  if [[ -n "$vars_meta" ]]; then
    while IFS='|' read -r meta_name _rest; do
      [[ -z "$meta_name" ]] && continue
      if [[ -z "$placeholders" ]] || ! echo "$placeholders" | grep -qF "{${meta_name}}"; then
        warn_msgs+=("var '${meta_name}' defined in vars block but not used in template")
      fi
    done <<< "$vars_meta"
  fi

  if [[ "$format" == "json" ]]; then
    errs_json="[]"
    warns_json="[]"
    if [[ ${#error_msgs[@]} -gt 0 ]]; then
      errs_json=$(printf '%s\n' "${error_msgs[@]}" | jq -Rnc '[inputs]')
    fi
    if [[ ${#warn_msgs[@]} -gt 0 ]]; then
      warns_json=$(printf '%s\n' "${warn_msgs[@]}" | jq -Rnc '[inputs]')
    fi
    if [[ $errors -gt 0 ]]; then
      jq -nc --argjson errors "$errs_json" --argjson warnings "$warns_json" \
        '{ok: false, errors: $errors, warnings: $warnings}'
    else
      jq -nc --argjson warnings "$warns_json" \
        '{ok: true, errors: [], warnings: $warnings}'
    fi
    exit 0
  fi

  for msg in "${error_msgs[@]}"; do echo "ERROR: $msg" >&2; done
  for msg in "${warn_msgs[@]}"; do echo "WARN: $msg" >&2; done
  if [[ $errors -gt 0 ]]; then
    echo "Validation FAILED: $errors error(s)" >&2
    exit 1
  fi
  echo "Validation passed" >&2
  exit 0
fi

# ============================================================================
# Placeholder 수집 + --var 키 검증
# ============================================================================

placeholders=$(_extract_vars "$template")

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

# ============================================================================
# --var로 전달된 키를 먼저 치환
# ============================================================================

# bash 5.x의 patsub_replacement 안전 치환 (& 문자 보호)
shopt -u patsub_replacement 2>/dev/null || true

for i in "${!var_keys[@]}"; do
  key="${var_keys[$i]}"
  val="${var_vals[$i]}"
  template="${template//\{${key}\}/${val}}"
done

# ============================================================================
# 미해결 변수 처리
# ============================================================================

remaining=$(_extract_vars "$template")

if [[ -n "$remaining" ]]; then
  if [[ "$non_interactive" == true ]]; then
    missing=$(echo "$remaining" | sed 's/[{}]//g' | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')
    if [[ "$format" == "json" ]]; then
      if [[ -n "$vars_meta" ]]; then
        # vars 블록 정의 순서로 메타데이터 포함 객체 배열 생성
        missing_json=$(
          {
            while IFS='|' read -r meta_name meta_desc meta_opts meta_def; do
              [[ -z "$meta_name" ]] && continue
              echo "$remaining" | grep -qF "{${meta_name}}" || continue
              ctx=$(_extract_var_context "$template" "$meta_name")
              if [[ -n "$meta_opts" ]]; then
                opts_json=$(echo "$meta_opts" | tr ',' '\n' | jq -Rnc '[inputs | select(length > 0)]')
              else
                opts_json="[]"
              fi
              if [[ -n "$meta_def" ]]; then
                jq -nc --arg n "$meta_name" --arg d "$meta_desc" --arg c "$ctx" \
                  --argjson o "$opts_json" --arg df "$meta_def" \
                  '{name:$n, desc:$d, context:$c, options:$o, default:$df}'
              else
                jq -nc --arg n "$meta_name" --arg d "$meta_desc" --arg c "$ctx" \
                  --argjson o "$opts_json" \
                  '{name:$n, desc:$d, context:$c, options:$o, default:null}'
              fi
            done <<< "$vars_meta"
            # vars 블록에 누락된 remaining 변수를 fallback 객체로 추가
            while IFS= read -r placeholder; do
              [[ -z "$placeholder" ]] && continue
              key="${placeholder//[\{\}]/}"
              echo "$vars_meta" | grep -q "^${key}|" && continue
              ctx=$(_extract_var_context "$template" "$key")
              jq -nc --arg n "$key" --arg c "$ctx" \
                '{name:$n, desc:"", context:$c, options:[], default:null}'
            done <<< "$remaining"
          } | jq -sc '.'
        )
      else
        # fallback: vars 블록 없으면 기존 문자열 배열
        missing_json=$(echo "$remaining" | sed 's/[{}]//g' | jq -Rnc '[inputs | select(length > 0)]')
      fi
      _json_exit false "$preset" "" "missing variables: $missing" "$missing_json" "[]"
    fi
    echo "Error: missing variables: $missing" >&2
    exit 2
  fi

  # ==========================================================================
  # CIR: fzf 기반 변수 편집 UI
  # 대안 비교 → 단일 fzf 세션에서 모든 변수를 한눈에 보고 원하는 순서로 편집.
  # read -p 순차 입력보다 직관적이고, 실시간 프리뷰로 치환 결과를 즉시 확인 가능.
  # ==========================================================================

  if command -v fzf &>/dev/null; then
    _var_tmpfile="$(mktemp /tmp/prompt-vars-XXXXX)"
    _tpl_tmpfile="$(mktemp /tmp/prompt-tpl-XXXXX)"
    _meta_tmpfile="$(mktemp /tmp/prompt-meta-XXXXX)"
    _cleanup() { rm -f "$_var_tmpfile" "$_tpl_tmpfile" "$_meta_tmpfile"; }
    trap '_cleanup' EXIT

    # 템플릿 저장 (프리뷰용)
    printf '%s\n' "$template" > "$_tpl_tmpfile"

    # 메타데이터 저장 (콜백용)
    printf '%s\n' "$vars_meta" > "$_meta_tmpfile"

    # 초기 변수 값 설정 (기본값 적용)
    while IFS= read -r placeholder; do
      [[ -z "$placeholder" ]] && continue
      key="${placeholder//[\{\}]/}"
      def_val=""
      if [[ -n "$vars_meta" ]]; then
        while IFS='|' read -r mn _md _mo mdf; do
          if [[ "$mn" == "$key" ]]; then def_val="$mdf"; break; fi
        done <<< "$vars_meta"
      fi
      echo "${key}=${def_val}" >> "$_var_tmpfile"
    done <<< "$remaining"

    # fzf 실행
    # CIR: </dev/tty 제거 — pipe stdin을 덮어쓰므로 변수 목록이 fzf에 전달되지 않음
    # fzf는 내부적으로 /dev/tty를 열어 키보드 입력을 처리함
    fzf_result=0
    "$SELF" __render_list "$_var_tmpfile" "$_meta_tmpfile" | \
      fzf \
        --ansi \
        --disabled \
        --no-sort \
        --header "  Enter: 변수 편집 | Ctrl-D: 완료 | Esc: 취소" \
        --preview "$SELF __preview '$_var_tmpfile' '$_tpl_tmpfile'" \
        --preview-window=right:60%:wrap \
        --bind "enter:execute($SELF __edit_var '$_var_tmpfile' '$_meta_tmpfile' {1})+reload($SELF __render_list '$_var_tmpfile' '$_meta_tmpfile')" \
        --bind "ctrl-d:accept" \
      >/dev/null 2>&1 || fzf_result=$?

    # Esc/Ctrl-C → 취소
    if [[ $fzf_result -eq 130 ]]; then
      _cleanup
      trap - EXIT
      exit 0
    fi

    # fzf 비정상 종료 (tty 미접근, 내부 에러 등) → 미확인 기본값 적용 방지
    if [[ $fzf_result -ne 0 ]]; then
      _cleanup
      trap - EXIT
      if [[ "$format" == "json" ]]; then
        _json_exit false "$preset" "" "interactive variable editor failed (fzf exit: $fzf_result)"
      fi
      echo "Error: interactive variable editor failed (fzf exit: $fzf_result)" >&2
      exit 1
    fi

    # 변수 적용
    while IFS='=' read -r key val; do
      [[ -z "$key" ]] && continue
      if [[ -z "$val" ]]; then
        echo "Error: empty value for {${key}}" >&2
        exit 2
      fi
      template="${template//\{${key}\}/${val}}"
    done < "$_var_tmpfile"

    _cleanup
    trap - EXIT
  else
    # fzf 없으면 기존 read 루프 fallback
    echo "Variables to fill:" >&2
    while IFS= read -r placeholder; do
      [[ -z "$placeholder" ]] && continue
      key="${placeholder//[\{\}]/}"
      # vars 메타에서 기본값/설명/옵션 찾기
      var_default="" var_desc="" var_opts=""
      if [[ -n "$vars_meta" ]]; then
        while IFS='|' read -r mn md mo mdf; do
          if [[ "$mn" == "$key" ]]; then
            var_default="$mdf"; var_desc="$md"; var_opts="$mo"
            break
          fi
        done <<< "$vars_meta"
      fi
      prompt_str="  {${key}}"
      [[ -n "$var_desc" ]] && prompt_str+=" ($var_desc)"
      [[ -n "$var_opts" ]] && prompt_str+=" [${var_opts}]"
      [[ -n "$var_default" ]] && prompt_str+=" (default: ${var_default})"
      prompt_str+=": "
      read -rp "$prompt_str" value </dev/tty
      [[ -z "${value// /}" && -n "$var_default" ]] && value="$var_default"
      if [[ -z "${value// /}" ]]; then
        echo "Error: empty value for {${key}}" >&2
        exit 2
      fi
      template="${template//\{${key}\}/${value}}"
    done <<< "$remaining"
  fi
fi

# ============================================================================
# 출력
# ============================================================================

if [[ "$format" == "json" ]]; then
  _json_exit true "$preset" "$template" ""
fi

printf '%s\n' "$template"

# ============================================================================
# Clipboard
# ============================================================================

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
