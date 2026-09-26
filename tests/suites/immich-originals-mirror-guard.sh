# tests/suites/immich-originals-mirror-guard.sh — 도메인 테스트 정의 (sourced; aggregator가 lib/test-common.sh 후 source)
# shellcheck shell=bash
# SC2154: 공통 변수(REPO_ROOT 등)는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# shellcheck disable=SC2154,SC2164

# immich-originals-mirror.sh의 빈-소스 가드를 박제한다: SRC_DIR이 비어 있으면 rsync를
# 절대 호출하지 않고 non-zero로 중단해야 한다. (빈 소스로 `rsync --delete` 미러 시 목적지
# 전체가 삭제되므로 — 이 서비스의 핵심 데이터 보존 계약.)
test_immich_originals_mirror_empty_source_skips_rsync() {
  local script sandbox src dest bin marker rc
  script="$REPO_ROOT/modules/nixos/programs/docker/immich-originals-mirror/files/immich-originals-mirror.sh"
  sandbox="$(new_sandbox)"
  src="$sandbox/src" # 의도적으로 빈 디렉토리
  dest="$sandbox/dest"
  bin="$sandbox/bin"
  marker="$sandbox/rsync-was-called"
  mkdir -p "$src" "$dest" "$bin"

  # 스텁 rsync: 호출되면 마커를 남긴다. 가드가 살아 있으면 이 마커는 생기지 않아야 한다.
  cat > "$bin/rsync" <<EOF
#!/usr/bin/env bash
touch "$marker"
EOF
  chmod +x "$bin/rsync"

  # 스텁 자격/라이브러리: send_notification은 no-op (trap이 호출).
  printf 'PUSHOVER_TOKEN=x\nPUSHOVER_USER=x\n' > "$sandbox/cred"
  printf 'send_notification() { :; }\n' > "$sandbox/service-lib"

  rc=0
  PATH="$bin:$PATH" \
    SRC_DIR="$src" DEST_DIR="$dest" \
    PUSHOVER_CRED_FILE="$sandbox/cred" SERVICE_LIB="$sandbox/service-lib" \
    bash "$script" >/dev/null 2>&1 || rc=$?

  [[ "$rc" -ne 0 ]] || fail "expected non-zero exit on empty SRC_DIR (got $rc)"
  [[ ! -e "$marker" ]] || fail "rsync must NOT be called when SRC_DIR is empty (목적지 삭제 방지)"
}

# #1369: 대상 HDD(MOUNT_ROOT)가 미마운트여도 nofail로 부팅은 계속되므로, 목적지가 루트
# 파일시스템의 일반 디렉터리로 존재하는 상황에서 rsync가 절대 실행되지 않아야 한다.
test_immich_originals_mirror_unmounted_target_blocks_rsync() {
  local script sandbox src dest bin marker rc
  script="$REPO_ROOT/modules/nixos/programs/docker/immich-originals-mirror/files/immich-originals-mirror.sh"
  sandbox="$(new_sandbox)"
  src="$sandbox/src"
  dest="$sandbox/dest"
  bin="$sandbox/bin"
  marker="$sandbox/rsync-was-called"
  mkdir -p "$src" "$dest" "$bin"
  printf 'not empty\n' > "$src/file.txt"

  cat > "$bin/rsync" <<EOF
#!/usr/bin/env bash
touch "$marker"
EOF
  chmod +x "$bin/rsync"

  # 미마운트 흉내: mountpoint가 항상 exit 1(마운트 아님)을 돌려준다.
  cat > "$bin/mountpoint" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$bin/mountpoint"

  printf 'PUSHOVER_TOKEN=x\nPUSHOVER_USER=x\n' > "$sandbox/cred"
  printf 'send_notification() { :; }\n' > "$sandbox/service-lib"

  rc=0
  PATH="$bin:$PATH" \
    SRC_DIR="$src" DEST_DIR="$dest" MOUNT_ROOT="$dest" \
    PUSHOVER_CRED_FILE="$sandbox/cred" SERVICE_LIB="$sandbox/service-lib" \
    bash "$script" >/dev/null 2>&1 || rc=$?

  [[ "$rc" -ne 0 ]] || fail "expected non-zero exit when target HDD is not mounted (got $rc)"
  [[ ! -e "$marker" ]] || fail "rsync must NOT be called when target HDD is not mounted"
}

# 회귀 방지: 마운트 가드를 넣은 뒤에도 정상 마운트 상태에서는 기존 미러 기능이 그대로 동작해야 한다.
test_immich_originals_mirror_mounted_target_runs_rsync() {
  local script sandbox src dest bin marker rc
  script="$REPO_ROOT/modules/nixos/programs/docker/immich-originals-mirror/files/immich-originals-mirror.sh"
  sandbox="$(new_sandbox)"
  src="$sandbox/src"
  dest="$sandbox/dest"
  bin="$sandbox/bin"
  marker="$sandbox/rsync-was-called"
  mkdir -p "$src" "$dest" "$bin"
  printf 'not empty\n' > "$src/file.txt"

  cat > "$bin/rsync" <<EOF
#!/usr/bin/env bash
touch "$marker"
EOF
  chmod +x "$bin/rsync"

  # 정상 마운트 흉내: mountpoint가 exit 0(마운트됨)을 돌려준다.
  cat > "$bin/mountpoint" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$bin/mountpoint"

  printf 'PUSHOVER_TOKEN=x\nPUSHOVER_USER=x\n' > "$sandbox/cred"
  printf 'send_notification() { :; }\n' > "$sandbox/service-lib"

  rc=0
  PATH="$bin:$PATH" \
    SRC_DIR="$src" DEST_DIR="$dest" MOUNT_ROOT="$dest" \
    PUSHOVER_CRED_FILE="$sandbox/cred" SERVICE_LIB="$sandbox/service-lib" \
    bash "$script" >/dev/null 2>&1 || rc=$?

  [[ "$rc" -eq 0 ]] || fail "expected mirror to succeed when target HDD is mounted (got $rc)"
  [[ -e "$marker" ]] || fail "rsync must be called when target HDD is mounted"
}
