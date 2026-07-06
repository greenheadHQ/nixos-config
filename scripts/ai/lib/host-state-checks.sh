#!/usr/bin/env bash
# scripts/ai/lib/host-state-checks.sh
#
# verify-ai-compat.sh의 host-state 검사 함수 모음.
# source한 caller가 REPO_ROOT, REPO_ROOT_REAL, MAIN_REPO_ROOT, HOME, pass/fail 전역을 제공한다.

# shellcheck disable=SC2154

resolved_target_matches_repo_suffix() {
  local resolved="$1"
  local expected="$2"
  local expected_suffix="$3"

  [ -n "$resolved" ] || return 1
  [ -n "$expected" ] || return 1

  if [ "$resolved" = "$expected" ]; then
    return 0
  fi

  case "$resolved" in
    */"$expected_suffix") ;;
    *) return 1 ;;
  esac

  case "$resolved" in
    /nix/store/*/"$expected_suffix")
      return 0
      ;;
  esac

  if [ -n "$MAIN_REPO_ROOT" ]; then
    case "$resolved" in
      "$MAIN_REPO_ROOT/$expected_suffix"|"$MAIN_REPO_ROOT/.claude/worktrees/"*/"$expected_suffix")
        return 0
        ;;
    esac
  fi

  if [ -n "$REPO_ROOT_REAL" ]; then
    case "$resolved" in
      "$REPO_ROOT_REAL/$expected_suffix")
        return 0
        ;;
    esac
  fi

  return 1
}

_check_hook_executable() {
  local relpath="$1" abspath="$HOME/$1" hook_name
  hook_name="$(basename "$relpath")"
  local expected_suffix="modules/shared/programs/codex/files/hooks/$hook_name"
  if [ ! -e "$abspath" ]; then
    fail "hook 사본 없음: $abspath"
    return
  fi
  if [ ! -x "$abspath" ]; then
    fail "hook 실행 권한 없음: $abspath"
    return
  fi
  local resolved
  resolved="$(readlink -f "$abspath" 2>/dev/null || true)"
  if [ -z "$resolved" ] || [ ! -f "$resolved" ]; then
    fail "hook 사본 readlink 실패 또는 target 부재: $relpath (resolved=$resolved)"
    return
  fi
  case "$resolved" in
    */"$expected_suffix")
      pass "hook 사본 OK: $relpath"
      ;;
    *)
      fail "hook 사본 대상 path suffix 불일치: $relpath (resolved=$resolved expected_suffix=*/$expected_suffix)"
      ;;
  esac
}

_check_executable_symlink_suffix() {
  local relpath="$1" expected_suffix="$2"
  local abspath="$HOME/$relpath"
  if [ ! -e "$abspath" ]; then
    fail "프로비저닝 실행 파일 없음: $abspath"
    return
  fi
  if [ ! -x "$abspath" ]; then
    fail "프로비저닝 실행 권한 없음: $abspath"
    return
  fi
  local resolved
  resolved="$(readlink -f "$abspath" 2>/dev/null || true)"
  if [ -z "$resolved" ] || [ ! -f "$resolved" ]; then
    fail "프로비저닝 실행 파일 readlink 실패 또는 target 부재: $relpath (resolved=$resolved)"
    return
  fi
  case "$resolved" in
    */"$expected_suffix")
      pass "프로비저닝 실행 파일 OK: $relpath"
      ;;
    *)
      fail "프로비저닝 실행 파일 target suffix 불일치: $relpath (resolved=$resolved expected_suffix=*/$expected_suffix)"
      ;;
  esac
}

