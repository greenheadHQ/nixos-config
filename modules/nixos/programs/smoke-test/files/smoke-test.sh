#!/usr/bin/env bash
# 홈서버 런타임 스모크 테스트 본체 (smoke-test.nix가 writeShellApplication으로 감싼다)
# writeShellApplication이 set -euo pipefail + shebang 자동 적용
# 검사 대상은 활성 서비스·백업만 골라 Nix가 환경 변수로 주입한다 (비활성 서비스 false positive 방지)

# shellcheck source=/dev/null
source "$PUSHOVER_CRED_FILE"
# shellcheck source=/dev/null
source "$SERVICE_LIB"

# Pushover credential 검증 (smartd.nix, check-temp.sh와 동일 패턴)
if [ -z "${PUSHOVER_TOKEN:-}" ] || [ -z "${PUSHOVER_USER:-}" ]; then
  echo "ERROR: PUSHOVER_TOKEN or PUSHOVER_USER empty" >&2
  exit 1
fi

# 예기치 않은 크래시 시 Pushover 알림 (모니터링 서비스는 자체 장애를 보고해야 함)
# 검사 실패 요약을 이미 알린 종료는 크래시가 아니므로 다시 알리지 않는다.
# 알림 실패는 흡수한다 — trap 안에서 실패하면 크래시 종료 코드가 알림 실패 코드로 덮인다.
SUMMARY_NOTIFIED=0
trap_on_error() {
  local exit_code=$?
  if [ $exit_code -ne 0 ] && [ "$SUMMARY_NOTIFIED" -eq 0 ]; then
    send_notification "Smoke Test" \
      "스크립트 크래시 (exit $exit_code). journalctl -u homeserver-smoke-test 확인 필요." 1 || true
  fi
}
trap trap_on_error EXIT

FAILURES=""
CHECKS=0
PASSED=0

check() {
  local name="$1"
  local result="$2"
  CHECKS=$((CHECKS + 1))
  if [ "$result" -eq 0 ]; then
    PASSED=$((PASSED + 1))
    echo "OK: $name"
  else
    FAILURES="${FAILURES}  - ${name}"$'\n'
    echo "FAIL: $name"
  fi
}

# ─── 1. Caddy 핵심 엔드포인트 헬스체크 ───
# Tailscale IP + SNI로 직접 접근, DNS 불필요
# -s: silent, -o /dev/null: body 버림, -w: HTTP 코드만 추출
# -f 없음: 4xx/5xx에서도 실제 코드를 캡처하기 위해
for endpoint in $ENDPOINT_LIST; do
  DOMAIN="${endpoint%%:*}"
  REST="${endpoint#*:}"
  EXPECTED_CODE="${REST%%:*}"
  PATH_SUFFIX="${REST#*:}"
  HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
    --resolve "${DOMAIN}:443:${TAILSCALE_IP}" \
    --max-time 10 \
    "https://${DOMAIN}${PATH_SUFFIX}" 2>/dev/null) || HTTP_CODE="000"
  RESULT=0
  [ "$HTTP_CODE" = "$EXPECTED_CODE" ] || RESULT=1
  check "HTTP ${DOMAIN}${PATH_SUFFIX} = ${EXPECTED_CODE} (got ${HTTP_CODE})" "$RESULT"
done

# ─── 1b. loopback 앱과 공개 Cloudflare 입구 헬스체크 ───
for endpoint in $LOOPBACK_ENDPOINT_LIST $PUBLIC_ENDPOINT_LIST; do
  EXPECTED_CODE="${endpoint%%|*}"
  URL="${endpoint#*|}"
  HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$URL" 2>/dev/null) || HTTP_CODE="000"
  RESULT=0
  [ "$HTTP_CODE" = "$EXPECTED_CODE" ] || RESULT=1
  check "HTTP ${URL} = ${EXPECTED_CODE} (got ${HTTP_CODE})" "$RESULT"
done

