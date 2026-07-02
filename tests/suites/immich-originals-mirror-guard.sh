# tests/suites/immich-originals-mirror-guard.sh — 도메인 테스트 정의 (sourced; aggregator가 lib/test-common.sh 후 source)
# shellcheck shell=bash
# SC2154: 공통 변수(REPO_ROOT 등)는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# shellcheck disable=SC2154,SC2164

# immich-originals-mirror.sh의 빈-소스 가드를 박제한다: SRC_DIR이 비어 있으면 rsync를
# 절대 호출하지 않고 non-zero로 중단해야 한다. (빈 소스로 `rsync --delete` 미러 시 목적지
# 전체가 삭제되므로 — 이 서비스의 핵심 데이터 보존 계약. plan 019 STEP 1 가드.)
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
