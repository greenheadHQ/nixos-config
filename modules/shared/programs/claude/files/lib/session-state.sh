#!/usr/bin/env bash
# shellcheck disable=SC2034
# SC2034: 본 파일의 상수는 source되는 hook과 statusline에서만 참조한다.
# 정적 분석은 직접 사용처를 보지 못해 false positive로 unused를 보고하므로
# 파일 전체에 대해 disable한다.
#
# Session state shared helpers — SessionStart hook(session-init-icons.sh), Stop
# hook(record-last-session.sh), statusline.sh(validate_session_id 정책)가
# 공유하는 상수·함수의 SSOT. 한쪽에서 변경하면 lineage 복원/sidecar I/O가
# silently 어긋나는 위험을 코드 레벨에서 차단한다.
#
# USED-BY:
#   claude/files/hooks/session-init-icons.sh    # via $SESSION_STATE_LIB
#   claude/files/hooks/record-last-session.sh   # via $SESSION_STATE_LIB
#   claude/files/scripts/statusline.sh          # via $SESSION_STATE_LIB (validate_session_id 정책)
#
# scripts/ai/verify-ai-compat.sh 가 본 USED-BY 선언과 실제 source 호출 일치를 oracle로 검증.
#
# 공개 API
# ─────────
#   상수:
#     SESSION_STATE_DIR              — `~/.claude/status-icons`. status JSON + 마커 위치.
#     SESSION_MEMO_DIR               — `~/.claude/memos`. 세션 메모 위치.
#     SESSION_LOG_DIR                — `~/.claude/logs`. 디버그 로그 위치.
#     SESSION_MARKER_PREFIX          — `.last-session-`. cwd 마커 파일명 prefix.
#   함수:
#     hash_cwd <path>                — cwd → sha1 hex(macOS shasum 우선, Linux sha1sum
#                                       fallback). 둘 다 부재 시 빈 문자열 반환.
#     marker_path_for_cwd <path>     — cwd → 마커 절대경로. encoded 실패 시 return 1.
#     is_safe_session_id <sid>       — 정책 SSOT (0=safe, 1=unsafe). allowlist
#                                       `[A-Za-z0-9._-]` + `..` 차단.
#     session_hook_log <event> <msg> — `CLAUDE_HOOK_DEBUG=1` 게이트. 단일 message
#                                       문자열만 받는다(공백/특수문자 포함 가능).
#                                       허용 event: `session-start`, `session-start-unsafe`,
#                                       `stop`.
#
# Source 방법(pinning-{guard,alert}.sh가 lib/pinning-patterns.sh를 source하는
# 패턴과 동일 — `$HOME/.claude/lib` 우선 + repo fallback):
#   SESSION_STATE_LIB="${SESSION_STATE_LIB:-$HOME/.claude/lib/session-state.sh}"
#   [ -f "$SESSION_STATE_LIB" ] || SESSION_STATE_LIB="<script_dir>/../lib/session-state.sh"
#   . "$SESSION_STATE_LIB"

# 공유 상수
SESSION_STATE_DIR="$HOME/.claude/status-icons"
SESSION_MEMO_DIR="$HOME/.claude/memos"
# SESSION_LOG_DIR은 append-only single file. size-based rotation은 별도 follow-up.
SESSION_LOG_DIR="$HOME/.claude/logs"
SESSION_MARKER_PREFIX=".last-session-"
# Retention 정책 없음 — 명확한 도입 이유가 PR #263 본문/code/CIR 어디에도
# 기록되지 않은 임의의 30일 정리는 제거. 사용자 의도는 "아카이빙 우선" —
# sidecar/memo/marker는 사용자가 명시적으로 정리하기 전까지 보존. storage 누적
# 우려 시 별도 도구로 처리 (이 hook은 자동 삭제하지 않는다).

# cwd → sha1 hex. shasum 우선, sha1sum fallback. 둘 다 부재 시 빈 문자열
# (호출부에서 lineage 복원/마커 기록을 graceful skip).
hash_cwd() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum | awk '{print $1}'
  elif command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha1sum | awk '{print $1}'
  fi
}

# cwd → marker 파일 절대 경로
marker_path_for_cwd() {
  local encoded
  encoded=$(hash_cwd "$1")
  [ -z "$encoded" ] && return 1
  printf '%s/%s%s' "$SESSION_STATE_DIR" "$SESSION_MARKER_PREFIX" "$encoded"
}

# session_id가 sidecar/marker 파일명에 안전한지 검사 (0=safe, 1=unsafe).
# 정책: allowlist `[A-Za-z0-9._-]` only + `..` 시퀀스 차단(path traversal 방어).
# 본 검증의 SSOT — hook과 statusline은 모두 이 함수를 source해서 호출한다.
is_safe_session_id() {
  case "$1" in
    "") return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
    *..*) return 1 ;;
  esac
  return 0
}

# CLAUDE_HOOK_DEBUG=1일 때만 활성화되는 진단 로그.
# 실제 source 라벨링/cwd 동작을 실측하기 위한 영구 진단 인프라.
#
# Invariant:
# - 첫 인자는 event 라벨(허용 enum: session-start / session-start-unsafe / stop).
# - 두 번째 인자는 단일 message 문자열. 호출자가 `k=v k=v` 형태를 그대로 넘긴다.
#   reader 측에서 `awk '{ts=$1; ev=$2; rest=$0}'` 형태로 파싱하면 첫 두 토큰만
#   고정 필드, rest는 free-form. 값에 공백이 들어가도 단일 인자라면 한 줄로 기록.
# - 본 함수는 정상 session-start/stop 로그(cwd=$CWD 포함)에도 사용되므로
#   sanitize 범위는 단일 라인 invariant 유지에 필요한 최소(C0 + DEL)로 한정한다.
#   ESC(0x1B)는 C0에 포함되어 차단된다. raw C1 byte(0x80-0x9F)는 정상 UTF-8
#   sequence에서 *단독* 등장이 invalid하므로 정상 cwd에선 발생하지 않는다.
#   UTF-8 continuation byte는 보존되어 한글 등 cwd가 그대로 기록된다.
#   unsafe sid 입력처럼 raw C1이 들어올 가능성이 있는 호출자는 자체적으로
#   추가 sanitize를 적용할 수 있으나, debug 로그를 terminal cat보다 grep/awk
#   reader로 보는 일반 사용 케이스에선 본 sanitize로 충분하다.
session_hook_log() {
  [ "${CLAUDE_HOOK_DEBUG:-0}" = "1" ] || return 0
  mkdir -p "$SESSION_LOG_DIR" 2>/dev/null || return 0
  chmod 700 "$SESSION_LOG_DIR" 2>/dev/null || true
  local msg
  # LC_ALL=C로 byte-mode tr. C0(0x00-0x1F) + DEL(0x7F)만 치환 — UTF-8 continuation
  # byte(0x80-0xBF)는 보존해 정상 한글/UTF-8 cwd가 깨지지 않게 한다.
  msg=$(printf '%s' "$2" | LC_ALL=C tr '\000-\037\177' '?')
  printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$msg" \
    >> "$SESSION_LOG_DIR/session-hooks.log" 2>/dev/null || true
}
