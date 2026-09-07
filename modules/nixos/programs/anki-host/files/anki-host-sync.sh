# shellcheck shell=bash
# anki-host-sync — 헬퍼 애드온(/sync)을 호출해 AnkiWeb과 동기화하고 결과를 상태 파일·Pushover로 남긴다.
# 이 스크립트가 sync의 운영 계층(상태 파일·알림·결과 분류)의 단일 소유자다 — 타이머 유닛, 부트스트랩
# 유닛, PR 2의 MCP "지금 동기화"(유닛 트리거)가 모두 이 경로를 지난다. 헬퍼 /sync를 직접 부르는 호출자를 두지 않는다.
# env: HELPER_PORT STATE_DIR INSTANCE HELPER_CURL_MAX_TIME MAX_RETRIES BACKOFF_SECS
#      READY_WAIT_TRIES READY_WAIT_SECS READY_PROBE_TIMEOUT BUSY_RETRIES BUSY_RETRY_SECS [CREDENTIALS_DIRECTORY]
#      (모두 nixos 모듈이 constants.ankiHost에서 주입 — 같은 값으로 유닛 TimeoutStartSec을 계산한다)
# 인자: [--mode normal|allow-download-if-empty]  (기본 normal — 타이머 유닛; 부트스트랩 유닛이 allow-download-if-empty)
#
# 방향 정책(plan 030 결정 3): normal은 병합만, allow-download-if-empty는 빈 로컬의 첫 부트스트랩.
# 서버를 덮어쓰는 방향은 헬퍼에 없다.
#
# 상태 파일 sync-status.json의 `result` 어휘 (이 스크립트가 유일한 생산자 — 재개 절차·MCP가 이 표를 읽는다):
#   running             이 회차가 락을 잡고 실행 중. 유닛이 죽으면 이 값이 남는다 → journalctl -u anki-host-sync-<name>
#   no-credentials      AnkiWeb 자격 값이 아직 없다 — 운영자 게이트(plan Step 14) 전의 정상 상태. 알림 없음
#   bootstrap-pending   로그인은 됐으나 로컬이 비어 있고 성공 이력이 없어 full sync가 요구됨 — 부트스트랩 유닛(Step 15) 대기. 알림 없음
#   collection-empty    성공 이력(lastSuccessAt)이 있는데 로컬이 비어 있다 — 프로필 소실·좀비 잠금 의심(plan STOP 9). 알림(c),
#                       원인 확인 전 부트스트랩 재실행 금지
#   success             normal 병합 또는 부트스트랩 다운로드 완료. `sync` 필드에 전후 스냅샷
#   busy-deferred       헬퍼가 다른 변경 작업(export 등) 중이라 이번 회차를 건너뜀 — 다음 타이머에 재시도. 알림 없음
#   helper-unreachable  준비 대기 예산 안에 헬퍼가 collection_open을 주지 않음 — 알림(c) 24h 1회
#   login-failed        자격은 있는데 로그인 실패(login-failed/hook-error) — 재시도 없이 알림(c)
#   full-sync-required  로컬이 비어 있지 않은데 full sync 요구 — 방향 자동 결정 금지, 알림(c)
#   error               헬퍼 오류·재시도 소진 — 알림(c)
# 위 값 중 no-credentials → bootstrap-pending → success 세 값이 진행 단계를 가리키고, 나머지는 운영 중 일시 상태다.
# 회차 식별: 모든 기록에 runId(systemd INVOCATION_ID)·runStartedAt이 실린다 — 한 회차 안에서는 같은 값이고,
# lastAttemptAt은 마지막 기록 시각이라 회차 식별에 쓰지 않는다.
# 요청–결과 대응(plan 결정 13): 호출자(MCP "지금 동기화")는 트리거 전에 상태 파일을 읽어 result가 running이면 새 회차가
# 생기지 않는다(systemd가 진행 중인 job에 합류시킨다)는 사실을 그대로 안내한다. 아니면 트리거 전 runId를 기억하고,
# runId가 바뀌고 result가 running이 아닐 때만 그 회차의 결과로 인정한다. 락 경합으로 건너뛴 회차(아래 flock)는 파일을
# 건드리지 않는다.
# (앞에 pushover.sh와 files/lib/helper-call.sh가 텍스트 결합되어 pushover_send·anki_helper_* 가 정의돼 있다.)

MODE="normal"
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

HELPER="http://127.0.0.1:${HELPER_PORT:?}"
STATE_FILE="${STATE_DIR:?}/sync-status.json"
LOCK_FILE="${STATE_DIR}/.sync.lock"
CRED_FILE="${CREDENTIALS_DIRECTORY:-}/pushover"
ALERT_DEDUPE_SECS=86400
: "${MAX_RETRIES:?}" "${BACKOFF_SECS:?}" "${HELPER_CURL_MAX_TIME:?}" "${INSTANCE:?}"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  # 타이머 유닛과 부트스트랩 유닛은 별개라 systemd가 병합하지 않는다 — 여기서만 배제한다. 상태 파일은 실행 중인
  # 회차가 소유하므로 건드리지 않는다 (running이 이미 기록돼 있다)
  echo "anki-host-sync[${INSTANCE}]: another run is active, skipping"
  exit 0
