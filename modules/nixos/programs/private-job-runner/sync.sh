# shellcheck shell=bash
# 로컬 private job 정의(<definitions>/<slug>/schedule)를 systemd user timer로
# 동기화한다 — 작업 discovery·스케줄은 전부 이 런타임 스캔에서만 읽는다.
# Nix eval은 로컬 작업 디렉터리를 읽지 않으므로 store·repo에는 작업 정보가 0건이다.
#
# 생성물은 user *runtime* unit 영역($XDG_RUNTIME_DIR/systemd/user)에 둔다 —
# 영속 config 영역에 쓰면 모듈 비활성화·롤백 후 sync가 사라졌을 때 timer를 정리할
# 주체가 없어 영구 잔존한다. runtime 영역은 재부팅에 소거되고, 활성 상태에서는
# 부팅 2분 뒤 sync가 재생성한다 (Persistent의 놓친 스케줄 기록은 unit 파일 위치와
# 무관한 systemd timer stamp가 소유하므로 유지된다). 비활성화 후 재부팅 전까지의
# 잔존은 수용한다 — 다음 부팅이 소거 지점이다.
#
# schedule이 잘못된 작업은 quiet skip이 아니다 — 오류 내용 기반 marker로 같은
# 오류만 억제해 1회 알림(내용이 바뀌면 다시 알림, 해소되면 자동 해제)하고 sync를
# failed unit로 끝낸다.
#
# 필요 env (unit이 주입): PRIVATE_JOB_LIB, PUSHOVER_LIB, PUSHOVER_CRED_FILE,
#   PRIVATE_JOBS_DEFINITIONS, PRIVATE_JOBS_STATE (HOME 상대)
set -euo pipefail
umask 0077

# shellcheck source=/dev/null
source "$PRIVATE_JOB_LIB"
# shellcheck source=/dev/null
source "$PUSHOVER_LIB"

JOBS_ROOT="$HOME/$PRIVATE_JOBS_DEFINITIONS"
STATE_ROOT="$HOME/$PRIVATE_JOBS_STATE"
UNIT_DIR="${XDG_RUNTIME_DIR:?}/systemd/user"
ERROR_DIR="$STATE_ROOT/.sync-errors"
MANAGED_MARK="# managed by private-jobs-sync"

changed=0                # unit 생성·갱신·삭제 발생 여부 (daemon-reload 필요 판단)
sync_failed=0            # 정의·collision·start 실패를 포함한 모든 sync 오류의 집계 플래그
declare -A error_seen=() # 이번 run에서 관측된 오류 key — 종료 시 나머지 marker 해제

job_error() { # key detail — 같은 key의 "같은 내용" 오류만 억제한다 (내용이
  # 바뀌면 새 알림, 해소되면 marker가 걷혀 재발 시 다시 알림).
  local key detail marker err_dir_violation
  key="$(printf '%s' "$1" | tr -c 'a-zA-Z0-9-' '_')"
  detail="$2"
  marker="$ERROR_DIR/$key"
  # marker와 그 부모가 symlink면 읽지도 쓰지도 않는다 — 링크 대상을 따라가
  # 임의 경로를 읽고 덮어쓸 수 있다.
  if [ -L "$ERROR_DIR" ] || [ -L "$marker" ]; then
    echo "ERROR: job=$1 $detail" >&2
    echo "WARNING: sync-error marker is a symlink — dedupe 생략" >&2
    sync_failed=1
    error_seen["$key"]=1
    return 0
  fi
  echo "ERROR: job=$1 $detail" >&2
  sync_failed=1
  error_seen["$key"]=1
  if [ ! -f "$marker" ] || [ "$(cat "$marker")" != "$detail" ]; then
    # marker는 "알림이 실제로 나간 뒤"에만 기록한다 — 먼저 기록하면 전송 실패가
    # "알림 완료"로 남아 같은 오류의 재시도가 영구 억제된다.
    if pushover_send "$PUSHOVER_CRED_FILE" "private job sync error" "job=$1 $detail" 1; then
      mkdir -p "$ERROR_DIR"
      err_dir_violation="$(path_violation_reason "$ERROR_DIR" "sync error dir" d 077)"
      if [ -z "$err_dir_violation" ]; then
        printf '%s' "$detail" > "$marker"
      else
        echo "WARNING: $err_dir_violation — marker 기록 생략" >&2
      fi
    else
      echo "WARNING: sync error notification could not be sent" >&2
    fi
  fi
}

