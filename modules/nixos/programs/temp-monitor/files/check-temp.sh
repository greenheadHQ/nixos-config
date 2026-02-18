#!/bin/bash
# writeShellApplication이 set -euo pipefail + shebang 자동 적용

# 환경변수 검증
: "${PUSHOVER_CRED_FILE:?PUSHOVER_CRED_FILE is required}"
: "${SERVICE_LIB:?SERVICE_LIB is required}"
: "${STATE_DIR:?STATE_DIR is required}"
: "${CPU_WARN:?CPU_WARN is required}"
: "${CPU_CRIT:?CPU_CRIT is required}"
: "${NVME_WARN:?NVME_WARN is required}"
: "${NVME_CRIT:?NVME_CRIT is required}"
: "${COOLDOWN_WARNING:?COOLDOWN_WARNING is required}"
: "${COOLDOWN_CRITICAL:?COOLDOWN_CRITICAL is required}"

# ═══════════════ 라이브러리 로드 ═══════════════
# shellcheck source=/dev/null
source "$SERVICE_LIB"
# shellcheck source=/dev/null
source "$PUSHOVER_CRED_FILE"

# Pushover credential 검증
if [ -z "${PUSHOVER_TOKEN:-}" ] || [ -z "${PUSHOVER_USER:-}" ]; then
  echo "WARNING: PUSHOVER_TOKEN or PUSHOVER_USER empty" >&2
  exit 1
fi

# ═══════════════ 센서 데이터 수집 ═══════════════
if ! SENSOR_JSON=$(sensors -j); then
  echo "ERROR: sensors -j 실패" >&2
  exit 1
fi

# 칩 타입 접두사로 동적 탐색 (PCI 주소 하드코딩 회피)
CPU_CHIP=$(jq -r '[keys[] | select(startswith("coretemp-"))] | .[0] // empty' <<< "$SENSOR_JSON")
NVME_CHIP=$(jq -r '[keys[] | select(startswith("nvme-"))] | .[0] // empty' <<< "$SENSOR_JSON")

# 센서 값 추출
# "Package id 0", "Composite"는 lm_sensors 안정 키명
CPU_TEMP=""
NVME_TEMP=""

if [ -n "$CPU_CHIP" ]; then
  CPU_TEMP=$(jq -r --arg chip "$CPU_CHIP" \
    '.[$chip]["Package id 0"].temp1_input // empty' <<< "$SENSOR_JSON") || CPU_TEMP=""
  if [ -z "$CPU_TEMP" ]; then
    echo "WARNING: CPU 칩 $CPU_CHIP 감지됨, 'Package id 0' 키 없음" >&2
  fi
fi

if [ -n "$NVME_CHIP" ]; then
  NVME_TEMP=$(jq -r --arg chip "$NVME_CHIP" \
    '.[$chip].Composite.temp1_input // empty' <<< "$SENSOR_JSON") || NVME_TEMP=""
  if [ -z "$NVME_TEMP" ]; then
    echo "WARNING: NVMe 칩 $NVME_CHIP 감지됨, 'Composite' 키 없음" >&2
  fi
fi

# ═══════════════ 온도 검증 및 알림 ═══════════════
check_temp() {
  local name="$1"
  local temp="$2"
  local warn_threshold="$3"
  local crit_threshold="$4"

  if [ -z "$temp" ]; then
    return 0
  fi

  # 소수점 이하 버림 (floor)
  local temp_int="${temp%.*}"

  # 단계 판정 (critical 먼저)
  local level="" priority=0 cooldown=0
  if [ "$temp_int" -ge "$crit_threshold" ]; then
    level="critical"
    priority=1
    cooldown="$COOLDOWN_CRITICAL"
  elif [ "$temp_int" -ge "$warn_threshold" ]; then
    level="warning"
    priority=0
    cooldown="$COOLDOWN_WARNING"
    # critical → warning 복귀: 쿨다운 초기화
    if [ -f "$STATE_DIR/last-alert-${name}-critical" ]; then
      rm -f "$STATE_DIR/last-alert-${name}-critical"
      rm -f "$STATE_DIR/last-alert-${name}-warning"
    fi
  else
    rm -f "$STATE_DIR/last-alert-${name}-warning"
    rm -f "$STATE_DIR/last-alert-${name}-critical"
    return 0
  fi

  # 쿨다운 체크
  local cooldown_file="$STATE_DIR/last-alert-${name}-${level}"
  if [ -f "$cooldown_file" ]; then
    local last_alert
    last_alert=$(cat "$cooldown_file")
    if ! [[ "$last_alert" =~ ^[0-9]+$ ]]; then
      rm -f "$cooldown_file"
    else
      local now elapsed
      now=$(date +%s)
      elapsed=$((now - last_alert))
      if [ "$elapsed" -lt "$cooldown" ]; then
        return 0
      fi
    fi
  fi

  # 알림 발송 — 성공 시에만 쿨다운 기록 (send_notification_strict: || true 없음)
  local title="Temp Alert: ${name} [${level^^}]"
  local message="${name}: ${temp}°C
임계값: 경고 ${warn_threshold}°C / 위험 ${crit_threshold}°C"

  if send_notification_strict "$title" "$message" "$priority"; then
    date +%s > "$cooldown_file"
  else
    echo "WARNING: Pushover 알림 전송 실패 (${name} ${level}, ${temp}°C)" >&2
  fi
}

# ═══════════════ 센서 체크 실행 ═══════════════
SENSORS_CHECKED=0

if [ -n "$CPU_TEMP" ]; then
  check_temp "CPU" "$CPU_TEMP" "$CPU_WARN" "$CPU_CRIT"
  SENSORS_CHECKED=1
fi

if [ -n "$NVME_TEMP" ]; then
  check_temp "NVMe" "$NVME_TEMP" "$NVME_WARN" "$NVME_CRIT"
  SENSORS_CHECKED=1
fi

if [ "$SENSORS_CHECKED" -eq 0 ]; then
  echo "WARNING: 모니터링 대상 센서 없음 (CPU/NVMe 칩 미감지)" >&2
  exit 1
fi

echo "온도 체크 완료: CPU=${CPU_TEMP:-N/A}°C NVMe=${NVME_TEMP:-N/A}°C"
