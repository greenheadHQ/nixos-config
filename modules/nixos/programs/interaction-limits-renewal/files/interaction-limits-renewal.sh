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

# 공용 fail-soft 전송 헬퍼 (modules/nixos/lib/pushover-fail-soft.sh — 소비 모듈 공통 소스).
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

# GET 실패(인증·네트워크·저장소 오류)는 "미설정"과 분리해 실패로 종료한다 —
# 오진 상태로 PUT을 시도하거나 미설정 오보 알림을 보내지 않기 위함.
if ! current_json="$(gh api "repos/$REPO/interaction-limits" 2>/dev/null)"; then
  notify "❌ interaction limits 갱신 실패" "$REPO · 현재 상태 조회(GET) 실패 — 인증/네트워크를 확인하세요. 다음 주기에 재시도합니다." 1
  echo "ERROR: GET failed for repos/$REPO/interaction-limits" >&2
  exit 1
fi
current_limit="$(jq -r '.limit // empty' <<<"$current_json")"
current_expires="$(jq -r '.expires_at // empty' <<<"$current_json")"

# 갱신 사유를 명시적 상태로 판정한다. remain_days는 실제 잔여일이 계산된 경우에만 설정된다.
#   ok       — 원하는 limit이 threshold보다 여유 있게 남음 (무알림 종료)
#   expiring — 원하는 limit이지만 잔여일이 threshold 이하
#   absent   — GET 성공 + 빈 응답 (limits 미설정)
#   mismatch — 다른 limit 값이 설정되어 있거나 만료 시각을 해석할 수 없음
renewal_reason="mismatch"
remain_days=""
if [ -z "$current_limit" ]; then
  renewal_reason="absent"
elif [ "$current_limit" = "$LIMIT_VALUE" ] && [ -n "$current_expires" ]; then
  now_epoch="$(date -u +%s)"
  if expires_epoch="$(date -u -d "$current_expires" +%s 2>/dev/null)"; then
    remain_days=$(((expires_epoch - now_epoch) / 86400))
    if [ "$remain_days" -gt "$RENEW_THRESHOLD_DAYS" ]; then
      renewal_reason="ok"
    else
      renewal_reason="expiring"
    fi
  fi
fi

case "$renewal_reason" in
  ok)
    # 평시 경로는 무알림 — 노이즈 0 유지.
    echo "OK: $current_limit until $current_expires (${remain_days}d left > ${RENEW_THRESHOLD_DAYS}d threshold) — no renewal needed"
    exit 0
    ;;
  expiring)
    detect_body="$REPO · $current_limit 잔여 ${remain_days}일 (만료 $current_expires) — 즉시 갱신을 시도합니다"
    ;;
  absent)
    detect_body="$REPO · limits 미설정 — 즉시 설정을 시도합니다"
    ;;
  mismatch)
    detect_body="$REPO · 현재 값 불일치 (limit=${current_limit:-없음}, 만료 해석 불가 포함) — 즉시 재설정을 시도합니다"
    ;;
esac
notify "🔒 interaction limits 갱신 필요" "$detect_body" 0

if gh api -X PUT "repos/$REPO/interaction-limits" -f limit="$LIMIT_VALUE" -f expiry="$EXPIRY" >/dev/null 2>&1; then
  new_expires="$(gh api "repos/$REPO/interaction-limits" --jq '.expires_at' 2>/dev/null || echo 'unknown')"
  notify "✅ interaction limits 갱신 완료" "$REPO · $LIMIT_VALUE · $EXPIRY — 새 만료: $new_expires" 0
  echo "RENEWED: reason=$renewal_reason limit=$LIMIT_VALUE expiry=$EXPIRY new_expires=$new_expires"
  exit 0
else
  notify "❌ interaction limits 갱신 실패" "$REPO · PUT 실패 — github-pat 권한/네트워크를 확인하세요. 다음 주기에 재시도합니다." 1
  echo "ERROR: PUT failed for repos/$REPO/interaction-limits" >&2
  exit 1
fi
