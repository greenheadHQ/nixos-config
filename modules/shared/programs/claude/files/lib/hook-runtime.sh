#!/usr/bin/env bash
# hook-runtime.sh — claude/codex hook 공통 helper 라이브러리.
# 정책 출처: https://github.com/greenheadHQ/nixos-config/issues/759
#
# 본 라이브러리는 pinning-alert, pinning-guard (claude/codex 양 트리) 와 record-last-stop,
# record-prompt-submit (codex 트리) 의 구현 use-site 에서 사용한다. 런타임별
# 전용 로직 (CLAUDECODE/CODEX_PROGRAMMATIC 가드, agent_id 가드, apply_patch envelope
# dispatch) 은 각 hook 본문에 inline 유지한다.
#
# 비대상: nrs-session-cleanup (claude/codex 양쪽) — 자체 NRS_LOCK_FILE cleanup 로직만
# 사용하며 lib 의존성 없음.
#
# 호출자는 본 lib 의 실패 정책 (fail-closed / warn-only / inline fallback) 을 결정한다.
# `hook_load_lib` 는 정책 결정권 없이 stdout 으로 path 또는 빈 문자열을 반환한다.
#
# USED-BY:
#   claude/files/hooks/pinning-alert.sh         # via $HOOK_RUNTIME_LIB
#   claude/files/hooks/pinning-guard.sh         # via $HOOK_RUNTIME_LIB
#   codex/files/hooks/pinning-alert.sh          # via $HOOK_RUNTIME_LIB
#   codex/files/hooks/pinning-guard.sh          # via $HOOK_RUNTIME_LIB
#   codex/files/hooks/record-last-stop.sh       # via $HOOK_RUNTIME_LIB
#   codex/files/hooks/record-prompt-submit.sh   # via $HOOK_RUNTIME_LIB
#
# scripts/ai/verify-ai-compat.sh 가 본 USED-BY 선언과 실제 source 호출 일치를 oracle로 검증.

# shellcheck disable=SC2034
# 본 lib 의 함수는 source 후 호출되며, 정적 분석은 사용처를 보지 못해 unused 로 false positive.

# hook_load_lib <env_var_name> <home_lib_dir> <lib_basename>
#
# 공유 라이브러리 경로 해결. env var primary + home lib dir secondary 시도.
# cross-tree fallback 없음. 호출자가 환경별 경로를 명시적으로 전달한다.
#
# 인자:
#   env_var_name: env var 이름 (예: PINNING_PATTERNS_LIB)
#   home_lib_dir: nix-installed lib 디렉토리 (예: $HOME/.codex/lib)
#   lib_basename: lib 파일명 (예: pinning-patterns.sh)
#
# stdout: 성공 시 lib path 출력. 실패 시 빈 문자열.
# exit code: 0 (성공) / 1 (실패).
#
# 호출자는 stdout 결과로 fail-closed / warn-only / inline fallback 정책을 결정한다.
# 본 helper 는 stderr 메시지 출력 안 함 — 호출자가 정책에 맞는 메시지 작성.
hook_load_lib() {
  local env_var_name="$1" home_lib_dir="$2" lib_basename="$3"
  local env_val lib_path
  # bash indirect expansion. hook은 #!/usr/bin/env bash 로 실행되어 source되므로 안전.
  env_val="${!env_var_name:-}"
  if [ -n "$env_val" ] && [ -f "$env_val" ]; then
    printf '%s' "$env_val"
    return 0
  fi
  lib_path="$home_lib_dir/$lib_basename"
  if [ -f "$lib_path" ]; then
    printf '%s' "$lib_path"
    return 0
  fi
  return 1
}

# hook_init_scan_dir [prefix]
#
# 임시 디렉토리 생성. mktemp -d 사용. trap 은 호출자가 설치한다.
#
# 인자:
#   prefix: mktemp prefix (기본값: hook-scan)
#
# stdout: 생성된 디렉토리 path.
# exit code: 0 (성공) / 1 (실패).
#
# TMPDIR fallback: ${TMPDIR:-/tmp} 는 TMPDIR 이 unset/empty 일 때만 /tmp 로 fallback 한다.
# 그러나 codex 가 자식 프로세스에 상속시키는 ~/.codex/tmp/... 세션 임시경로처럼 TMPDIR 이
# "set 이지만 이미 삭제됐거나 쓰기 불가" 인 경우 (set-but-unusable) 는 fallback 되지 않아
# `mktemp -d "$TMPDIR/..."` 가 부모 부재로 실패한다. systemd private tmp가 삭제된 mount처럼
# `/tmp` 자체가 stat 가능하지만 생성은 실패하는 경우도 있으므로, 후보 디렉토리는 실제 mktemp
# 성공까지 확인한다. pinning-guard 는 이 실패를 fail-closed 로 처리해 Bash/Edit/Write/apply_patch
# 전 명령을 차단하므로, 여기서 usable 후보를 찾아 가용성 회귀를 막는다. mktemp 가 새 격리
# 디렉토리를 만드는 것은 동일하므로 pinning 검사의 보안 경계는 그대로 유지된다.
hook_init_scan_dir() {
  local prefix="${1:-hook-scan}"
  local requested_base="${TMPDIR:-}"
  local cache_base=""
  local base out

  if [ -n "${XDG_CACHE_HOME:-}" ]; then
    cache_base="$XDG_CACHE_HOME/codex-hooks/tmp"
  elif [ -n "${HOME:-}" ]; then
    cache_base="$HOME/.cache/codex-hooks/tmp"
  fi

  for base in "$requested_base" /tmp /var/tmp "${XDG_RUNTIME_DIR:-}" "$cache_base"; do
    [ -n "$base" ] || continue
    if [ ! -d "$base" ]; then
      if [ -n "$cache_base" ] && [ "$base" = "$cache_base" ]; then
        mkdir -p "$base" 2>/dev/null || continue
      else
        continue
      fi
    fi
    [ -w "$base" ] || continue
    if out=$(mktemp -d "$base/${prefix}-XXXXXX" 2>/dev/null); then
      printf '%s\n' "$out"
      return 0
    fi
  done
  return 1
}

# hook_parse_tool_name
#
# stdin 으로 받은 JSON 에서 .tool_name 추출. jq 사용.
#
# stdin: hook stdin JSON (예: '{"tool_name": "Edit", ...}')
# stdout: tool_name 값 또는 빈 문자열.
# exit code: 항상 0 (jq 파싱 실패 시에도 빈 문자열 + 0).
hook_parse_tool_name() {
  jq -r '.tool_name // empty' 2>/dev/null || true
}

# hook_parse_session_id
#
# stdin 으로 받은 JSON 에서 .session_id 추출. jq 사용.
#
# stdin: hook stdin JSON
# stdout: session_id 값 또는 빈 문자열.
# exit code: 항상 0.
hook_parse_session_id() {
  jq -r '.session_id // empty' 2>/dev/null || true
}