fi

now() { date -Iseconds; }

# 회차 식별자 — 락을 잡은 직후 한 번 정하고 이 회차의 모든 기록에 같은 값으로 실린다
RUN_ID="${INVOCATION_ID:-manual-$(date +%s%N)}"
RUN_STARTED_AT="$(now)"

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
    --arg run_id "$RUN_ID" --arg run_started "$RUN_STARTED_AT" \
    --arg last_success "$last_success" --arg alert_key "$alert_key" --arg alert_at "$alert_at" \
    --argjson sync "${sync_json:-null}" \
    '{runId: $run_id, runStartedAt: $run_started, lastAttemptAt: $now,
      lastSuccessAt: (if $last_success == "" then null else $last_success end),
      result: $result, mode: $mode, error: (if $error == "" then null else $error end),
      lastAlert: (if $alert_key == "" then null else {key: $alert_key, at: $alert_at} end),
      sync: $sync}' > "${STATE_FILE}.partial"
  mv "${STATE_FILE}.partial" "$STATE_FILE"
}

send_pushover() {
  local title="$1" message="$2" priority="$3"
  if [ ! -r "$CRED_FILE" ]; then
    echo "anki-host-sync[${INSTANCE}]: pushover credential missing, '${title}' not sent" >&2
    return 1
  fi
  pushover_send "$CRED_FILE" "$title" "$message" "$priority"
}

# notify_alert <key> <priority> <title> <message>
# 실패·중단 알림(c): 같은 key는 24시간에 한 번만 보낸다. 실패 루프에서 매 회차 알림이 반복되지 않게 한다.
notify_alert() {
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
  if send_pushover "$title" "$message" "$priority"; then
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

# notify_event <title> <message>
# 성공 알림(b): 매 회차가 별개의 사건(그날의 학습 반영)이라 중복 억제 대상이 아니다. 우선순위 0.
notify_event() {
  if send_pushover "$1" "$2" 0; then
    echo "anki-host-sync[${INSTANCE}]: event sent"
  else
    echo "anki-host-sync[${INSTANCE}]: event send failed" >&2
  fi
}

# 락을 잡은 직후 "실행 중"을 먼저 기록한다 — 호출자가 직전 회차의 낡은 결과를 이번 회차의 결과로 읽지 않게 한다
write_state "running" "" ""

if ! anki_helper_wait_ready "$HELPER"; then
  echo "anki-host-sync[${INSTANCE}]: helper unreachable ($(helper_error))"
  write_state "helper-unreachable" "helper unreachable on ${HELPER}" ""
  notify_alert "helper-unreachable" 1 "Anki 동기화 실패" "miniPC의 Anki(${INSTANCE})가 응답하지 않습니다. 서비스 상태를 확인하세요. 최근 카드 변경은 miniPC에만 있을 수 있습니다."
  exit 1
fi
# 로그인 판정은 애드온의 login.status 하나로 한다 — 준비 응답(/status)에 들어 있고, 준비 대기가 not-attempted를
# 걸러 주므로 여기서는 확정값만 온다
login_status="$(printf '%s' "$HELPER_BODY" | jq -r '.result.login.status // "not-attempted"')"
case "$login_status" in
  logged-in|already-logged-in) ;;
  no-credentials)
    # 운영자 게이트(시크릿 값 투입) 전의 정상 상태 — 알림 소음을 만들지 않는다
    echo "anki-host-sync[${INSTANCE}]: no AnkiWeb credentials yet, skipping"
    write_state "no-credentials" "" ""
    exit 0
    ;;
  *)
    # 자격은 있는데 로그인 실패(login-failed/hook-error) → 재시도 없이 알림 (계정 잠금 방지, STOP 4)
    write_state "login-failed" "login status: ${login_status}" ""
    notify_alert "login-failed" 1 "Anki 로그인 실패" "miniPC의 Anki(${INSTANCE})가 AnkiWeb에 로그인하지 못했습니다. 자격 정보를 확인하세요. 동기화는 중단된 상태입니다."
    exit 1
    ;;
esac

