#!/usr/bin/env bash
# codex-exec-supervised — capability-probe based supervisor wrapper for codex exec
#
# Background (issue #593): codex exec --ephemeral는 prompt 인수가 있어도 stdin이 piped면
# read_prompt_from_stdin(StdinPromptBehavior::OptionalAppend)가 EOF 미도달 시 무기한 wait한다.
# npm wrapper(@openai/codex)는 spawn(binaryPath, args, {stdio:"inherit", env})로 native binary를
# 호출하면서 detach나 process group 생성을 하지 않고 SIGKILL forward도 안 한다. 따라서
# 단순 `timeout` 호출만으로는 wrapper PID만 죽고 native binary가 잔존할 수 있다.
#
# 본 wrapper는 setsid + timeout 조합으로 process group kill을 보장한다. mac BSD coreutils에는
# timeout이 없고 setsid도 없으므로, Nix wrapper(modules/shared/programs/shell/default.nix의
# home.file + pkgs.writeShellScript)가 두 binary의 absolute store path를 CODEX_EXEC_TIMEOUT_BIN과
# CODEX_EXEC_SETSID_BIN env 변수에 export한 뒤 본 raw script를 exec한다. 이로써 wrapper subprocess의
# PATH가 GNU coreutils로 오염되지 않고, codex exec 자식 shell도 원래 user PATH(BSD coreutils 우선)를
# 보존한다.
#
# stdin 처리 책임: 호출자가 명시적으로 처리 (`cat prompt.md | codex-exec-supervised ... -` 또는
# `codex-exec-supervised ... < /dev/null`). 본 wrapper는 stdin을 inherit한다.
#
# 사용 (Layer 1 supervised contract — programmatic 호출의 canonical pattern):
#   cat prompt.md | codex-exec-supervised --sandbox read-only --ignore-user-config --ignore-rules --ephemeral \
#     -c model="gpt-5.5" -c model_reasoning_effort="medium" -o result.md -
#
# wrapper 자체 capability probe (사전점검용 — codex exec를 호출하지 않고 의존성만 검증):
#   codex-exec-supervised --check  # 모든 dependency(setsid/timeout/codex) 가용 시 exit 0, 부재 시 127
#
# 환경 변수 (override 가능):
#   CODEX_EXEC_TIMEOUT_SECONDS    overall timeout, default 1800 (30분; Codex
#                                 agents.job_max_runtime_seconds worker fallback
#                                 1800초와 일치 — 출처는 Codex config-reference
#                                 https://developers.openai.com/codex/config-reference 의 agents 섹션)
#                                 rationale: programmatic codex 호출(reviewer/Arbiter/Intensity/fan-out/
#                                 consult)은 xhigh reasoning + 큰 prompt에서 수 분 걸리며 upstream
#                                 보고는 12-15분 지연 사례까지 있다 (openai/codex#9872). 기본값을
#                                 운영 budget(30분)으로 두고, fixture/검증용 짧은 timeout은 호출자가
#                                 env로 명시한다 (예: invocation matrix는 INVOCATION_MATRIX_TIMEOUT_SECONDS
#                                 oracle 상수로 40초 명시).
#                                 양수 정수만 허용 (invalid 값은 fail-closed).
#                                 상한 7200초 (2시간 — supervisor fail-closed 상한. default 운영
#                                 budget(1800초)을 초과하는 합법 작업의 escape는 raw codex exec
#                                 우회로 처리).
#   CODEX_EXEC_KILL_AFTER_SECONDS SIGTERM 후 SIGKILL 전환 grace, default 5
#                                 rationale: npm wrapper SIGTERM forward 후 native 응답 대기.
#                                 양수 정수만 허용. 상한 60초.
#   CODEX_EXEC_TIMEOUT_BIN        timeout binary absolute path. 미설정 시 PATH 검색 후 부재면 BLOCKED.
#                                 Nix wrapper가 ${pkgs.coreutils}/bin/timeout으로 set한다.
#   CODEX_EXEC_SETSID_BIN         setsid binary absolute path. 미설정 시 PATH 검색 후 부재면 BLOCKED.
#                                 부재 fail-closed (process group kill 보장이 본 wrapper의 핵심 경계).
#                                 진단용 timeout-only 실행이 필요하면 본 wrapper를 우회해 timeout/codex를
#                                 직접 호출한다 (보장 약화는 wrapper 인터페이스 안에 흡수하지 않는다).
#                                 Nix wrapper가 ${pkgs.util-linux}/bin/setsid로 set한다.
#
# Exit code:
#   0          정상
#   124        timeout 발동 (SIGTERM)
#   137        SIGKILL (timeout --kill-after)
#   127        capability-probe 실패 (codex/timeout/setsid 부재 또는 invalid env). BLOCKED 신호.
#   기타       codex 자체 exit code

