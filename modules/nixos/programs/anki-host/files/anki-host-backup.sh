# shellcheck shell=bash
# anki-host-backup — 인스턴스마다 헬퍼 애드온(/export)으로 일관된 .colpkg(미디어 포함, 구형 호환
# 형식)를 만들고 HDD로 복사한다. 실행 중인 SQLite를 직접 rsync하면 불일치 사본이 되므로 Anki가
# 직접 내보낸 패키지만 백업한다. 실패 시에만 Pushover(우선순위 1)로 알린다.
#
# 디렉터리 역할 (애드온 ALLOWED_SUBDIRS와 같은 계약):
#   <state>/backups/         일일 백업 스테이징 — SSD 최신 LOCAL_KEEP개, HDD RETENTION_DAYS로 정리
#   <state>/restore-points/  변경 전 복구점(MCP 도구·운영자가 생성) — HDD로 미러하고, SSD에는 미러가 끝난
#                            것 중 최신 RESTORE_POINTS_LOCAL_KEEP개만 남긴다. HDD의 복구점은 지우지 않는다.
# env: INSTANCES ("name:helperPort ..."), STATE_ROOT, BACKUP_DIR, RETENTION_DAYS, LOCAL_KEEP,
#      RESTORE_POINTS_LOCAL_KEEP, HELPER_CURL_MAX_TIME, [CREDENTIALS_DIRECTORY]
# (앞에 files/lib/helper-call.sh가 텍스트 결합되어 anki_helper_call·helper_ok·helper_busy·helper_error가 정의돼 있다.)

CRED_FILE="${CREDENTIALS_DIRECTORY:-}/pushover"
BUSY_RETRIES=3
BUSY_RETRY_SECS=60
READY_WAIT_TRIES=24
READY_WAIT_SECS=5
READY_PROBE_TIMEOUT=30

failures=""
stamp="$(date +%Y%m%dT%H%M%S)"

for entry in $INSTANCES; do
  name="${entry%%:*}"
  port="${entry##*:}"
  helper="http://127.0.0.1:${port}"
  state_dir="${STATE_ROOT}/${name}"
  local_dir="${state_dir}/backups"
  rp_dir="${state_dir}/restore-points"
  dest_dir="${BACKUP_DIR}/${name}"
  file="anki-host-${name}-${stamp}.colpkg"
  mkdir -p "$dest_dir" "${dest_dir}/restore-points"

  # 헬퍼 준비 대기 — 재배포·재부팅 직후 타이머가 돌면 Anki가 아직 뜨는 중일 수 있다 (sync 스크립트와 같은 예산)
  for _ in $(seq 1 "$READY_WAIT_TRIES"); do
    anki_helper_call "${helper}/status" "" "$READY_PROBE_TIMEOUT"
    if helper_ok && [ "$(printf '%s' "$HELPER_BODY" | jq -r '.result.collection_open')" = "true" ]; then
      break
    fi
    sleep "$READY_WAIT_SECS"
  done

  payload="$(jq -n --arg path "${local_dir}/${file}" '{path: $path, include_media: true, legacy: true}')"
  for _ in $(seq 1 "$BUSY_RETRIES"); do
    anki_helper_call "${helper}/export" "$payload" "$HELPER_CURL_MAX_TIME"
    if helper_busy; then
      # sync 등 다른 변경 작업 진행 중 — 잠시 기다렸다 재시도
      sleep "$BUSY_RETRY_SECS"
      continue
    fi
    break
  done
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

  # 복구점 미러 — 아직 HDD에 없는 파일만 복사한다. HDD의 복구점은 지우지 않는다.
  if [ -d "$rp_dir" ]; then
    while IFS= read -r rp; do
      base="$(basename "$rp")"
      if [ ! -f "${dest_dir}/restore-points/${base}" ]; then
        cp "$rp" "${dest_dir}/restore-points/${base}.partial" && mv "${dest_dir}/restore-points/${base}.partial" "${dest_dir}/restore-points/${base}" \
          && chmod 0600 "${dest_dir}/restore-points/${base}" && echo "anki-host-backup[${name}]: restore point mirrored: ${base}"
      fi
    done < <(find "$rp_dir" -maxdepth 1 -type f -name '*.colpkg')
    # SSD 복구점 상한 — HDD 미러가 끝난 것만, 최신 RESTORE_POINTS_LOCAL_KEEP개를 넘는 오래된 것부터 지운다
    find "$rp_dir" -maxdepth 1 -type f -name '*.colpkg' -printf '%T@ %p\n' \
      | sort -rn | awk -v keep="$RESTORE_POINTS_LOCAL_KEEP" 'NR > keep {print $2}' \
      | while IFS= read -r old; do
          if [ -f "${dest_dir}/restore-points/$(basename "$old")" ]; then
            rm -f "$old" && echo "anki-host-backup[${name}]: restore point pruned from SSD (kept on HDD): $(basename "$old")"
          fi
        done
  fi

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
