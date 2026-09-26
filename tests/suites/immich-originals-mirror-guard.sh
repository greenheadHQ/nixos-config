# tests/suites/immich-originals-mirror-guard.sh — 도메인 테스트 정의 (sourced; aggregator가 lib/test-common.sh 후 source)
# shellcheck shell=bash
# SC2154: 공통 변수(REPO_ROOT 등)는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# shellcheck disable=SC2154,SC2164

# backup-scripts.sh의 _backup_scripts_require_immich_disk_space와 같은 스킵 관례 — 스크립트
# 전체 성공(rsync까지 실행)이 필요한 테스트에서, 호스트의 실제 여유 공간이 스크립트의 5GB
# 하한(immich-originals-mirror.sh)에 못 미쳐 무관한 이유로 거짓 실패하는 것을 막는다.
_immich_originals_mirror_require_disk_space() {
  local dest_dir="$1"
  local avail_kb avail_gb
  avail_kb=$(df --output=avail "$dest_dir" | tail -1)
  avail_gb=$((avail_kb / 1024 / 1024))
  if [ "$avail_gb" -lt 5 ]; then
    echo "SKIP: immich originals mirror script requires >=5GB free in DEST_DIR; df branch is outside this characterization suite" >&2
    return 1
  fi
}

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
# MOUNT_ROOT는 DEST_DIR의 부모("$sandbox/root")로 둔다 — 프로덕션(mediaData가 마운트,
# DEST_DIR은 그 아래 하위 디렉터리)과 같은 모양으로 두 값을 다르게 유지해야, "가드가
# MOUNT_ROOT가 아니라 DEST_DIR을 검사하는" 변이를 뒤의 argv 검증 테스트가 잡을 수 있다.
test_immich_originals_mirror_unmounted_target_blocks_rsync() {
  local script sandbox src root dest bin marker rc
  script="$REPO_ROOT/modules/nixos/programs/docker/immich-originals-mirror/files/immich-originals-mirror.sh"
  sandbox="$(new_sandbox)"
  src="$sandbox/src"
  root="$sandbox/root"
  dest="$root/dest"
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
    SRC_DIR="$src" DEST_DIR="$dest" MOUNT_ROOT="$root" \
    PUSHOVER_CRED_FILE="$sandbox/cred" SERVICE_LIB="$sandbox/service-lib" \
    bash "$script" >/dev/null 2>&1 || rc=$?

  [[ "$rc" -ne 0 ]] || fail "expected non-zero exit when target HDD is not mounted (got $rc)"
  [[ ! -e "$marker" ]] || fail "rsync must NOT be called when target HDD is not mounted"
}

# 회귀 방지: 마운트 가드를 넣은 뒤에도 정상 마운트 상태에서는 기존 미러 기능이 그대로 동작해야 한다.
test_immich_originals_mirror_mounted_target_runs_rsync() {
  local script sandbox src root dest bin marker rc
  script="$REPO_ROOT/modules/nixos/programs/docker/immich-originals-mirror/files/immich-originals-mirror.sh"
  sandbox="$(new_sandbox)"
  src="$sandbox/src"
  root="$sandbox/root"
  dest="$root/dest"
  bin="$sandbox/bin"
  marker="$sandbox/rsync-was-called"
  mkdir -p "$src" "$dest" "$bin"
  _immich_originals_mirror_require_disk_space "$dest" || return 0
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
    SRC_DIR="$src" DEST_DIR="$dest" MOUNT_ROOT="$root" \
    PUSHOVER_CRED_FILE="$sandbox/cred" SERVICE_LIB="$sandbox/service-lib" \
    bash "$script" >/dev/null 2>&1 || rc=$?

  [[ "$rc" -eq 0 ]] || fail "expected mirror to succeed when target HDD is mounted (got $rc)"
  [[ -e "$marker" ]] || fail "rsync must be called when target HDD is mounted"
}

