# shellcheck shell=bash
# 로컬 private job 정의(~/.local/private-jobs/<slug>/schedule)를 systemd user
# timer로 동기화한다 — 작업 discovery·스케줄은 전부 이 런타임 스캔에서만 읽는다.
# Nix eval은 로컬 작업 디렉터리를 읽지 않으므로 store·repo에는 작업 정보가 0건이다.
#
# 생성물: $XDG_CONFIG_HOME/systemd/user/private-job-<slug>.timer (managed 헤더로
# 표식). 정의가 사라진 timer는 disable 후 삭제한다. schedule이 잘못된 작업은
# quiet skip이 아니다 — sync-error marker로 1회 알림(정상화 시 marker 해제)하고
# sync 자체를 failed unit로 끝낸다.
#
# 필요 env (unit이 주입): PUSHOVER_LIB, PUSHOVER_CRED_FILE
set -euo pipefail
umask 0077

JOBS_ROOT="$HOME/.local/private-jobs"
STATE_ROOT="$HOME/.local/state/private-jobs"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
MANAGED_MARK="# managed by private-jobs-sync"

# shellcheck source=/dev/null
source "$PUSHOVER_LIB"

changed=0
invalid=0

job_error() { # slug detail — 같은 오류의 반복 알림은 marker로 dedupe한다
  local slug="$1" detail="$2"
  local marker="$STATE_ROOT/$slug/sync-error"
  echo "ERROR: job=$slug $detail" >&2
  invalid=1
  if [ ! -f "$marker" ]; then
    mkdir -p "$STATE_ROOT/$slug"
    printf '%s\n' "$detail" > "$marker"
    pushover_send "$PUSHOVER_CRED_FILE" "private job sync error" "job=$slug $detail" 1 \
      || echo "WARNING: sync error notification could not be sent" >&2
  fi
}

job_ok() { # slug — 오류가 해소되면 marker를 걷어 다음 오류가 다시 알림되게 한다
  rm -f "$STATE_ROOT/$1/sync-error"
}

mkdir -p "$UNIT_DIR"

# ── 현재 정의된 작업 → timer 생성/갱신
declare -A want=()
if [ -d "$JOBS_ROOT" ]; then
  for job_dir in "$JOBS_ROOT"/*/; do
    [ -d "$job_dir" ] || continue
    slug="$(basename "$job_dir")"
    if ! [[ "$slug" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]]; then
      job_error "invalid" "invalid slug directory"
      continue
    fi
    if [ -L "${job_dir%/}" ] || [ ! -O "$job_dir" ]; then
      job_error "$slug" "job directory is a symlink or not owned by user"
      continue
    fi
    if [ ! -f "$job_dir/schedule" ]; then
      job_error "$slug" "schedule file missing"
      continue
    fi
    schedule="$(head -1 "$job_dir/schedule")"
    if ! systemd-analyze calendar "$schedule" >/dev/null 2>&1; then
      job_error "$slug" "invalid OnCalendar expression"
      continue
    fi
    job_ok "$slug"
    want["$slug"]=1

    unit_file="$UNIT_DIR/private-job-$slug.timer"
    # Persistent=true — 꺼져 있던 동안 놓친 스케줄을 부팅 후 따라잡는다 (재부팅
    # 복구는 linger + timers.target 재진입과 함께 실기기 smoke가 검증한다).
    content="$MANAGED_MARK
[Unit]
Description=private job timer (%I)

[Timer]
OnCalendar=$schedule
Persistent=true
Unit=private-job@$slug.service

[Install]
WantedBy=timers.target
"
    content="${content//%I/$slug}"
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
    systemctl --user disable --now "$base.timer" >/dev/null 2>&1 || true
    rm -f "$unit_file"
    changed=1
  fi
done

if [ "$changed" -eq 1 ]; then
  systemctl --user daemon-reload
fi
for slug in "${!want[@]}"; do
  systemctl --user enable --now "private-job-$slug.timer" >/dev/null 2>&1 \
    || job_error "$slug" "timer enable failed"
done

[ "$invalid" -eq 0 ] || exit 1
echo "sync ok: ${#want[@]} job(s)"