# ─── 1c. 승인 배선 — Caddy 443 보존, 이전 8443 제거, 모든 Funnel 비활성 ───
# 시작 뒤 수동 조작으로 다른 포트가 공개되거나 443을 가로채는 이탈도 매일 검출한다.
if [ -n "$APPROVAL_FQDN" ]; then
  SERVE_STATUS=$(tailscale serve status --json 2>/dev/null || true)
  RESULT=0
  jq -e --arg approval "$APPROVAL_FQDN:$APPROVAL_PORT" \
    --arg legacy_port "$LEGACY_FUNNEL_PORT" --arg approval_port "$APPROVAL_PORT" \
    --arg approval_target "$APPROVAL_TARGET" '
      .TCP["443"] == null and .TCP[$legacy_port] == null and
      all((.AllowFunnel // {}) | to_entries[]; .value != true) and
      .TCP[$approval_port].HTTPS == true and
      .Web[$approval].Handlers["/"].Proxy == $approval_target
    ' >/dev/null <<<"$SERVE_STATUS" || RESULT=1
  check "Tailscale approval wiring (443 reserved for Caddy, no Funnel, ${APPROVAL_PORT} tailnet-only)" "$RESULT"
fi

# ─── 2. 백업 신선도 검증 (활성 백업만, 비활성 서비스 false positive 방지) ───
# 비활성 백업은 Nix가 디렉터리 변수를 빈 값으로, 인스턴스 목록을 비워 주입한다.

if [ -n "$IMMICH_BACKUP_DIR" ]; then
  # immich: flat directory에 immich-db-*.dump 파일
  # || true: 디렉토리 미존재 시 find 비정상 종료 + pipefail 방지
  LATEST_IMMICH=$(find "$IMMICH_BACKUP_DIR" -maxdepth 1 -name "immich-db-*.dump" \
    -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2- || true)
  if [ -n "$LATEST_IMMICH" ]; then
    AGE_HOURS=$(( ($(date +%s) - $(stat -c %Y "$LATEST_IMMICH")) / 3600 ))
    RESULT=0
    [ "$AGE_HOURS" -le "$BACKUP_MAX_AGE" ] || RESULT=1
    check "Immich backup freshness (${AGE_HOURS}h <= ${BACKUP_MAX_AGE}h)" "$RESULT"
  else
    check "Immich backup exists" 1
  fi
fi

if [ -n "$KARAKEEP_BACKUP_DIR" ]; then
  # karakeep: 날짜별 디렉토리의 db.db.gz
  LATEST_KK_DIR=$(find "$KARAKEEP_BACKUP_DIR" -maxdepth 1 -type d -name "20*" \
    -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2- || true)
  if [ -n "$LATEST_KK_DIR" ] && [ -f "$LATEST_KK_DIR/db.db.gz" ]; then
    AGE_HOURS=$(( ($(date +%s) - $(stat -c %Y "$LATEST_KK_DIR/db.db.gz")) / 3600 ))
    RESULT=0
    [ "$AGE_HOURS" -le "$BACKUP_MAX_AGE" ] || RESULT=1
    check "Karakeep backup freshness (${AGE_HOURS}h <= ${BACKUP_MAX_AGE}h)" "$RESULT"
  else
    check "Karakeep backup exists" 1
  fi
fi

for instance in $ANKI_BACKUP_INSTANCES; do
  # anki-host 인스턴스: 인스턴스 디렉터리에 anki-host-<인스턴스>-*.colpkg (일일, 04:15)
  LATEST_ANKI=$(find "$ANKI_BACKUP_ROOT/$instance" -maxdepth 1 -name "anki-host-$instance-*.colpkg" \
    -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2- || true)
  if [ -n "$LATEST_ANKI" ]; then
    AGE_HOURS=$(( ($(date +%s) - $(stat -c %Y "$LATEST_ANKI")) / 3600 ))
    RESULT=0
    [ "$AGE_HOURS" -le "$BACKUP_MAX_AGE" ] || RESULT=1
    check "Anki ${instance} backup freshness (${AGE_HOURS}h <= ${BACKUP_MAX_AGE}h)" "$RESULT"
  else
    check "Anki ${instance} backup exists" 1
  fi
done

# ─── 3. 실패한 systemd 유닛 검출 ───
# 알림 경로가 죽으면 유닛 실패가 아무 데도 통보되지 않는다 — 2026-08-16~25
# interaction-limits-renewal이 매일 실패했으나 그 실패를 알릴 curl이 없어 10일간
# 묻혔다. 매일 도는 이 smoke-test가 failed 유닛을 훑어 그 침묵을 덮는다.
# 유닛마다 OnFailure=를 다는 대신 여기 한 곳에 둔 이유: OnFailure가 호출할 알림
# 유닛도 같은 종류의 의존(curl)을 필요로 해 같은 결함을 재생산하고, 새 유닛이
# 생길 때마다 배선이 필요하다. 이 검사 하나는 신규 유닛까지 자동으로 덮는다.
# 범위: 시스템 유닛 한정 — --user를 쓰지 않으므로 시스템 매니저만 조회한다
# (스코프를 정하는 것은 실행 사용자가 아니라 --system/--user 플래그이고 전자가 기본값).
# --plain은 행 앞의 상태 마커(실패 유닛에 붙는 ●) 열을 제거해 첫 필드가 유닛명이
# 되게 한다 — 빼면 cut -f1이 유닛명 대신 ●를 뽑아 보고에 유닛명이 사라진다.
# 조회 성공 여부를 먼저 보존한다: systemctl이 매니저와 통신하지 못하면 빈 출력으로
# 끝나는데, 그것을 "실패 유닛 없음"으로 읽으면 이 검사가 덮으려는 침묵을 그대로
# 재현한다("확인 못 함"과 "이상 없음"은 다르다). stderr도 버리지 않는다 — 이번
# 사고의 근본 원인 메시지가 2>/dev/null에 삼켜져 진단이 늦어졌다.
if FAILED_RAW=$(systemctl --failed --no-legend --plain); then
  FAILED_UNITS=$(printf '%s' "$FAILED_RAW" | cut -d' ' -f1 | tr '\n' ' ')
  RESULT=0
  [ -z "$FAILED_UNITS" ] || RESULT=1
  check "No failed systemd units (${FAILED_UNITS:-none})" "$RESULT"
else
  QUERY_RC=$?
  check "systemd failed-unit query (systemctl rc=${QUERY_RC})" 1
fi

# ─── 결과 요약 + Pushover ───
# 실패가 하나라도 있으면 요약 알림을 한 번 시도하고 0이 아닌 코드로 끝내 systemd에 실패로 남긴다.
# 시도 전에 표시해 EXIT trap이 같은 실패를 크래시로 다시 알리지 않게 하고, 알림 실패는
# 흡수해 종료 코드를 검사 결과가 정하게 한다.
echo "=== Smoke test: ${PASSED}/${CHECKS} passed ==="
if [ -n "$FAILURES" ]; then
  SUMMARY_NOTIFIED=1
  send_notification "Smoke Test" \
    "$(printf '%s/%s passed\n%s' "$PASSED" "$CHECKS" "$FAILURES")" 0 || true
  exit 1
fi