# 리뷰: 가드가 mountpoint를 부를 때 실제로 MOUNT_ROOT를 넘기는지 확인한다 — exit code만 보는
# 검사는 "DEST_DIR을 검사하도록 바꿔치는" 변이도 통과시킨다(모두 항상 마운트됨 스텁이므로).
# mountpoint 호출은 디스크 공간 검사보다 항상 앞서 실행되므로, 이 테스트는 argv만 확인하고
# 스크립트 전체 종료 코드는 보지 않는다 — 그렇지 않으면 여유 공간 5GB 미만인 호스트에서 이
# 테스트만 무관한 이유로 거짓 실패한다.
test_immich_originals_mirror_mount_guard_checks_mount_root_not_dest_dir() {
  local script sandbox src root dest bin marker argv_log
  script="$REPO_ROOT/modules/nixos/programs/docker/immich-originals-mirror/files/immich-originals-mirror.sh"
  sandbox="$(new_sandbox)"
  src="$sandbox/src"
  root="$sandbox/root"
  dest="$root/dest"
  bin="$sandbox/bin"
  marker="$sandbox/rsync-was-called"
  argv_log="$sandbox/mountpoint-argv.log"
  mkdir -p "$src" "$dest" "$bin"
  printf 'not empty\n' > "$src/file.txt"
  : > "$argv_log"

  cat > "$bin/rsync" <<EOF
#!/usr/bin/env bash
touch "$marker"
EOF
  chmod +x "$bin/rsync"

  cat > "$bin/mountpoint" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$argv_log"
exit 0
EOF
  chmod +x "$bin/mountpoint"

  printf 'PUSHOVER_TOKEN=x\nPUSHOVER_USER=x\n' > "$sandbox/cred"
  printf 'send_notification() { :; }\n' > "$sandbox/service-lib"

  PATH="$bin:$PATH" \
    SRC_DIR="$src" DEST_DIR="$dest" MOUNT_ROOT="$root" \
    PUSHOVER_CRED_FILE="$sandbox/cred" SERVICE_LIB="$sandbox/service-lib" \
    bash "$script" >/dev/null 2>&1 || true

  [ "$(cat "$argv_log")" = "-q $root" ] \
    || fail "expected mountpoint to be called as '-q $root' (MOUNT_ROOT), got: $(cat "$argv_log")"
}

# 이슈 최소 수정 범위: "목적지가 기대한 마운트 아래에 있는지 검증". MOUNT_ROOT는 마운트돼 있어도
# DEST_DIR이 그 아래가 아니면(설정 오류) 마운트 확인만으로는 잡지 못한다. DEST_DIR을 미리
# 만들지 않아 소속 가드가 mkdir 뒤로 밀리는 회귀도 함께 잡고, stderr의 가드 고유 문구로
# 실패 사유가 디스크 공간 등 다른 분기로 새지 않았는지도 확인한다.
test_immich_originals_mirror_destination_outside_mount_blocks_rsync() {
  local script sandbox src root other_mount dest bin marker stderr_path rc
  script="$REPO_ROOT/modules/nixos/programs/docker/immich-originals-mirror/files/immich-originals-mirror.sh"
  sandbox="$(new_sandbox)"
  src="$sandbox/src"
  root="$sandbox/root"
  other_mount="$sandbox/other-mount"
  dest="$root/dest" # 의도적으로 미생성 — 소속 가드가 mkdir 뒤로 밀리면 이 디렉터리가 생겨버린다
  bin="$sandbox/bin"
  marker="$sandbox/rsync-was-called"
  stderr_path="$sandbox/stderr"
  mkdir -p "$src" "$root" "$other_mount" "$bin"
  printf 'not empty\n' > "$src/file.txt"

  cat > "$bin/rsync" <<EOF
#!/usr/bin/env bash
touch "$marker"
EOF
  chmod +x "$bin/rsync"

  # 항상 마운트됨(exit 0) — 이 테스트는 마운트 확인이 아니라 소속 확인만 겨냥한다.
  cat > "$bin/mountpoint" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$bin/mountpoint"

  printf 'PUSHOVER_TOKEN=x\nPUSHOVER_USER=x\n' > "$sandbox/cred"
  printf 'send_notification() { :; }\n' > "$sandbox/service-lib"

  rc=0
  PATH="$bin:$PATH" \
    SRC_DIR="$src" DEST_DIR="$dest" MOUNT_ROOT="$other_mount" \
    PUSHOVER_CRED_FILE="$sandbox/cred" SERVICE_LIB="$sandbox/service-lib" \
    bash "$script" >/dev/null 2>"$stderr_path" || rc=$?

  [[ "$rc" -ne 0 ]] || fail "expected non-zero exit when DEST_DIR is outside MOUNT_ROOT (got $rc)"
  [[ ! -e "$marker" ]] || fail "rsync must NOT be called when DEST_DIR is outside MOUNT_ROOT"
  [[ ! -d "$dest" ]] || fail "DEST_DIR must NOT be created (mkdir) when it is outside MOUNT_ROOT (membership guard must run before mkdir)"
  assert_contains "$(cat "$stderr_path")" "is not under MOUNT_ROOT"
}

