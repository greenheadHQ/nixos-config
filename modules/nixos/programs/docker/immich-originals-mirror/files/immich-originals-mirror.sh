#!/usr/bin/env bash
# modules/nixos/programs/docker/immich-originals-mirror/files/immich-originals-mirror.sh
# Immich 원본 사진/영상을 SSD(upload-cache) → HDD로 일일 rsync 미러링.
# 원본이 disko 포맷 대상 SSD에만 존재하는 "무백업 단독 존재"를 해소한다(백업 자세 시정).
# oneshot systemd service가 SRC_DIR/DEST_DIR/PUSHOVER_CRED_FILE/SERVICE_LIB를 주입한다.
#
# 삭제 전파(--delete) 결정: 이 미러는 원본의 삭제를 그대로 따라간다(진짜 미러).
# 실수 삭제 방어는 Immich 앱 휴지통(기본 30일)과 오프사이트 계층(별도 plan)의 몫이라는
# 계층 설계를 따른다 — 이 스크립트 자체는 지연 삭제(--backup-dir)를 하지 않는다.
set -euo pipefail

# service-lib.sh 로드(send_notification) + Pushover 자격
# shellcheck source=/dev/null
source "$PUSHOVER_CRED_FILE"
# shellcheck source=/dev/null
source "$SERVICE_LIB"

# 에러 핸들러: 실패 시에만 Pushover 알림 (성공 시 무알림)
cleanup_on_error() {
  local exit_code=$?
  if [ "$exit_code" -ne 0 ]; then
    send_notification "Immich Originals Mirror" \
      "원본 미러 실패 (exit $exit_code). journalctl -u immich-originals-mirror 확인 필요." 1
  fi
}
trap cleanup_on_error EXIT

echo "=== Immich originals mirror start: $(date -Iseconds) ==="

# 1. 소스 가드(핵심 데이터 보존 계약) — SRC_DIR이 존재하고 비어있지 않아야 한다.
#    빈 소스로 `rsync --delete`를 돌리면 목적지 전체가 삭제되므로(데이터 소실),
#    소스가 비어 보이면(컨테이너 중지·마운트 누락 등) 미러를 실행하지 않고 중단한다.
# shellcheck disable=SC2012  # 파일명 파싱이 아니라 "비었는지"만 판정하므로 목록 나열로 충분
if [ ! -d "$SRC_DIR" ] || [ -z "$(ls -A "$SRC_DIR")" ]; then
  echo "ERROR: Source empty or missing: $SRC_DIR (미러 중단 — 빈 소스로 목적지 삭제 방지)" >&2
  exit 1
fi

# 2. 마운트 가드 (#1369) — 대상 HDD는 nofail이라 미마운트여도 부팅은 계속된다. 이 검사가
#    없으면 MOUNT_ROOT가 루트 파일시스템의 일반 디렉터리로 존재하는 상태에서도 미러가
#    SSD에 쓰이고(--delete까지 실행되어) 성공으로 오인될 수 있다. systemd RequiresMountsFor가
#    1차 방어이고, 이 스크립트를 직접 실행하는 경로(수동 디버깅 등)를 위한 2차 방어다.
#    목적지를 아직 만들기(mkdir) 전에 검사해야 한다 — mkdir 자체도 쓰기다.
if ! mountpoint -q "$MOUNT_ROOT"; then
  echo "ERROR: $MOUNT_ROOT is not a mount point (target HDD not mounted) — 목적지 쓰기 중단" >&2
  exit 1
fi
echo "Mount check OK: $MOUNT_ROOT is mounted"

# 3. 목적지 소속 가드 — MOUNT_ROOT가 마운트돼 있어도 DEST_DIR이 그 아래가 아니면(설정
#    오류) 마운트 확인만으로는 잡지 못한다. 경로 문자열상 DEST_DIR이 MOUNT_ROOT 아래인지만
#    본다(디렉터리 경계 기준 접두 비교) — `..`·심볼릭 링크·중첩 마운트까지 해석하는 실제
#    파일시스템 소속 판정은 아니다. mkdir 전에 검사해야 한다 — mkdir 자체도 쓰기다.
case "$DEST_DIR/" in
  "$MOUNT_ROOT"/*) ;;
  *)
    echo "ERROR: DEST_DIR ($DEST_DIR) is not under MOUNT_ROOT ($MOUNT_ROOT) — 목적지 쓰기 중단" >&2
    exit 1
    ;;
esac

# 4. 목적지 준비 + 디스크 여유 하한(플로어) 검사.
#    하한 가드일 뿐이며, 초회 전체 복사에 필요한 정확한 용량 부족은 rsync가 자체 종료
#    코드로 잡는다(아래 6번). immich-backup.nix의 5GB 검사 패턴을 준용한다.
mkdir -p "$DEST_DIR"
AVAIL_KB=$(df --output=avail "$DEST_DIR" | tail -1)
AVAIL_GB=$((AVAIL_KB / 1024 / 1024))
if [ "$AVAIL_GB" -lt 5 ]; then
  echo "ERROR: Destination disk space low (${AVAIL_GB}GB available, need >=5GB floor)" >&2
  exit 1
fi
echo "Destination disk space OK: ${AVAIL_GB}GB available"

# 5. rsync 미러 실행 (--delete: 삭제 전파, 상단 주석의 계층 설계 근거).
#    --stats 요약은 stdout으로 journald에 남긴다.
echo "Running rsync mirror: $SRC_DIR/ -> $DEST_DIR/"
RSYNC_RC=0
rsync --archive --delete --human-readable --stats "$SRC_DIR/" "$DEST_DIR/" || RSYNC_RC=$?

# 6. rsync 종료 코드 처리.
#    0  = 정상.
#    24 = 전송 중 소스 파일이 사라짐(라이브 업로드 중 파일 이동은 자연 현상) → 경고 후 정상.
#    그 외 non-zero = 실패(trap이 Pushover 알림).
if [ "$RSYNC_RC" -eq 0 ]; then
  echo "Mirror completed cleanly."
elif [ "$RSYNC_RC" -eq 24 ]; then
  echo "WARN: rsync exit 24 (source files vanished during transfer) — treated as success."
else
  echo "ERROR: rsync failed (exit $RSYNC_RC)" >&2
  exit "$RSYNC_RC"
fi

echo "=== Immich originals mirror completed: $(date -Iseconds) ==="
