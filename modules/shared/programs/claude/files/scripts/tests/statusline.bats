#!/usr/bin/env bats
# statusline.sh polh 측정 fallback chain unit tests.
#
# 각 케이스는 mock stdin JSON 과 env 매트릭스를 조합해 statusline.sh 출력을
# 검사한다. 폭은 raw cols 로 입력되며 statusline.sh 내부에서 `EFF_COLS = COLS - 40`
# 보정이 적용된 뒤 RATE_DETAIL 임계값(88/58/40)과 session-id 표시 조건(EFF_COLS>=100)
# 이 평가된다.
#
# 회귀 시 assertion 메시지에는 어떤 fallback 단계가 hit 됐다고 기대했는지
# 명시한다. 출력의 ANSI 이스케이프와 OSC 8 hyperlink 가 grep 패턴을 깨지 않도록
# 패턴은 색 코드 무관한 키 토큰만 매칭한다.

setup() {
  STATUSLINE="${BATS_TEST_DIRNAME}/../statusline.sh"
  # resets_at 을 실행 시점 기준 미래로 동적 생성. 절대값 timestamp 를 박으면 시간이
  # 지나며 stale 되어 statusline.sh 의 `remaining > 0` 가드가 `→ remaining` 출력을
  # 건너뛰고 SC-1 의 detail=4 검증이 무력화된다.
  local now five_h seven_d
  now=$(date +%s)
  five_h=$((now + 5 * 3600))
  seven_d=$((now + 5 * 86400))
  MOCK_JSON=$(cat <<EOF
{
  "session_id": "abc12345-def6-7890-abcd-ef1234567890",
  "transcript_path": "/tmp/nonexistent.jsonl",
  "cwd": "/tmp",
  "model": {"display_name": "test"},
  "workspace": {"current_dir": "/tmp"},
  "rate_limits": {
    "five_hour": {"used_percentage": 6, "resets_at": $five_h},
    "seven_day": {"used_percentage": 82, "resets_at": $seven_d}
  },
  "context_window": {
    "current_usage": {
      "cache_read_input_tokens": 8000,
      "cache_creation_input_tokens": 2000
    }
  }
}
EOF
)
}

run_statusline() {
  # env 인자: NAME=VALUE 형태로 0개 이상 전달.
  # stdout 만 capture (stderr 누설 노이즈 차단).
  printf '%s' "$MOCK_JSON" | env -u CLAUDE_STATUSLINE_COLUMNS -u COLUMNS "$@" bash "$STATUSLINE" 2>/dev/null
}

# ANSI escape sequence 제거 (색 코드, OSC 8 hyperlink 분리). statusline.sh 출력은
# 토큰 사이에 escape 가 끼어 있어 grep 패턴이 직접 매치하지 못한다.
strip_ansi() {
  sed -E $'s/\x1b\\[[0-9;]*m//g; s/\x1b\\][0-9]*;[^\x07]*\x07//g'
}

@test "env override 200 enables full detail + full UUID" {
  run run_statusline CLAUDE_STATUSLINE_COLUMNS=200
  [ "$status" -eq 0 ]
  local plain
  plain=$(echo "$output" | strip_ansi)
  # full UUID = 36 자 UUID 형식. session_id 의 long form 이 통째로 나와야 한다.
  echo "$plain" | grep -q "abc12345-def6-7890-abcd-ef1234567890" \
    || { echo "expected full UUID from env=200 path; got: $plain" >&2; false; }
  # detail=4 시 reset_date 가 `(MM/DD HH:MM)` 형식으로 두 window 모두 표시.
  reset_count=$(echo "$plain" | grep -oE '\([0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}\)' | wc -l)
  [ "$reset_count" -eq 2 ] \
    || { echo "expected detail=4 (2 reset_date) from env=200; got count=$reset_count" >&2; false; }
  # detail=3 부터 `→ remaining` 도 양 window 모두 표시. detail=4 의 핵심 마커.
  remaining_count=$(echo "$plain" | grep -oE '→ [0-9]+[dhm]' | wc -l)
  [ "$remaining_count" -ge 2 ] \
    || { echo "expected → remaining (≥2) from env=200; got count=$remaining_count" >&2; false; }
}

@test "env override 50 collapses to compact output (short UUID, detail=2)" {
  # raw 50 → COLS<80 piecewise: EFF_COLS=50. EFF_COLS<100 → short prefix.
  # EFF_COLS=50 은 RATE_DETAIL 임계값 (88/58/40) 중 ≥40 만 통과 → detail=2
  # (bar + pct + window, → remaining/reset_date 없음).
  run run_statusline CLAUDE_STATUSLINE_COLUMNS=50
  [ "$status" -eq 0 ]
  local plain
  plain=$(echo "$output" | strip_ansi)
  # short prefix = 처음 8 자.
  echo "$plain" | grep -q "abc12345" \
    || { echo "expected short UUID prefix from env=50; got: $plain" >&2; false; }
  # full UUID dash 확장이 없어야 short prefix 확정.
  if echo "$plain" | grep -q "abc12345-"; then
    echo "expected short UUID, but full UUID leaked from env=50; got: $plain" >&2
    false
  fi
  # detail=2 → reset_date 없음.
  if echo "$plain" | grep -qE '\([0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}\)'; then
    echo "expected no reset_date from env=50 (detail=2); got: $plain" >&2
    false
  fi
  # detail=2 → → remaining 도 없음 (detail≥3 부터 출력).
  if echo "$plain" | grep -qE '→ [0-9]+[dhm]'; then
    echo "expected no → remaining from env=50 (detail=2); got: $plain" >&2
    false
  fi
}

