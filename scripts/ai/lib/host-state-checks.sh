#!/usr/bin/env bash
# scripts/ai/lib/host-state-checks.sh
#
# verify-ai-compat.sh의 검사 함수 모음 (host state + repo 스캔).
# source한 caller가 REPO_ROOT, REPO_ROOT_REAL, MAIN_REPO_ROOT, HOME, pass/fail/warn 전역을 제공한다.
# retired 참조 스캔은 추가로 RETIRED_SHARED_SKILLS, RETIRED_REF_SCAN_ROOTS,
# RETIRED_REF_SCAN_EXCLUDE 전역을 소비한다.

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

# ─── retired 스킬 잔존 참조 스캔 ───
# RETIRED_REF_SCAN_ROOTS 트리 전체를 본다. 스킬 디렉토리는 SKILL.md/references뿐 아니라
# modes/·scripts/·tests/ 하위까지 잔존 참조가 남을 수 있어 확장자·경로로 좁히지 않는다.
#
# RETIRED_REF_SCAN_EXCLUDE 항목 형식: "<스킬명>|<REPO_ROOT 상대 경로>|<라인 부분문자열>".
# 세 필드를 모두 만족하는 라인만 면제한다. 파일 통째 면제가 아니므로, 제외 등록된 파일에
# 나중에 다른 문맥이나 다른 퇴역 스킬명의 참조가 들어와도 그대로 warn으로 잡힌다.
# 어떤 라인에도 걸리지 않은 제외 항목은 stale로 보고한다 — 원본 서술이 사라졌는데 규칙만
# 남으면 이후 진짜 잔존 참조를 조용히 삼키기 때문이다.
_RETIRED_REF_EXCLUDE_HIT=()

_retired_ref_reset_exclude_hits() {
  local i=0
  local total
  # 미정의 배열도 `set -u` 하에서 안전하게 다루도록 "정의된 빈 배열"로 정규화한다.
  RETIRED_REF_SCAN_EXCLUDE=(${RETIRED_REF_SCAN_EXCLUDE[@]+"${RETIRED_REF_SCAN_EXCLUDE[@]}"})
  total="${#RETIRED_REF_SCAN_EXCLUDE[@]}"
  _RETIRED_REF_EXCLUDE_HIT=()
  while [ "$i" -lt "$total" ]; do
    _RETIRED_REF_EXCLUDE_HIT+=("0")
    i=$((i + 1))
  done
}

# 매치 라인 1건이 제외 대상인지 판정하고, 걸린 제외 항목에 hit 표시를 남긴다.
_retired_ref_is_excluded() {
  local skill="$1" rel="$2" text="$3"
  local i=0
  local total="${#RETIRED_REF_SCAN_EXCLUDE[@]}"
  local entry rest e_skill e_rel e_needle

  while [ "$i" -lt "$total" ]; do
    entry="${RETIRED_REF_SCAN_EXCLUDE[$i]}"
    i=$((i + 1))
    e_skill="${entry%%|*}"
    rest="${entry#*|}"
    e_rel="${rest%%|*}"
    e_needle="${rest#*|}"
    # 필드 3개가 아닌 항목은 형식 오류 — stale 보고에서 잡히도록 여기서는 건너뛴다.
    [ "$rest" != "$entry" ] && [ "$e_needle" != "$rest" ] || continue
    [ "$skill" = "$e_skill" ] || continue
    [ "$rel" = "$e_rel" ] || continue
    case "$text" in
      *"$e_needle"*) ;;
      *) continue ;;
    esac
    _RETIRED_REF_EXCLUDE_HIT[$((i - 1))]="1"
    return 0
  done
  return 1
}

# 스캔이 끝난 뒤 한 번도 걸리지 않은 제외 항목을 보고한다 (형식 오류 항목 포함).
_retired_ref_report_stale_excludes() {
  local i=0
  local total="${#RETIRED_REF_SCAN_EXCLUDE[@]}"

  while [ "$i" -lt "$total" ]; do
    if [ "${_RETIRED_REF_EXCLUDE_HIT[$i]}" != "1" ]; then
      fail "retired shared 스킬 참조 제외 항목이 아무 라인에도 걸리지 않음(stale): ${RETIRED_REF_SCAN_EXCLUDE[$i]}"
    fi
    i=$((i + 1))
  done
}

verify_retired_shared_skill_references() {
  local match_file kept_file skill_name scan_root line path rel text match_count grep_rc
  local roots=()

  for scan_root in "${RETIRED_REF_SCAN_ROOTS[@]}"; do
    [ -d "$scan_root" ] && roots+=("$scan_root")
  done
  if [ "${#roots[@]}" -eq 0 ]; then
    fail "retired shared 스킬 참조 스캔 루트 없음 (RETIRED_REF_SCAN_ROOTS 확인)"
    return
  fi

  _retired_ref_reset_exclude_hits

  match_file="$(mktemp "${TMPDIR:-/tmp}/verify-ai-retired-skill-refs.XXXXXX")"
  kept_file="$(mktemp "${TMPDIR:-/tmp}/verify-ai-retired-skill-refs-kept.XXXXXX")"
  for skill_name in "${RETIRED_SHARED_SKILLS[@]}"; do
    # -I: 바이너리 fixture 제외. LC_ALL=C로 고정해 바이너리 판정을 로케일에서 떼어낸다
    # (UTF-8 로케일의 grep은 invalid 바이트를 가진 텍스트 파일까지 바이너리로 보고 건너뛴다).
    # rc 0=매치 있음, 1=매치 없음, >1=일부 파일을 읽지 못함.
    if LC_ALL=C grep -rnIHF -- "$skill_name" "${roots[@]}" >"$match_file"; then
      grep_rc=0
    else
      grep_rc=$?
    fi
    # rc>1은 "읽지 못한 파일이 있다"는 신호일 뿐 수집된 매치는 유효하다. fail로 알리되
    # 스캔을 중단하지 않는다 — 중단하면 같은 실행에서 발견한 실제 잔존 참조까지 사라진다.
    if [ "$grep_rc" -gt 1 ]; then
      fail "retired shared 스킬 참조 검사 grep 부분 실패: $skill_name (rc=$grep_rc — 아래 결과는 읽은 파일 기준)"
    fi

    # `<path>:<lineno>:<text>` 라인을 경로/라인번호/본문으로 분해해 제외 목록과 대조한다.
    : >"$kept_file"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      path="${line%%:*}"
      rel="${path#"$REPO_ROOT"/}"
      text="${line#*:}"
      text="${text#*:}"
      _retired_ref_is_excluded "$skill_name" "$rel" "$text" && continue
      printf '%s\n' "${line#"$REPO_ROOT"/}" >>"$kept_file"
    done <"$match_file"

    if [ -s "$kept_file" ]; then
      match_count="$(wc -l <"$kept_file" | tr -d '[:space:]')"
      # 문서에는 "과거 X 스킬은 제거" 같은 이력 서술도 남을 수 있어,
      # retired 배포 잔재와 달리 우선 warn-only로 두고 사람이 의도를 판정한다.
      warn "retired shared 스킬 참조 잔존: $skill_name (${match_count}건)"
      sed 's/^/    /' "$kept_file" >&2
    else
      pass "retired shared 스킬 참조 없음: $skill_name"
    fi
  done

  _retired_ref_report_stale_excludes
  rm -f "$match_file" "$kept_file"
}
