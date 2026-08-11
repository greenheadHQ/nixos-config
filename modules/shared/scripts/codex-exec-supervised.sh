#!/usr/bin/env bash
# codex-exec-supervised — capability-probe based supervisor wrapper for codex exec
#
# Background (issue #593): codex exec --ephemeral는 prompt 인수가 있어도 stdin이 piped면
# read_prompt_from_stdin(StdinPromptBehavior::OptionalAppend)가 EOF 미도달 시 무기한 wait한다.
# 이 동작은 upstream 미해결이다 (openai/codex#20919, #27019 — 2026-08 기준 OPEN, opt-out
# 플래그 없음). stdin EOF 보장은 호출자 책임이고(아래 "stdin 처리 책임"), 본 wrapper는 그
# 규약이 깨졌을 때의 폭발 반경을 timeout으로 유한하게 만든다.
#
# 역사 각주: 도입 당시(2026-05, PR #636)는 npm wrapper(@openai/codex) 패키징의 detach/process
# group 부재로 "timeout이 wrapper PID만 죽이고 native가 잔존"하는 축이 있어 setsid를 채택했다.
# 현행 패키징(modules/shared/programs/codex/ — upstream tarball의 native binary 직핀)에는 중간
# npm 프로세스가 없어 그 실패 모드는 소멸했고, 2026-08 mac+Linux 분리 실측에서 process group은
# GNU timeout 자신이 생성하며(비-foreground 모드) SIGTERM 무시 hang의 유일한 구제는
# --kill-after(SIGKILL 승급)임이 확인됐다. setsid 의존 제거는 후속 PR에서 real-codex Linux
# 재확인 후 진행한다 — 그 전까지 기존 fail-closed 동작을 유지한다.
#
# mac BSD coreutils에는 timeout이 없고 setsid도 없으므로, Nix wrapper(modules/shared/programs/
# shell/default.nix의 home.file + pkgs.writeShellScript)가 두 binary의 absolute store path를
# CODEX_EXEC_TIMEOUT_BIN과 CODEX_EXEC_SETSID_BIN env 변수에 export한 뒤 본 raw script를 exec한다.
# 이로써 wrapper subprocess의 PATH가 GNU coreutils로 오염되지 않고, codex exec 자식 shell도
# 원래 user PATH(BSD coreutils 우선)를 보존한다.
#
# stdin 처리 책임: 호출자가 명시적으로 처리 (`cat prompt.md | codex-exec-supervised ... -` 또는
# `codex-exec-supervised ... < /dev/null`). 본 wrapper는 stdin을 inherit한다.
#
# 사용 (Layer 1 supervised contract — programmatic 호출의 canonical pattern):
#   cat prompt.md | codex-exec-supervised --sandbox read-only --ignore-user-config --ignore-rules --ephemeral \
#     -c model_reasoning_effort="medium" -o result.md -
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
#                                 rationale: SIGTERM 수신 후 codex의 자체 정리 시간. SIGTERM이
#                                 무시되는 hang에서는 이 SIGKILL 승급이 유일한 구제임이 실측
#                                 확인됐다 (2026-08 hazard 분리 실험). 양수 정수만 허용. 상한 60초.
#   CODEX_EXEC_TIMEOUT_BIN        timeout binary absolute path. 미설정 시 PATH 검색 후 부재면 BLOCKED.
#                                 Nix wrapper가 ${pkgs.coreutils}/bin/timeout으로 set한다.
#   CODEX_EXEC_SETSID_BIN         setsid binary absolute path. 미설정 시 PATH 검색 후 부재면 BLOCKED.
#                                 부재 fail-closed. 주의: 2026-08 실측에서 setsid는 종료 보장에
#                                 기여하지 않음이 확인됐다 (process group은 timeout이 생성 — 헤더
#                                 역사 각주 참조). 제거는 후속 PR 범위이며 그 전까지 기존 동작 유지.
#                                 진단용 timeout-only 실행이 필요하면 본 wrapper를 우회해 timeout/codex를
#                                 직접 호출한다 (보장 약화는 wrapper 인터페이스 안에 흡수하지 않는다).
#                                 Nix wrapper가 ${pkgs.util-linux}/bin/setsid로 set한다.
#
#   정본 4개의 계열 이름(TIMEOUT/KILL_AFTER/SETSID 접두)이면서 정확 불일치인 CODEX_EXEC_*
#   변수는 fail-closed로 거부한다 (exit 127) — 정본 변수명 오타(예: CODEX_EXEC_TIMEOUT=1500,
#   _SECONDS 누락)가 침묵으로 무시되어 호출 의도가 소실되는 사고 방지 (2026-08-06 실사례).
#   주의: CODEX_EXEC_ 접두사 전체는 wrapper 소유가 아니다 — upstream codex 자신이
#   CODEX_EXEC_SERVER_*(exec-server 서브커맨드의 env 바인딩: URL/EXIT_ON_STDIN_CLOSE/
#   NOISE_* 등)를 예약하므로, 계열 밖 변수는 검사 없이 통과시킨다.
#
# Exit code:
#   0          정상
#   124        timeout 발동 (SIGTERM)
#   137        SIGKILL (timeout --kill-after)
#   127        capability-probe 실패 (codex/timeout/setsid 부재 또는 invalid env). BLOCKED 신호.
#   기타       codex 자체 exit code

set -euo pipefail

# 정본 변수명 near-miss fail-fast. 반드시 본 스크립트의 어떤 CODEX_EXEC_* 셸 변수 할당보다
# 먼저 실행한다 — 이 시점의 ${!CODEX_EXEC_@}는 환경에서 상속된 이름만 열거한다.
# 거부 범위는 정본 4개의 계열 이름(TIMEOUT/KILL_AFTER/SETSID 접두)뿐이다 — CODEX_EXEC_ 접두사
# 전체를 거부하면 upstream codex가 예약한 CODEX_EXEC_SERVER_*(exec-server env 바인딩)까지
# 오발동으로 차단한다 (헤더 참조).
_KNOWN_CODEX_EXEC_VARS=" CODEX_EXEC_TIMEOUT_SECONDS CODEX_EXEC_KILL_AFTER_SECONDS CODEX_EXEC_TIMEOUT_BIN CODEX_EXEC_SETSID_BIN "
for _codex_exec_var in "${!CODEX_EXEC_@}"; do
  if [[ "$_KNOWN_CODEX_EXEC_VARS" == *" $_codex_exec_var "* ]]; then
    continue
  fi
  case "$_codex_exec_var" in
    CODEX_EXEC_TIMEOUT*|CODEX_EXEC_KILL_AFTER*|CODEX_EXEC_SETSID*)
      printf 'codex-exec-supervised: %s 는 정본 변수명이 아님 (오타 의심) — 허용:%s(exit 127)\n' \
        "$_codex_exec_var" "$_KNOWN_CODEX_EXEC_VARS" >&2
      exit 127
      ;;
  esac
done

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
# 부재 시 fail-closed (기존 계약 유지). 근거·현행 실측은 헤더 역사 각주와
# CODEX_EXEC_SETSID_BIN 항목 참조 — 2026-08 실측상 setsid는 종료 보장에 기여하지
# 않으며(process group은 timeout이 생성), 제거는 후속 PR 범위다.
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
# 사전점검 callsite (run-da(audit) preflight)는 `codex-exec-supervised --check`로 호출한다.
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