@test "COLUMNS fallback when CLAUDE_STATUSLINE_COLUMNS unset" {
  run run_statusline COLUMNS=150
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "abc12345-def6-7890-abcd-ef1234567890" \
    || { echo "expected full UUID from COLUMNS=150 fallback; got: $output" >&2; false; }
  reset_count=$(echo "$output" | grep -oE '\([0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}\)' | wc -l)
  [ "$reset_count" -eq 2 ] \
    || { echo "expected detail=4 from COLUMNS=150 fallback; got count=$reset_count" >&2; false; }
}

@test "static default 140 enables full detail when all sources unset" {
  run run_statusline
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "abc12345-def6-7890-abcd-ef1234567890" \
    || { echo "expected full UUID from static default 140; got: $output" >&2; false; }
  reset_count=$(echo "$output" | grep -oE '\([0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}\)' | wc -l)
  [ "$reset_count" -eq 2 ] \
    || { echo "expected detail=4 from static default 140; got count=$reset_count" >&2; false; }
}

@test "leading-zero env value falls through to default (octal regression guard)" {
  # 가드 부재 시 0140 은 bash 산술에서 octal 96으로 해석되어 EFF_COLS=56 → short
  # prefix 가 됐다. decimal-only 가드가 0140 을 거부하고 default 140 으로
  # fallthrough 하면 EFF_COLS=100 → full UUID + detail=4.
  run run_statusline CLAUDE_STATUSLINE_COLUMNS=0140
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "abc12345-def6-7890-abcd-ef1234567890" \
    || { echo "expected default-140 fallthrough on octal-looking input; got: $output" >&2; false; }
  reset_count=$(echo "$output" | grep -oE '\([0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}\)' | wc -l)
  [ "$reset_count" -eq 2 ] \
    || { echo "expected detail=4 from default-140 fallthrough; got count=$reset_count" >&2; false; }
}

# 비숫자, 음수, 0, 5자리 이상, 빈 string, 공백 같은 invalid 입력이 모두 default 140
# fallthrough 로 떨어지는지 검증. _is_decimal 가드의 입력 다양성을 한 케이스로 묶는다.
@test "invalid env values all fall through to default 140" {
  local case
  for case in "-1" "0" "10000" "abc" "" " 140" "140 "; do
    run run_statusline CLAUDE_STATUSLINE_COLUMNS="$case"
    [ "$status" -eq 0 ]
    local plain
    plain=$(echo "$output" | strip_ansi)
    echo "$plain" | grep -q "abc12345-def6-7890-abcd-ef1234567890" \
      || { echo "case=\"$case\": expected default-140 fallthrough; got: $plain" >&2; false; }
  done
}

# stdin .terminal.columns 가 env 부재 시 활용되는 forward-compat 경로 검증.
@test "stdin terminal.columns is used when env unset" {
  local now five_h seven_d
  now=$(date +%s)
  five_h=$((now + 5 * 3600))
  seven_d=$((now + 5 * 86400))
  local stdin_json
  stdin_json=$(cat <<EOF
{
  "session_id": "abc12345-def6-7890-abcd-ef1234567890",
  "transcript_path": "/tmp/nonexistent.jsonl",
  "cwd": "/tmp",
  "model": {"display_name": "test"},
  "workspace": {"current_dir": "/tmp"},
  "terminal": {"columns": 150},
  "rate_limits": {
    "five_hour": {"used_percentage": 6, "resets_at": $five_h},
    "seven_day": {"used_percentage": 82, "resets_at": $seven_d}
  },
  "context_window": {
    "current_usage": {
      "cache_read_input_tokens": 8000,
      "cache_creation_input_tokens": 2000
    }
  }
}
EOF
)
  run bash -c "printf '%s' \"\$1\" | env -u CLAUDE_STATUSLINE_COLUMNS -u COLUMNS bash \"\$2\" 2>/dev/null" _ "$stdin_json" "$STATUSLINE"
  [ "$status" -eq 0 ]
  local plain
  plain=$(echo "$output" | strip_ansi)
  # stdin terminal.columns=150 → EFF_COLS=110 → detail=4 + full UUID
  echo "$plain" | grep -q "abc12345-def6-7890-abcd-ef1234567890" \
    || { echo "expected full UUID from stdin terminal.columns=150; got: $plain" >&2; false; }
  reset_count=$(echo "$plain" | grep -oE '\([0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}\)' | wc -l)
  [ "$reset_count" -eq 2 ] \
    || { echo "expected detail=4 from stdin terminal.columns=150; got count=$reset_count" >&2; false; }
}

# CLAUDE_STATUSLINE_COLUMNS 가 COLUMNS 와 동시에 설정되면 env override 가 우선해야 한다
# (G-3 명시 override 의도). 우선순위 역전 회귀를 잡는다.
@test "CLAUDE_STATUSLINE_COLUMNS wins over COLUMNS when both set" {
  run run_statusline CLAUDE_STATUSLINE_COLUMNS=50 COLUMNS=200
  [ "$status" -eq 0 ]
  local plain
  plain=$(echo "$output" | strip_ansi)
  # env=50 우선 → short UUID. COLUMNS=200 가 우선이면 full UUID 노출.
  if echo "$plain" | grep -q "abc12345-"; then
    echo "expected CLAUDE_STATUSLINE_COLUMNS=50 to win (short UUID); COLUMNS=200 leaked full UUID: $plain" >&2
    false
  fi
  echo "$plain" | grep -q "abc12345" \
    || { echo "expected short UUID prefix; got: $plain" >&2; false; }
}