verify_used_by_oracle() {
  local _lib_path="$1"
  local _lib_label="$2"
  local _lib_basename _lib_basename_re
  _lib_basename=$(basename "$_lib_path")
  _lib_basename_re=${_lib_basename//./\\.}
  if [ ! -f "$_lib_path" ]; then
    fail "USED-BY oracle: lib 파일 없음 ($_lib_label) — $_lib_path"
    return
  fi

  # 헤더에서 USED-BY 블록 파싱. `^#[[:space:]]+` 로 시작하는 모든 indented 주석 라인을 후보로
  # 처리하고, 라인 형식이 정확히 `<path>.sh   # via $VAR_NAME` 인지 strict 검증한다.
  # 위반은 `BAD\t<line>` sentinel 로 emit 하여 shell loop 가 명시 fail. 정상은 `OK\t<path>\t<var>`.
  # 빈 주석 (`^#$`) 또는 비-주석 라인 (`!/^#/`) 에서만 블록 종료.
  #
  # strict 형식 (고정 위치):
  #   - arr[1] = path (`.sh` 로 끝나는 형태)
  #   - arr[2] = `#` (구분자)
  #   - arr[3] = `via` (literal)
  #   - arr[4] = `$VAR_NAME` ($ prefix + `[A-Z_][A-Z0-9_]*` 형태)
  #   - arr[5+] = 선택적 trailing 주석/설명 (검증 안 함)
  local _used_by_entries
  _used_by_entries=$(awk '
    /^# USED-BY:/ { in_block=1; next }
    in_block {
      if (/^#$/ || !/^#/) {
        in_block=0
        next
      }
      if (/^#[[:space:]]+/) {
        line = $0
        sub(/^#[[:space:]]+/, "", line)
        if (line == "") next
        n = split(line, arr, /[[:space:]]+/)
        if (n < 4) {
          printf "BAD\t%s\n", $0
          next
        }
        path = arr[1]
        if (path !~ "^[a-zA-Z][a-zA-Z0-9_./-]+\\.sh$") {
          printf "BAD\t%s\n", $0
          next
        }
        if (arr[2] != "#" || arr[3] != "via") {
          printf "BAD\t%s\n", $0
          next
        }
        var_raw = arr[4]
        if (var_raw !~ "^\\$[A-Z_][A-Z0-9_]*$") {
          printf "BAD\t%s\n", $0
          next
        }
        var = var_raw
        sub(/^\$/, "", var)
        printf "OK\t%s\t%s\n", path, var
      }
    }
  ' "$_lib_path")

  if [ -z "$_used_by_entries" ]; then
    fail "USED-BY oracle: lib 헤더에 USED-BY 블록 없음 ($_lib_label)"
    return
  fi

  local _ok=1
  local _count=0
  # Forward check: 선언된 각 use-site 가 실제 source 패턴을 가지는지 확인.
  # Declared list: backward check 시 비교용. newline-delimited 정규화된 path 를 모아 두고
  # grep -Fxq 로 set membership 검사. `declare -A` (Bash 4+) 회피하여 macOS /bin/bash 3.2 호환.
  local _declared_list=""
  while IFS=$'\t' read -r _tag _arg1 _arg2; do
    [ -n "$_tag" ] || continue
    if [ "$_tag" = "BAD" ]; then
      fail "USED-BY oracle: $_lib_label 헤더의 USED-BY 라인 형식 위반 ($_arg1) — \`<path>.sh   # via \$VAR_NAME\` 형식 필요"
      _ok=0
      continue
    fi
    local _use_site="$_arg1" _expected_var="$_arg2"
    [ -n "$_use_site" ] || continue
    _count=$((_count + 1))
    _declared_list="${_declared_list}${_use_site}"$'\n'
    local _use_full_path
    case "$_use_site" in
      claude/*|codex/*)
        _use_full_path="$REPO_ROOT/modules/shared/programs/$_use_site"
        ;;
      *)
        _use_full_path="$REPO_ROOT/$_use_site"
        ;;
    esac
    if [ ! -f "$_use_full_path" ]; then
      fail "USED-BY oracle: 선언된 use-site 미존재 ($_lib_label → $_use_site)"
      _ok=0
      continue
    fi
    # 주석 라인 제외 (특히 `# shellcheck source=`).
    local _non_comment
    _non_comment=$(grep -vE '^[[:space:]]*#' "$_use_full_path")

    # 단일 매칭 규칙: expected_var (use-site source local 변수) 의 할당 RHS 가 lib_basename 포함
    # + 동일 var 의 source 호출. hook_load_lib helper 호출은 변수 할당 RHS 의 일부이므로 같은 매칭 적용.
    if printf '%s\n' "$_non_comment" | grep -qE "^[[:space:]]*${_expected_var}=.*${_lib_basename_re}" \
      && printf '%s\n' "$_non_comment" | grep -qE "(\.[[:space:]]+|source[[:space:]]+)\"\\\$${_expected_var}\""; then
      continue
    fi
    fail "USED-BY oracle: $_lib_label → $_use_site 에서 실제 source 패턴 미발견 (\$${_expected_var} 변수 할당 RHS 에 ${_lib_basename} 포함 + 동일 var source 필요)"
    _ok=0
  done <<< "$_used_by_entries"

  # Backward check: repo 내에서 lib_basename 을 변수 할당 RHS 로 사용 + 동일 var source 호출이
  # 있는 .sh 파일을 후보로 수집한 뒤, _declared_list 에 없는 후보는 fail.
  # 이는 `실제 source 하지만 USED-BY 헤더에 미선언` 인 drift 를 잡는다 (양방향 검증).
  # 검색 범위: modules/shared/programs/ + scripts/. 자기 자신 lib path 는 제외.
  local _candidate _candidate_rel _candidate_abs_rel
  while IFS= read -r _candidate; do
    [ -n "$_candidate" ] || continue
    # 자기 자신 (lib 정의 파일) 제외.
    [ "$_candidate" = "$_lib_path" ] && continue
    # lib 자체 디렉토리 내 다른 lib 파일은 제외 (예: hook-runtime 검증 시 pinning-patterns 본문 매치).
    case "$_candidate" in
      */modules/shared/programs/claude/files/lib/*) continue ;;
      */modules/shared/programs/codex/files/lib/*) continue ;;
    esac
    # 변수 할당 + source 호출 패턴 둘 다 있어야 진짜 후보.
    if grep -qE "^[[:space:]]*[A-Z_]+_LIB=.*${_lib_basename_re}" "$_candidate" \
      && grep -qE "(\.[[:space:]]+|source[[:space:]]+)\"\\\$[A-Z_]+_LIB\"" "$_candidate"; then
      _candidate_abs_rel="${_candidate#"$REPO_ROOT"/}"
      _candidate_rel="${_candidate_abs_rel#modules/shared/programs/}"
      if ! printf '%s' "$_declared_list" | grep -Fxq "$_candidate_rel" \
        && ! printf '%s' "$_declared_list" | grep -Fxq "$_candidate_abs_rel"; then
        fail "USED-BY oracle: $_lib_label backward check 실패 — $_candidate_rel 가 lib 을 source 하지만 USED-BY 헤더에 미선언"
        _ok=0
      fi
    fi
  done < <(grep -rlE "${_lib_basename_re}" \
    --include='*.sh' \
    "$REPO_ROOT/modules/shared/programs/" "$REPO_ROOT/scripts/" 2>/dev/null)

  if [ "$_ok" = "1" ]; then
    pass "USED-BY oracle 통과: $_lib_label ($_count use-site, backward check OK)"
  fi
}