# 리뷰: case 패턴에서 슬래시를 빼는 변이(`"$MOUNT_ROOT"/*` → `"$MOUNT_ROOT"*`)는 MOUNT_ROOT가
# DEST_DIR의 문자열 접두사이기만 해도(디렉터리 경계가 아니어도) 통과시켜 버린다. MOUNT_ROOT를
# 실제 부모("$sandbox/mnt")와 문자열은 겹치지만 디렉터리 경계가 아닌 "$sandbox/mntdata/dest"의
# 상위("$sandbox/mnt"의 형제)로 둬서, 그 변이를 이 테스트가 잡는지 고정한다.
test_immich_originals_mirror_mount_prefix_without_directory_boundary_is_rejected() {
  local script sandbox src mount_prefix dest_parent dest bin marker stderr_path rc
  script="$REPO_ROOT/modules/nixos/programs/docker/immich-originals-mirror/files/immich-originals-mirror.sh"
  sandbox="$(new_sandbox)"
  src="$sandbox/src"
  mount_prefix="$sandbox/mnt"
  dest_parent="$sandbox/mntdata"
  dest="$dest_parent/dest" # 의도적으로 미생성
  bin="$sandbox/bin"
  marker="$sandbox/rsync-was-called"
  stderr_path="$sandbox/stderr"
  mkdir -p "$src" "$mount_prefix" "$dest_parent" "$bin"
  printf 'not empty\n' > "$src/file.txt"

  cat > "$bin/rsync" <<EOF
#!/usr/bin/env bash
touch "$marker"
EOF
  chmod +x "$bin/rsync"

  cat > "$bin/mountpoint" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$bin/mountpoint"

  printf 'PUSHOVER_TOKEN=x\nPUSHOVER_USER=x\n' > "$sandbox/cred"
  printf 'send_notification() { :; }\n' > "$sandbox/service-lib"

  rc=0
  PATH="$bin:$PATH" \
    SRC_DIR="$src" DEST_DIR="$dest" MOUNT_ROOT="$mount_prefix" \
    PUSHOVER_CRED_FILE="$sandbox/cred" SERVICE_LIB="$sandbox/service-lib" \
    bash "$script" >/dev/null 2>"$stderr_path" || rc=$?

  [[ "$rc" -ne 0 ]] \
    || fail "expected non-zero exit when DEST_DIR shares only a string prefix with MOUNT_ROOT (no directory boundary)"
  [[ ! -e "$marker" ]] || fail "rsync must NOT be called for the string-prefix MOUNT_ROOT case"
  [[ ! -d "$dest" ]] || fail "DEST_DIR must NOT be created for the string-prefix MOUNT_ROOT case"
  assert_contains "$(cat "$stderr_path")" "is not under MOUNT_ROOT"
}

# 순서 회귀: 마운트 가드가 mkdir(목적지 생성)보다 앞서야 한다. DEST_DIR을 미리 만들지 않고
# 실행해, 가드가 통과되지 않으면 스크립트가 그 디렉터리를 만들지 않아야 함을 확인한다.
test_immich_originals_mirror_unmounted_target_does_not_create_dest_dir() {
  local script sandbox src root dest bin marker rc
  script="$REPO_ROOT/modules/nixos/programs/docker/immich-originals-mirror/files/immich-originals-mirror.sh"
  sandbox="$(new_sandbox)"
  src="$sandbox/src"
  root="$sandbox/root"
  dest="$root/dest" # 의도적으로 미생성 — mkdir이 가드보다 앞서면 이 디렉터리가 생겨버린다
  bin="$sandbox/bin"
  marker="$sandbox/rsync-was-called"
  mkdir -p "$src" "$root" "$bin"
  printf 'not empty\n' > "$src/file.txt"

  cat > "$bin/rsync" <<EOF
#!/usr/bin/env bash
touch "$marker"
EOF
  chmod +x "$bin/rsync"

  cat > "$bin/mountpoint" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$bin/mountpoint"

  printf 'PUSHOVER_TOKEN=x\nPUSHOVER_USER=x\n' > "$sandbox/cred"
  printf 'send_notification() { :; }\n' > "$sandbox/service-lib"

  rc=0
  PATH="$bin:$PATH" \
    SRC_DIR="$src" DEST_DIR="$dest" MOUNT_ROOT="$root" \
    PUSHOVER_CRED_FILE="$sandbox/cred" SERVICE_LIB="$sandbox/service-lib" \
    bash "$script" >/dev/null 2>&1 || rc=$?

  [[ "$rc" -ne 0 ]] || fail "expected non-zero exit when target HDD is not mounted (got $rc)"
  [[ ! -d "$dest" ]] || fail "DEST_DIR must NOT be created (mkdir) before the mount guard runs"
  [[ ! -e "$marker" ]] || fail "rsync must NOT be called when target HDD is not mounted"
}