# 이름이 규약 밖인 디렉터리는 그 이름 자체가 작업 실체를 담고 있을 수 있다 —
# journal·외부 알림에는 실명 대신 이름의 해시 앞 8자만 내보낸다.
masked_name() { printf 'withheld-%s' "$(printf '%s' "$1" | sha256sum | cut -c1-8)"; }

# runtime 파일 존재만 보면 상위 우선 경로(~/.config, /etc/systemd/user 등)의
# 동명 unit에 shadow된다 — systemd가 실제로 로드하는 FragmentPath로 판정해
# "내 runtime 파일이 아닌 unit"을 건드리지 않는다.
loaded_fragment() { # unit-name → FragmentPath (미로드면 빈 출력)
  systemctl --user show -p FragmentPath --value "$1" 2>/dev/null || true
}

mkdir -p "$UNIT_DIR"

# 발화 대상 template 자체가 shadow되면 모든 작업이 runner·hardening·알림 계약
# 밖에서 실행된다 — NixOS 선언 경로(store 링크·/etc/systemd/user)가 아니면 전면
# 중단한다.
template_fragment="$(loaded_fragment "private-job@.service")"
case "$template_fragment" in
  "" | /nix/store/* | /etc/systemd/user/*) : ;;
  *) job_error "template" "private-job@ template shadowed by unmanaged unit" ;;
esac

# ── 현재 정의된 작업 → timer 생성/갱신
declare -A want=()
if [ -d "$JOBS_ROOT" ]; then
  # 스캔 대상 루트 자체도 실행 입력이다 — symlink·타 owner·느슨한 권한이면 스캔
  # 전체를 중단한다 (fail-closed).
  root_violation="$(path_violation_reason "$JOBS_ROOT" "jobs root" d 022)"
  if [ -n "$root_violation" ]; then
    job_error "jobs-root" "$root_violation"
  else
    for job_dir in "$JOBS_ROOT"/*/; do
      [ -d "$job_dir" ] || continue
      slug="$(basename "$job_dir")"
      if ! is_valid_slug "$slug"; then
        job_error "$(masked_name "$slug")" "invalid slug directory (name withheld)"
        continue
      fi
      violation="$(path_violation_reason "${job_dir%/}" "job directory" d 022)"
      if [ -n "$violation" ]; then
        job_error "$slug" "$violation"
        continue
      fi
      # job_dir는 glob("$JOBS_ROOT"/*/)에서 와 트레일링 슬래시를 포함한다 — 그대로
      # 이어 붙이면 "…//schedule"이 되고, realpath 정규화(단일 슬래시)와 달라져
      # canonical 검증이 정상 경로를 오탐 거부한다 (실기기 발현).
      schedule_file="${job_dir%/}/schedule"
      # schedule도 실행 계약의 입력이다 — run.sh와 같은 소유·링크·권한 기준을 요구한다.
      violation="$(path_violation_reason "$schedule_file" "schedule" f 022)"
      if [ -n "$violation" ]; then
        job_error "$slug" "schedule: $violation"
        continue
      fi
      # "1줄 파일" 계약을 실제로 검증한다 — 첫 줄만 조용히 소비하면 운영자는
      # 나머지 내용도 반영됐다고 오해한다.
      if [ -n "$(sed -n '2,$p' "$schedule_file" | tr -d '[:space:]')" ]; then
        job_error "$slug" "schedule must be a single line"
        continue
      fi
      schedule="$(head -1 "$schedule_file")"
      if ! systemd-analyze calendar "$schedule" >/dev/null 2>&1; then
        job_error "$slug" "invalid OnCalendar expression"
        continue
      fi

      unit_file="$UNIT_DIR/private-job-$slug.timer"
      # 같은 이름의 비관리 unit(상위 우선 경로 포함)이 로드되면 덮지도 조작하지도
      # 않는다 — managed 생성물은 내 runtime 파일이 FragmentPath일 때만 관리한다.
      fragment="$(loaded_fragment "private-job-$slug.timer")"
      if [ -n "$fragment" ] && [ "$fragment" != "$unit_file" ]; then
        job_error "$slug" "timer name collision with unmanaged unit"
        continue
      fi
      # timer가 발화할 service 인스턴스도 shadow 검사 — timer만 검사하면 실행
      # 자체가 unmanaged unit으로 넘어간다.
      svc_fragment="$(loaded_fragment "private-job@$slug.service")"
      case "$svc_fragment" in
        "" | /nix/store/* | /etc/systemd/user/*) : ;;
        *) job_error "$slug" "service name collision with unmanaged unit"; continue ;;
      esac
      # -L을 먼저 본다 — dangling symlink는 -e가 false라 뒤에 두면 검사를 통과해
      # printf가 링크 대상(runtime 영역 밖)에 파일을 만들 수 있다.
      if [ -L "$unit_file" ] || { [ -e "$unit_file" ] && ! head -1 "$unit_file" | grep -qF "$MANAGED_MARK"; }; then
        job_error "$slug" "timer name collision with unmanaged runtime file"
        continue
      fi
      want["$slug"]=1

      content="$MANAGED_MARK
[Unit]
Description=private job timer ($slug)

[Timer]
OnCalendar=$schedule
Persistent=true
Unit=private-job@$slug.service
"
      if [ ! -f "$unit_file" ] || [ "$(cat "$unit_file")" != "$(printf '%s' "$content")" ]; then
        printf '%s' "$content" > "$unit_file"
        changed=1
      fi
    done
  fi
fi

# ── 정의가 사라진 managed timer 제거 (managed 헤더 + 실제 로드 경로가 내 파일일
# 때만 stop — 사용자·HM unit은 건드리지 않는다)
for unit_file in "$UNIT_DIR"/private-job-*.timer; do
  [ -f "$unit_file" ] || continue
  head -1 "$unit_file" | grep -qF "$MANAGED_MARK" || continue
  base="$(basename "$unit_file" .timer)"
  slug="${base#private-job-}"
  if [ -z "${want[$slug]:-}" ]; then
    if [ "$(loaded_fragment "$base.timer")" = "$unit_file" ]; then
      # stop이 실패하면 파일을 지우지 않는다 — active timer가 manager 메모리에서
      # 계속 발화하는 유령 상태를 만들지 않고 다음 sync가 재시도하게 한다.
      if ! systemctl --user stop "$base.timer" >/dev/null 2>&1; then
        job_error "$slug" "timer stop failed (unit file preserved for retry)"
        continue
      fi
    fi
    rm -f "$unit_file"
    changed=1
  fi
done

if [ "${changed:-0}" -eq 1 ]; then
  systemctl --user daemon-reload
fi
# runtime unit은 enable(영속 링크)이 아니라 start로 상주시킨다 — 재부팅 후에는
# 이 sync가 다시 생성·start한다 (부팅 복구 경로).
for slug in "${!want[@]}"; do
  systemctl --user start "private-job-$slug.timer" >/dev/null 2>&1 \
    || job_error "$slug" "timer start failed"
done

# ── 이번 run에서 관측되지 않은 오류 marker 해제 — 해소된 오류가 재발하면 다시
# 알림되게 한다 (부모가 symlink면 대상 디렉터리의 파일을 지울 수 있어 건드리지
# 않는다).
if [ -d "$ERROR_DIR" ] && [ ! -L "$ERROR_DIR" ]; then
  for marker in "$ERROR_DIR"/*; do
    [ -f "$marker" ] || continue
    key="$(basename "$marker")"
    [ -n "${error_seen[$key]:-}" ] || rm -f "$marker"
  done
fi

# 의도된 실패(정의 오류 등 — 개별 알림 완료)는 SYNC_HANDLED_EXIT(값 소유:
# default.nix)로 구분한다: unit의 ExecStopPost는 이 코드를 보고 이중 알림을
# 건너뛰고, 비정형 실패(set -e의 다른 종료)만 통지한다.
[ "$sync_failed" -eq 0 ] || exit "${SYNC_HANDLED_EXIT:?}"
echo "sync ok: ${#want[@]} job(s)"