set -euo pipefail

# 환경변수 검증 helper. 양수 정수만 허용.
_validate_positive_int() {
  local name="$1" val="$2" upper="$3"
  if ! [[ "$val" =~ ^[1-9][0-9]*$ ]]; then
    printf 'codex-exec-supervised: %s=%s — 양수 정수만 허용\n' "$name" "$val" >&2
    return 1
  fi
  if (( val > upper )); then
    printf 'codex-exec-supervised: %s=%d 가 상한(%d)을 초과\n' "$name" "$val" "$upper" >&2
    return 1
  fi
  return 0
}

CODEX_EXEC_TIMEOUT_SECONDS="${CODEX_EXEC_TIMEOUT_SECONDS:-1800}"
CODEX_EXEC_KILL_AFTER_SECONDS="${CODEX_EXEC_KILL_AFTER_SECONDS:-5}"
_validate_positive_int CODEX_EXEC_TIMEOUT_SECONDS "$CODEX_EXEC_TIMEOUT_SECONDS" 7200 || exit 127
_validate_positive_int CODEX_EXEC_KILL_AFTER_SECONDS "$CODEX_EXEC_KILL_AFTER_SECONDS" 60 || exit 127

# timeout binary resolution: env var(absolute path) 우선, fallback PATH 검색.
TIMEOUT_BIN="${CODEX_EXEC_TIMEOUT_BIN:-}"
if [[ -z "$TIMEOUT_BIN" ]]; then
  if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_BIN="$(command -v timeout)"
  elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_BIN="$(command -v gtimeout)"
  else
    printf 'codex-exec-supervised: timeout/gtimeout 부재 (CODEX_EXEC_TIMEOUT_BIN 미설정) — BLOCKED, exit 127\n' >&2
    exit 127
  fi
fi
if [[ ! -x "$TIMEOUT_BIN" ]]; then
  printf 'codex-exec-supervised: TIMEOUT_BIN=%s 가 실행 불가 — exit 127\n' "$TIMEOUT_BIN" >&2
  exit 127
fi

# setsid binary resolution: env var(absolute path) 우선, fallback PATH 검색.
# 부재 시 fail-closed (보안 경계: process group kill 보장이 본 wrapper의 핵심).
# 진단 목적의 timeout-only 실행은 본 wrapper를 우회해 직접 timeout/codex를 호출한다.
SETSID_BIN="${CODEX_EXEC_SETSID_BIN:-}"
if [[ -z "$SETSID_BIN" ]] && command -v setsid >/dev/null 2>&1; then
  SETSID_BIN="$(command -v setsid)"
fi
if [[ -z "$SETSID_BIN" ]] || [[ ! -x "$SETSID_BIN" ]]; then
  printf 'codex-exec-supervised: setsid 부재 (CODEX_EXEC_SETSID_BIN 미설정) — BLOCKED, exit 127\n' >&2
  exit 127
fi

# codex 가용성 점검
if ! command -v codex >/dev/null 2>&1; then
  printf 'codex-exec-supervised: codex 바이너리 부재 — exit 127\n' >&2
  exit 127
fi

# wrapper-level capability probe (사전점검용 — codex exec를 호출하지 않고 의존성만 검증).
# 모든 dependency(setsid/timeout/codex) resolution이 위에서 통과했으므로 여기서 exit 0이면 OK 신호다.
# 사전점검 callsite (parallel-audit/codex-fan-out preflight)는 `codex-exec-supervised --check`로 호출한다.
if [[ "${1:-}" == "--check" ]]; then
  printf 'codex-exec-supervised: dependencies OK (timeout=%s setsid=%s codex=%s)\n' \
    "$TIMEOUT_BIN" "$SETSID_BIN" "$(command -v codex)" >&2
  exit 0
fi

# Execute with supervisor.
# stdin은 caller가 처리한다 (pipe 또는 redirect). 본 wrapper는 inherit.
# 핵심: PATH는 변경하지 않는다. timeout/setsid는 absolute path로 직접 호출하여 codex exec child shell
# 의 user PATH(BSD coreutils 우선)를 보존한다.
# `setsid --wait`: setsid가 fork 경로(호출 프로세스가 process group leader인 경우)를 타면 자식 종료를
# 기다려 자식의 exit status를 반환한다. 옵션이 없으면 timeout이 발생시킨 124/137이 wrapper 종료
# status로 전달되지 않을 수 있다 (util-linux setsid(1) -w 참조).
exec "$SETSID_BIN" --wait "$TIMEOUT_BIN" \
  --kill-after="$CODEX_EXEC_KILL_AFTER_SECONDS" \
  "$CODEX_EXEC_TIMEOUT_SECONDS" \
  codex exec "$@"
