#!/bin/bash
# 홈서버 서비스 공통 셸 라이브러리
# 각 서비스의 version-check, update-script, cleanup에서 source하여 사용
# 주의: set -euo pipefail은 호출 스크립트가 선언 (라이브러리에서 선언하지 않음)
# 주의: subshell($(...))에서 호출 금지 — 전역변수 손실 방지

# ═══════════════════════════════════════════════════════════════
# Pushover 알림 전송
# 기본 priority: -1 (무음) — cleanup-script.sh가 기본값에 의존
# version-check/update 호출은 모두 명시적 priority 전달
# ═══════════════════════════════════════════════════════════════
send_notification() {
  local title="$1"
  local message="$2"
  local priority="${3:-"-1"}"

  curl -sf --proto =https --max-time 10 \
    --form-string "token=${PUSHOVER_TOKEN}" \
    --form-string "user=${PUSHOVER_USER}" \
    --form-string "title=${title}" \
    --form-string "message=${message}" \
    --form-string "priority=${priority}" \
    https://api.pushover.net/1/messages.json > /dev/null 2>&1 || true
}

# ═══════════════════════════════════════════════════════════════
# GitHub Releases API로 최신 버전 조회
# 결과: 전역변수 GITHUB_LATEST_VERSION, GITHUB_RESPONSE 설정
# 실패 시 빈 문자열 설정 + return 0 (set -e 안전)
# 주의: subshell에서 호출하면 전역변수가 손실됨
# ═══════════════════════════════════════════════════════════════
fetch_github_release() {
  local repo="$1"
  GITHUB_LATEST_VERSION=""
  GITHUB_RESPONSE=""
  GITHUB_RESPONSE=$(curl -sf --proto =https --max-time 30 \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${repo}/releases/latest") || {
    echo "WARNING: GitHub API request failed for ${repo}"
    return 0
  }
  GITHUB_LATEST_VERSION=$(echo "$GITHUB_RESPONSE" | jq -r '.tag_name | ltrimstr("v")')
  # jq -r은 JSON null을 문자열 "null"로 반환 → 빈 문자열로 정규화
  [ "$GITHUB_LATEST_VERSION" = "null" ] && GITHUB_LATEST_VERSION=""
}

# ═══════════════════════════════════════════════════════════════
# 컨테이너 이미지 digest 조회 (podman inspect)
# update-script에서 pull 전후 digest 비교에 사용
# ═══════════════════════════════════════════════════════════════
get_image_digest() {
  local container_name="$1"
  podman inspect "$container_name" --format '{{.Image}}' 2>/dev/null || echo ""
}

# ═══════════════════════════════════════════════════════════════
# 워치독: 장기 실패 감지 (3일 초과 시 경고)
# ═══════════════════════════════════════════════════════════════
check_watchdog() {
  local state_dir="$1"
  local service_name="$2"
  local last_success_file="$state_dir/last-success"

  if [ -f "$last_success_file" ]; then
    local last_success now days_since
    last_success=$(cat "$last_success_file")
    now=$(date +%s)
    days_since=$(( (now - last_success) / 86400 ))
    if [ "$days_since" -ge 3 ]; then
      send_notification "$service_name Version Check" \
        "버전 체크가 ${days_since}일간 성공하지 못했습니다. 서비스 상태를 확인하세요." 0
    fi
  fi
}

# ═══════════════════════════════════════════════════════════════
# 최초 실행 시 현재 버전만 기록
# return 0: 최초 실행 (호출측에서 종료해야 함)
# return 1: 이전 실행 존재 (계속 진행)
# ═══════════════════════════════════════════════════════════════
check_initial_run() {
  local state_dir="$1"
  local current_version="$2"
  local last_notified_file="$state_dir/last-notified-version"

  if [ ! -f "$last_notified_file" ]; then
    echo "First run: recording version $current_version"
    echo "$current_version" > "$last_notified_file"
    return 0
  fi
  return 1
}

# ═══════════════════════════════════════════════════════════════
# last-success 타임스탬프 갱신
# ═══════════════════════════════════════════════════════════════
record_success() {
  local state_dir="$1"
  date +%s > "$state_dir/last-success"
}

# ═══════════════════════════════════════════════════════════════
# HTTP 200 응답 대기 (헬스체크)
# ═══════════════════════════════════════════════════════════════
http_health_check() {
  local url="$1"
  local max_retries="${2:-30}"
  local interval="${3:-10}"

  echo "Running health check on $url..."
  for i in $(seq 1 "$max_retries"); do
    if curl -sf --max-time 10 "$url" > /dev/null 2>&1; then
      echo "Health check passed (attempt $i/$max_retries)"
      return 0
    fi
    echo "Waiting for service to start... ($i/$max_retries)"
    sleep "$interval"
  done

  echo "Health check failed after $max_retries attempts"
  return 1
}
