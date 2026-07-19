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
# 필요 env (unit이 주입): PUSHOVER_LIB, PUSHOVER_CRED_FILE,
#   PRIVATE_JOBS_DEFINITIONS, PRIVATE_JOBS_STATE (HOME 상대)
set -euo pipefail
umask 0077

JOBS_ROOT="$HOME/$PRIVATE_JOBS_DEFINITIONS"
STATE_ROOT="$HOME/$PRIVATE_JOBS_STATE"
UNIT_DIR="${XDG_RUNTIME_DIR:?}/systemd/user"
ERROR_DIR="$STATE_ROOT/.sync-errors"
MANAGED_MARK="# managed by private-jobs-sync"

# shellcheck source=/dev/null
source "$PUSHOVER_LIB"

sync_failed=0            # 모든 종류의 sync 오류(정의·enable 실패 포함)의 집계 플래그
declare -A error_seen=() # 이번 run에서 관측된 오류 key — 종료 시 나머지 marker 해제

job_error() { # key detail — 같은 key의 "같은 내용" 오류만 억제한다 (내용이
  # 바뀌면 새 알림, 해소되면 marker가 걷혀 재발 시 다시 알림).
  local key detail marker
  key="$(printf '%s' "$1" | tr -c 'a-zA-Z0-9-' '_')"
  detail="$2"
  marker="$ERROR_DIR/$key"
  echo "ERROR: job=$1 $detail" >&2
  sync_failed=1
  error_seen["$key"]=1
  if [ ! -f "$marker" ] || [ "$(cat "$marker")" != "$detail" ]; then
    mkdir -p "$ERROR_DIR"
    printf '%s' "$detail" > "$marker"
    pushover_send "$PUSHOVER_CRED_FILE" "private job sync error" "job=$1 $detail" 1 \
      || echo "WARNING: sync error notification could not be sent" >&2
  fi
}

mkdir -p "$UNIT_DIR"

# ── 현재 정의된 작업 → timer 생성/갱신
declare -A want=()
if [ -d "$JOBS_ROOT" ]; then
  for job_dir in "$JOBS_ROOT"/*/; do
    [ -d "$job_dir" ] || continue
    slug="$(basename "$job_dir")"
    if ! [[ "$slug" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]]; then
      job_error "$slug" "invalid slug directory"
      continue
    fi
    if [ -L "${job_dir%/}" ] || [ ! -O "$job_dir" ]; then
      job_error "$slug" "job directory is a symlink or not owned by user"
      continue
    fi
    schedule_file="$job_dir/schedule"
    # schedule도 실행 계약의 입력이다 — run.sh와 같은 소유·링크 기준을 요구한다.
    if [ ! -f "$schedule_file" ] || [ -L "$schedule_file" ] || [ ! -O "$schedule_file" ]; then
      job_error "$slug" "schedule missing, symlink, or not owned by user"
      continue
    fi
    schedule="$(head -1 "$schedule_file")"
    if ! systemd-analyze calendar "$schedule" >/dev/null 2>&1; then
      job_error "$slug" "invalid OnCalendar expression"
      continue
    fi

    unit_file="$UNIT_DIR/private-job-$slug.timer"
    # 같은 이름의 비관리 unit이 이미 있으면 덮지 않는다 — managed 헤더 검사는
    # 제거 단계만이 아니라 생성 단계에도 적용해야 "사용자 unit 불가침" 계약이 선다.
    if [ -e "$unit_file" ] && { [ -L "$unit_file" ] || ! head -1 "$unit_file" | grep -qF "$MANAGED_MARK"; }; then
      job_error "$slug" "timer name collision with unmanaged unit"
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

# ── 정의가 사라진 managed timer 제거 (managed 헤더가 있는 것만 — 사용자가 직접
# 만든 unit은 건드리지 않는다)
for unit_file in "$UNIT_DIR"/private-job-*.timer; do
  [ -f "$unit_file" ] || continue
  head -1 "$unit_file" | grep -qF "$MANAGED_MARK" || continue
  base="$(basename "$unit_file" .timer)"
  slug="${base#private-job-}"
  if [ -z "${want[$slug]:-}" ]; then
    systemctl --user stop "$base.timer" >/dev/null 2>&1 || true
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
# 알림되게 한다.
if [ -d "$ERROR_DIR" ]; then
  for marker in "$ERROR_DIR"/*; do
    [ -f "$marker" ] || continue
    key="$(basename "$marker")"
    [ -n "${error_seen[$key]:-}" ] || rm -f "$marker"
  done
fi

[ "$sync_failed" -eq 0 ] || exit 1
echo "sync ok: ${#want[@]} job(s)"
