# shellcheck shell=bash
# anki-host-sync — 헬퍼 애드온(/sync)을 호출해 AnkiWeb과 동기화하고 결과를 상태 파일·Pushover로 남긴다.
# env: HELPER_PORT STATE_DIR INSTANCE PUSHOVER_HELPER [CREDENTIALS_DIRECTORY] [ANKI_HOST_SYNC_MODE]
# 인자: [--mode normal|allow-download-if-empty|download|upload]
#
# 방향 정책(plan 030 결정 3): normal은 병합만, allow-download-if-empty는 빈 로컬의 첫 부트스트랩,
# download/upload는 운영자가 명시할 때만. full sync가 요구됐는데 처리하지 않으면 알림만 보낸다.

MODE="${ANKI_HOST_SYNC_MODE:-normal}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode)
      MODE="$2"
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

HELPER="http://127.0.0.1:${HELPER_PORT}"
STATE_FILE="${STATE_DIR}/sync-status.json"
LOCK_FILE="${STATE_DIR}/.sync.lock"
CRED_FILE="${CREDENTIALS_DIRECTORY:-}/pushover"
MAX_RETRIES=3
BACKOFF=5
ALERT_DEDUPE_SECS=86400

# shellcheck source=/dev/null
source "${PUSHOVER_HELPER}"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "anki-host-sync[${INSTANCE}]: another run is active, skipping"
  exit 0
fi

now() { date -Iseconds; }

state_get() { jq -r "$1 // empty" "$STATE_FILE" 2>/dev/null || true; }

# write_state <result> <error> <sync-json-or-empty>
write_state() {
  local result="$1" error="$2" sync_json="$3"
  local last_success alert_key alert_at
  last_success="$(state_get '.lastSuccessAt')"
  alert_key="$(state_get '.lastAlert.key')"
  alert_at="$(state_get '.lastAlert.at')"
  if [ "$result" = "success" ]; then
    last_success="$(now)"
    alert_key=""
    alert_at=""
  fi
  jq -n \
    --arg now "$(now)" --arg result "$result" --arg error "$error" --arg mode "$MODE" \
    --arg last_success "$last_success" --arg alert_key "$alert_key" --arg alert_at "$alert_at" \
    --argjson sync "${sync_json:-null}" \
    '{lastAttemptAt: $now, lastSuccessAt: (if $last_success == "" then null else $last_success end),
      result: $result, mode: $mode, error: (if $error == "" then null else $error end),
      lastAlert: (if $alert_key == "" then null else {key: $alert_key, at: $alert_at} end),
      sync: $sync}' > "${STATE_FILE}.partial"
  mv "${STATE_FILE}.partial" "$STATE_FILE"
}

# notify <key> <priority> <title> <message>  — 같은 key의 알림은 24시간에 한 번만 보낸다
notify() {
  local key="$1" priority="$2" title="$3" message="$4"
  local prev_key prev_at prev_epoch
  prev_key="$(state_get '.lastAlert.key')"
  prev_at="$(state_get '.lastAlert.at')"
  if [ -n "$prev_key" ] && [ "$prev_key" = "$key" ] && [ -n "$prev_at" ]; then
    prev_epoch="$(date -d "$prev_at" +%s 2>/dev/null || echo 0)"
    if [ $(( $(date +%s) - prev_epoch )) -lt "$ALERT_DEDUPE_SECS" ]; then
      echo "anki-host-sync[${INSTANCE}]: alert '${key}' suppressed (sent within 24h)"
      return 0
    fi
  fi
  if [ ! -r "$CRED_FILE" ]; then
    echo "anki-host-sync[${INSTANCE}]: pushover credential missing, alert '${key}' not sent" >&2
  elif pushover_send "$CRED_FILE" "$title" "$message" "$priority"; then
    echo "anki-host-sync[${INSTANCE}]: alert '${key}' sent"
  else
    echo "anki-host-sync[${INSTANCE}]: alert '${key}' send failed" >&2
  fi
  # 전송 성공 여부와 무관하게 기록해 실패 루프에서 알림이 반복되지 않게 한다
  local tmp
  tmp="$(jq --arg key "$key" --arg at "$(now)" '.lastAlert = {key: $key, at: $at}' "$STATE_FILE" 2>/dev/null || echo '{}')"
  printf '%s\n' "$tmp" > "${STATE_FILE}.partial"
  mv "${STATE_FILE}.partial" "$STATE_FILE"
}

# 헬퍼 준비 대기 — 타이머(Persistent)는 활성화 직후에도 한 번 돌아 Anki가 뜨기 전에 올 수 있다
status_json=""
for _ in $(seq 1 24); do
  status_json="$(curl -sS --max-time 30 "${HELPER}/status" 2>/dev/null || true)"
  if [ "$(printf '%s' "$status_json" | jq -r '.ok and .result.collection_open' 2>/dev/null)" = "true" ]; then
    break
  fi
  sleep 5
done
# 헬퍼가 없거나 자격이 없으면 조용히 끝낸다 (운영자 게이트 전에는 알림 소음을 만들지 않는다)
if [ "$(printf '%s' "$status_json" | jq -r '.ok and .result.collection_open' 2>/dev/null)" != "true" ]; then
  echo "anki-host-sync[${INSTANCE}]: helper unreachable"
  write_state "helper-unreachable" "helper unreachable on ${HELPER}" ""
  notify "helper-unreachable" 1 "Anki 동기화 실패" "miniPC의 Anki(${INSTANCE})가 응답하지 않습니다. 서비스 상태를 확인하세요. 최근 카드 변경은 miniPC에만 있을 수 있습니다."
  exit 1
