#!/usr/bin/env bash
# GitHub interaction limits 자동 갱신 (MiniPC 일일 타이머 진입점).
# CIR: collaborators_only 제한은 GitHub 정책상 최장 six_months 후 자동 해제된다 —
# 외부인 PR/이슈/코멘트 차단(공개 저장소 방어)이 조용히 풀리는 것을 막기 위해
# 만료 임박을 감지해 PUT으로 재설정한다. 알림 3종(감지/성공/실패)은 사용자 합의 사양.
# 상태 파일 없는 무상태 설계 — 실패 시 다음 주기의 판정이 자연 재시도가 된다.
set -euo pipefail
umask 077

: "${REPO:?missing REPO}"
: "${LIMIT_VALUE:?missing LIMIT_VALUE}"
: "${EXPIRY:?missing EXPIRY}"
: "${RENEW_THRESHOLD_DAYS:?missing RENEW_THRESHOLD_DAYS}"
: "${GH_PAT_PATH:?missing GH_PAT_PATH}"
: "${PUSHOVER_HELPER:?missing PUSHOVER_HELPER}"
: "${PUSHOVER_SHARE_CRED:?missing PUSHOVER_SHARE_CRED}"
: "${PUSHOVER_LIB:?missing PUSHOVER_LIB}"

# 공통 fail-soft 전송 헬퍼 (da-weekly-report와 동일 소스 — drift 방지).
# shellcheck disable=SC1090
source "$PUSHOVER_LIB"

notify() {
  # 알림 실패가 갱신 로직을 막지 않는다 (fail-soft).
  send_pushover_fail_soft "$PUSHOVER_HELPER" "$PUSHOVER_SHARE_CRED" "$1" "$2" "${3:-0}" || true
}

if [ ! -r "$GH_PAT_PATH" ]; then
  notify "interaction limits 갱신 실패" "github-pat 미가독: $GH_PAT_PATH — opnix 상태를 확인하세요. 다음 주기에 재시도합니다." 1
  echo "ERROR: GH_PAT_PATH not readable: $GH_PAT_PATH" >&2
  exit 1
fi
GH_TOKEN="$(cat "$GH_PAT_PATH")"
export GH_TOKEN

# GET 실패(404 = 미설정 포함)는 빈 상태로 취급해 갱신 경로로 보낸다.
current_json="$(gh api "repos/$REPO/interaction-limits" 2>/dev/null || printf '{}')"
current_limit="$(jq -r '.limit // empty' <<<"$current_json")"
current_expires="$(jq -r '.expires_at // empty' <<<"$current_json")"

remain_days=-1
if [ "$current_limit" = "$LIMIT_VALUE" ] && [ -n "$current_expires" ]; then
  now_epoch="$(date -u +%s)"
  expires_epoch="$(date -u -d "$current_expires" +%s 2>/dev/null || echo 0)"
  if [ "$expires_epoch" -gt 0 ]; then
    remain_days=$(((expires_epoch - now_epoch) / 86400))
  fi
fi

if [ "$remain_days" -gt "$RENEW_THRESHOLD_DAYS" ]; then
  # 평시 경로는 무알림 — 노이즈 0 유지.
  echo "OK: $current_limit until $current_expires (${remain_days}d left > ${RENEW_THRESHOLD_DAYS}d threshold) — no renewal needed"
  exit 0
fi

if [ "$remain_days" -ge 0 ]; then
  detect_body="$REPO · $current_limit 잔여 ${remain_days}일 (만료 $current_expires) — 즉시 갱신을 시도합니다"
else
  detect_body="$REPO · limits 미설정 또는 값 불일치 (현재: ${current_limit:-없음}) — 즉시 설정을 시도합니다"
fi
notify "🔒 interaction limits 갱신 필요" "$detect_body" 0

if gh api -X PUT "repos/$REPO/interaction-limits" -f limit="$LIMIT_VALUE" -f expiry="$EXPIRY" >/dev/null 2>&1; then
  new_expires="$(gh api "repos/$REPO/interaction-limits" --jq '.expires_at' 2>/dev/null || echo 'unknown')"
  notify "✅ interaction limits 갱신 완료" "$REPO · $LIMIT_VALUE · $EXPIRY — 새 만료: $new_expires" 0
  echo "RENEWED: limit=$LIMIT_VALUE expiry=$EXPIRY new_expires=$new_expires"
  exit 0
else
  notify "❌ interaction limits 갱신 실패" "$REPO · PUT 실패 — github-pat 권한/네트워크를 확인하세요. 다음 주기에 재시도합니다." 1
  echo "ERROR: PUT failed for repos/$REPO/interaction-limits" >&2
  exit 1
fi
