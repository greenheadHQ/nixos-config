# shellcheck shell=bash
# anki-host-backup — 인스턴스마다 헬퍼 애드온(/export)으로 일관된 .colpkg(미디어 포함, 구형 호환
# 형식)를 만들고 HDD로 복사한다. 실행 중인 SQLite를 직접 rsync하면 불일치 사본이 되므로 Anki가
# 직접 내보낸 패키지만 백업한다. 실패 시에만 Pushover(우선순위 1)로 알린다.
# env: INSTANCES ("name:helperPort ..."), STATE_ROOT, BACKUP_DIR, RETENTION_DAYS, LOCAL_KEEP, PUSHOVER_HELPER, [CREDENTIALS_DIRECTORY]

CRED_FILE="${CREDENTIALS_DIRECTORY:-}/pushover"
# shellcheck source=/dev/null
source "${PUSHOVER_HELPER}"

failures=""
stamp="$(date +%Y%m%dT%H%M%S)"

for entry in $INSTANCES; do
  name="${entry%%:*}"
  port="${entry##*:}"
  state_dir="${STATE_ROOT}/${name}"
  local_dir="${state_dir}/backups"
  dest_dir="${BACKUP_DIR}/${name}"
  file="anki-host-${name}-${stamp}.colpkg"
  mkdir -p "$dest_dir"

  payload="$(jq -n --arg path "${local_dir}/${file}" '{path: $path, include_media: true, legacy: true}')"
  if ! response="$(curl -sS --max-time 1800 -H 'Content-Type: application/json' -d "$payload" "http://127.0.0.1:${port}/export" 2>&1)" \
     || [ "$(printf '%s' "$response" | jq -r '.ok' 2>/dev/null)" != "true" ]; then
    echo "anki-host-backup[${name}]: export failed: $(printf '%s' "$response" | head -c 200)" >&2
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

  # HDD 보존 기간 초과분 삭제, 로컬(SSD)에는 최신 LOCAL_KEEP개만 남긴다
  find "$dest_dir" -maxdepth 1 -type f -name 'anki-host-*.colpkg' -mtime "+${RETENTION_DAYS}" -delete
  find "$local_dir" -maxdepth 1 -type f -name 'anki-host-*.colpkg' -printf '%T@ %p\n' \
    | sort -rn | awk -v keep="$LOCAL_KEEP" 'NR > keep {print $2}' | xargs -r rm -f

  echo "anki-host-backup[${name}]: ${file} ($(stat -c %s "${dest_dir}/${file}") bytes) -> ${dest_dir}"
done

if [ -n "$failures" ]; then
  if [ -r "$CRED_FILE" ]; then
    pushover_send "$CRED_FILE" "Anki 백업 실패" "miniPC Anki 컬렉션 백업이 실패했습니다:${failures}. journalctl -u anki-host-backup 로그를 확인하세요." 1 || true
  fi
  exit 1
fi