fi
login_status="$(printf '%s' "$status_json" | jq -r '.result.login.status // empty')"
logged_in="$(printf '%s' "$status_json" | jq -r '.result.logged_in')"
if [ "$logged_in" != "true" ]; then
  if [ "$login_status" = "no-credentials" ] || [ "$login_status" = "not-attempted" ]; then
    echo "anki-host-sync[${INSTANCE}]: no AnkiWeb credentials yet, skipping"
    write_state "no-credentials" "" ""
    exit 0
  fi
  # 자격은 있는데 로그인 실패 → 재시도 없이 알림 (계정 잠금 방지, STOP 4)
  write_state "login-failed" "login status: ${login_status}" ""
  notify "login-failed" 1 "Anki 로그인 실패" "miniPC의 Anki(${INSTANCE})가 AnkiWeb에 로그인하지 못했습니다. 자격 정보를 확인하세요. 동기화는 중단된 상태입니다."
  exit 1
fi

attempt=1
delay="$BACKOFF"
last_error=""
while [ "$attempt" -le "$MAX_RETRIES" ]; do
  payload="$(jq -n --arg mode "$MODE" '{mode: $mode, wait_media_secs: 60}')"
  response="$(curl -sS --max-time 1900 -H 'Content-Type: application/json' -d "$payload" "${HELPER}/sync" 2>&1)" && rc=0 || rc=$?
  if [ "$rc" -eq 0 ] && [ "$(printf '%s' "$response" | jq -r '.ok' 2>/dev/null)" = "true" ]; then
    result_json="$(printf '%s' "$response" | jq -c '.result')"
    action="$(printf '%s' "$result_json" | jq -r '.action')"
    required="$(printf '%s' "$result_json" | jq -r '.required')"
    case "$action" in
      normal|full-download|full-upload)
        write_state "success" "" "$result_json"
        # (b) 다른 기기의 학습·카드 변경이 내려왔을 때만 알린다 (수치와 덱 이름만)
        summary="$(printf '%s' "$result_json" | jq -r '
          def deckdiff: (.after.today_reviews_by_deck // {}) as $a | (.before.today_reviews_by_deck // {}) as $b
            | [ ($a | keys[]) as $k | {deck: $k, n: ($a[$k] - ($b[$k] // 0))} | select(.n > 0) ]
            | sort_by(-.n) | map("\(.deck) \(.n)장") | join(", ");
          (.after.revlog - .before.revlog) as $rev
          | (.after.notes - .before.notes) as $notes
          | (.after.cards - .before.cards) as $cards
          | if .action == "full-download" then
              "AnkiWeb 컬렉션을 처음 내려받았습니다. 노트 \(.after.notes)개, 카드 \(.after.cards)장, 복습 기록 \(.after.revlog)건."
            elif .action == "full-upload" then
              "miniPC의 변경을 AnkiWeb에 전체 업로드했습니다. 다른 기기에서는 다음 동기화 때 반드시 다운로드를 선택하세요."
            elif ($rev > 0 or $notes != 0 or $cards != 0) then
              ([ (if $rev > 0 then "복습 \($rev)건이 반영됐습니다" + (if (deckdiff | length) > 0 then " (\(deckdiff))" else "" end) else empty end),
                 (if $notes > 0 then "노트 \($notes)개 추가" elif $notes < 0 then "노트 \(-$notes)개 삭제" else empty end),
                 (if $cards > 0 then "카드 \($cards)장 추가" elif $cards < 0 then "카드 \(-$cards)장 삭제" else empty end)
               ] | join(". ")) + "."
            else "" end')"
        if [ -n "$summary" ]; then
          title="Anki 동기화"
          [ "$action" = "normal" ] && title="오늘의 공부가 반영됐습니다"
          notify "sync-${action}-$(date +%Y%m%d%H%M%S)" 0 "$title" "$summary"
        fi
        echo "anki-host-sync[${INSTANCE}]: ${action} (required=${required})"
        exit 0
        ;;
      full-sync-required)
        write_state "full-sync-required" "required=${required}" "$result_json"
        notify "full-sync-required" 1 "Anki 전체 동기화 필요" "AnkiWeb이 전체 동기화(한쪽이 다른 쪽을 덮어쓰기)를 요구했지만 miniPC는 자동으로 방향을 정하지 않았습니다. 원인을 확인하기 전에는 어느 기기에서도 업로드/다운로드를 선택하지 마세요. (요구: ${required})"
        exit 0
        ;;
      *)
        last_error="unexpected action: ${action} (required=${required})"
        ;;
    esac
  else
    last_error="$(printf '%s' "$response" | jq -r '.error // empty' 2>/dev/null || true)"
    [ -n "$last_error" ] || last_error="curl exit ${rc}: $(printf '%s' "$response" | head -c 200)"
    if [ "$last_error" = "not-logged-in" ]; then
      break
    fi
  fi
  echo "anki-host-sync[${INSTANCE}]: attempt ${attempt}/${MAX_RETRIES} failed: ${last_error}" >&2
  if [ "$attempt" -lt "$MAX_RETRIES" ]; then
    sleep "$delay"
    delay=$((delay * 2))
  fi
  attempt=$((attempt + 1))
done

write_state "error" "$last_error" ""
notify "sync-failed" 1 "Anki 동기화 실패" "miniPC의 Anki(${INSTANCE})가 AnkiWeb과 동기화하지 못했습니다: $(printf '%s' "$last_error" | head -c 120). 카드 변경은 miniPC에만 있을 수 있습니다."
exit 1
