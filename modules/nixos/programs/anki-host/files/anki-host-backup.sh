# shellcheck shell=bash
# anki-host-backup — 인스턴스마다 헬퍼 애드온(/export)으로 일관된 .colpkg(미디어 포함, 구형 호환
# 형식)를 만들고 HDD로 복사한다. 실행 중인 SQLite를 직접 rsync하면 불일치 사본이 되므로 Anki가
# 직접 내보낸 패키지만 백업한다. 실패 시에만 Pushover(우선순위 1)로 알린다.
#
# 디렉터리 역할 (애드온 ALLOWED_SUBDIRS와 같은 계약):
#   <state>/backups/         일일 백업 스테이징 — SSD 최신 LOCAL_KEEP개, HDD RETENTION_DAYS로 정리
#   <state>/restore-points/  변경 전 복구점 — 이 스크립트는 건드리지 않는다. 생산자(MCP 도구)와 보존·미러
#                            규칙은 PR 2b에서 함께 도입한다 (plan 030 결정 11).
# env: INSTANCES ("name:helperPort ..."), STATE_ROOT, BACKUP_DIR, RETENTION_DAYS, LOCAL_KEEP, HELPER_CURL_MAX_TIME,
#      READY_WAIT_TRIES READY_WAIT_SECS READY_PROBE_TIMEOUT BUSY_RETRIES BUSY_RETRY_SECS, [CREDENTIALS_DIRECTORY]
#      (모두 nixos 모듈이 constants.ankiHost에서 주입 — 같은 값으로 유닛 TimeoutStartSec을 계산한다)
# (앞에 pushover.sh와 files/lib/helper-call.sh가 텍스트 결합되어 pushover_send·anki_helper_* 가 정의돼 있다.)

CRED_FILE="${CREDENTIALS_DIRECTORY:-}/pushover"
: "${INSTANCES:?}" "${STATE_ROOT:?}" "${BACKUP_DIR:?}" "${RETENTION_DAYS:?}" "${LOCAL_KEEP:?}" "${HELPER_CURL_MAX_TIME:?}"

# anki_helper_call_retry_busy <url> <json-payload> <max-time-secs>
#   변경 작업 1회 호출 + busy 재시도. 409(busy)면 BUSY_RETRY_SECS 뒤 다시 시도하고, BUSY_RETRIES회째 busy면 그대로
#   돌려준다(마지막 회차 뒤에는 대기하지 않는다). 호출자는 helper_busy로 "여전히 busy"를 판정한다.
#   인스턴스당 한 번만 부른다 — 유닛 예산(backup.nix perInstanceSecs)이 그 전제로 계산된다.
anki_helper_call_retry_busy() {
  local url="$1" payload="$2" max_time="$3" i
  for i in $(seq 1 "${BUSY_RETRIES:?}"); do
    anki_helper_call "$url" "$payload" "$max_time"
    helper_busy || return 0
    [ "$i" -lt "$BUSY_RETRIES" ] && sleep "${BUSY_RETRY_SECS:?}"
  done
  return 0
}

failures=""
stamp="$(date +%Y%m%dT%H%M%S)"

for entry in $INSTANCES; do
  name="${entry%%:*}"
  port="${entry##*:}"
  helper="http://127.0.0.1:${port}"
  local_dir="${STATE_ROOT}/${name}/backups"
  dest_dir="${BACKUP_DIR}/${name}"
  file="anki-host-${name}-${stamp}.colpkg"
  mkdir -p "$dest_dir"

  if ! anki_helper_wait_ready "$helper"; then
    echo "anki-host-backup[${name}]: helper not ready: $(helper_error)" >&2
    failures="${failures} ${name}(not-ready)"
    continue
  fi

  payload="$(jq -n --arg path "${local_dir}/${file}" '{path: $path, include_media: true, legacy: true}')"
  anki_helper_call_retry_busy "${helper}/export" "$payload" "$HELPER_CURL_MAX_TIME"
  if ! helper_ok; then
    echo "anki-host-backup[${name}]: export failed: $(helper_error)" >&2
    failures="${failures} ${name}(export)"
    continue
  fi

  # zip 무결성 검사 — testzip()은 예외 없이 반환값으로만 알리므로 exit status로 바꾼다
  if ! python3 -c 'import sys, zipfile; bad = zipfile.ZipFile(sys.argv[1]).testzip(); sys.exit(0 if bad is None else 1)' "${local_dir}/${file}"; then
    echo "anki-host-backup[${name}]: integrity check failed for ${file}" >&2
    failures="${failures} ${name}(integrity)"
    continue
  fi

  if ! cp "${local_dir}/${file}" "${dest_dir}/${file}.partial" || ! mv "${dest_dir}/${file}.partial" "${dest_dir}/${file}"; then
    echo "anki-host-backup[${name}]: copy to HDD failed" >&2
    failures="${failures} ${name}(copy)"
    rm -f "${dest_dir}/${file}.partial"
    continue
  fi
  chmod 0600 "${dest_dir}/${file}"

  # 일일 백업본 정리(anki-host-<name>-*.colpkg만): HDD는 보존 기간 초과분, SSD는 최신 LOCAL_KEEP개
  find "$dest_dir" -maxdepth 1 -type f -name "anki-host-${name}-*.colpkg" -mtime "+${RETENTION_DAYS}" -delete
  find "$local_dir" -maxdepth 1 -type f -name "anki-host-${name}-*.colpkg" -printf '%T@ %p\n' \
    | sort -rn | awk -v keep="$LOCAL_KEEP" 'NR > keep {print $2}' | xargs -r rm -f

  echo "anki-host-backup[${name}]: ${file} ($(stat -c %s "${dest_dir}/${file}") bytes) -> ${dest_dir}"
done

if [ -n "$failures" ]; then
  if [ -r "$CRED_FILE" ]; then
    pushover_send "$CRED_FILE" "Anki 백업 실패" "miniPC Anki 컬렉션 백업이 실패했습니다:${failures}. journalctl -u anki-host-backup 로그를 확인하세요." 1 || true
  fi
  exit 1
fi