attempt=1
delay="$BACKOFF_SECS"
busy_left="${BUSY_RETRIES:?}" # busy 예산은 스크립트 전체에서 BUSY_RETRIES회 — sync 재시도 회차와 무관 (유닛 예산 계산의 전제)
last_error=""
payload="$(jq -n --arg mode "$MODE" '{mode: $mode}')"
while [ "$attempt" -le "$MAX_RETRIES" ]; do
  anki_helper_call "${HELPER}/sync" "$payload" "$HELPER_CURL_MAX_TIME"
  if helper_busy; then
    # 다른 변경 작업(export/import) 진행 중 — 실패가 아니라 순서 대기. 예산을 다 쓰면 다음 타이머에 맡긴다
    busy_left=$((busy_left - 1))
    if [ "$busy_left" -le 0 ]; then
      echo "anki-host-sync[${INSTANCE}]: helper busy ($(printf '%s' "$HELPER_BODY" | jq -r '.busy // "?"')), deferring to next run"
      write_state "busy-deferred" "helper busy: $(printf '%s' "$HELPER_BODY" | jq -r '.busy // "?"')" ""
      exit 0
    fi
    sleep "${BUSY_RETRY_SECS:?}"
    continue
  fi
  if helper_ok; then
    result_json="$(printf '%s' "$HELPER_BODY" | jq -c '.result')"
    action="$(printf '%s' "$result_json" | jq -r '.action')"
    required="$(printf '%s' "$result_json" | jq -r '.required')"
    case "$action" in
      normal|full-download)
        write_state "success" "" "$result_json"
        # (b) 다른 기기의 학습·카드 변경이 내려왔을 때만 알린다 (수치와 덱 이름만).
        # 발송 여부·제목·본문을 한 jq 프로그램이 함께 정한다 — 제목이 본문 조건과 어긋나지 않게.
        notice="$(printf '%s' "$result_json" | jq -c '
          def deckdiff: (.after.today_reviews_by_deck // {}) as $a | (.before.today_reviews_by_deck // {}) as $b
            | [ ($a | keys[]) as $k | {deck: $k, n: ($a[$k] - ($b[$k] // 0))} | select(.n > 0) ]
            | sort_by(-.n) | map("\(.deck) \(.n)장") | join(", ");
          (.after.revlog - .before.revlog) as $rev
          | (.after.notes - .before.notes) as $notes
          | (.after.cards - .before.cards) as $cards
          | if .action == "full-download" then
              {title: "Anki 동기화", body: "AnkiWeb 컬렉션을 처음 내려받았습니다. 노트 \(.after.notes)개, 카드 \(.after.cards)장, 복습 기록 \(.after.revlog)건."}
            elif ($rev > 0 or $notes != 0 or $cards != 0) then
              {title: (if $rev > 0 then "오늘의 공부가 반영됐습니다" else "Anki 동기화" end),
               body: (([ (if $rev > 0 then "복습 \($rev)건이 반영됐습니다" + (if (deckdiff | length) > 0 then " (\(deckdiff))" else "" end) else empty end),
                        (if $notes > 0 then "노트 \($notes)개 추가" elif $notes < 0 then "노트 \(-$notes)개 삭제" else empty end),
                        (if $cards > 0 then "카드 \($cards)장 추가" elif $cards < 0 then "카드 \(-$cards)장 삭제" else empty end)
                      ] | join(". ")) + ".")}
            else null end')"
        if [ "$notice" != "null" ]; then
          notify_event "$(printf '%s' "$notice" | jq -r '.title')" "$(printf '%s' "$notice" | jq -r '.body')"
        fi
        echo "anki-host-sync[${INSTANCE}]: ${action} (required=${required})"
        exit 0
        ;;
      full-sync-required)
        if [ "$(printf '%s' "$result_json" | jq -r '.empty_before')" = "true" ]; then
          if [ -n "$(state_get '.lastSuccessAt')" ]; then
            # 이미 성공한 적이 있는 인스턴스의 컬렉션이 비었다 — 부트스트랩 전 대기가 아니라 프로필 소실·좀비 잠금 사고다.
            # 침묵하면 동기화가 무기한 멈춘 채 드러나지 않는다 (plan STOP 9)
            write_state "collection-empty" "empty collection after prior success (required=${required})" "$result_json"
            notify_alert "collection-empty" 1 "Anki 컬렉션이 비어 있습니다" "miniPC의 Anki(${INSTANCE})가 동기화 성공 이력이 있는데 컬렉션이 비어 있습니다. 프로필 소실이 의심되니 원인을 확인하기 전에는 부트스트랩을 다시 실행하지 마세요. 동기화는 중단된 상태입니다."
            exit 1
          fi
          # 빈 컬렉션의 첫 sync는 부트스트랩 유닛(--mode allow-download-if-empty)이 담당한다 — 알림 없이 대기
          echo "anki-host-sync[${INSTANCE}]: empty collection awaiting bootstrap (required=${required})"
          write_state "bootstrap-pending" "run anki-host-sync-${INSTANCE}-bootstrap" "$result_json"
          exit 0
        fi
        write_state "full-sync-required" "required=${required}" "$result_json"
        notify_alert "full-sync-required" 1 "Anki 전체 동기화 필요" "AnkiWeb이 전체 동기화(한쪽이 다른 쪽을 덮어쓰기)를 요구했지만 miniPC는 자동으로 방향을 정하지 않았습니다. 원인을 확인하기 전에는 어느 기기에서도 업로드/다운로드를 선택하지 마세요. (요구: ${required})"
        exit 0
        ;;
      *)
        last_error="unexpected action: ${action} (required=${required})"
        ;;
    esac
  else
    last_error="$(helper_error)"
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
notify_alert "sync-failed" 1 "Anki 동기화 실패" "miniPC의 Anki(${INSTANCE})가 AnkiWeb과 동기화하지 못했습니다: $(printf '%s' "$last_error" | head -c 120). 카드 변경은 miniPC에만 있을 수 있습니다."
exit 1
