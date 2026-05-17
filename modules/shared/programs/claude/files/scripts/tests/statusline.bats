#!/usr/bin/env bats
# statusline.sh 폭 측정 fallback chain unit tests.
#
# 각 케이스는 mock stdin JSON 과 env 매트릭스를 조합해 statusline.sh 출력을
# 검사한다. 폭은 raw cols 로 입력되며 statusline.sh 내부에서 `EFF_COLS = COLS - 40`
# 보정이 적용된 뒤 RATE_DETAIL 임계값(88/58/40)이 평가된다.
#
# 검증은 rate_limits 출력의 detail 토큰을 본다: detail=4의 reset_date `(MM/DD HH:MM)`
# 갯수 + detail=3의 `→ remaining` 토큰. SSH 분기는 `▏…▕` vertical bracket으로
# 식별한다. 회귀 시 assertion 메시지에는 어떤 fallback 단계가 hit 됐다고 기대했는지
# 명시한다. 출력의 ANSI 이스케이프와 OSC 8 hyperlink 가 grep 패턴을 깨지 않도록
# 패턴은 색 코드 무관한 키 토큰만 매칭한다.

setup() {
  STATUSLINE="${BATS_TEST_DIRNAME}/../statusline.sh"
  # resets_at 을 실행 시점 기준 미래로 동적 생성. 절대값 timestamp 를 박으면 시간이
  # 지나며 stale 되어 statusline.sh 의 `remaining > 0` 가드가 `→ remaining` 출력을
  # 건너뛰고 detail=4 검증이 무력화된다.
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

# 공통 실행 helper. statusline.sh 호출 시 env isolation 정책을 한 곳에 모은다.
# stdin: 첫 인자 (mock JSON 본문). env 인자: shift 후 남은 NAME=VALUE 들.
# isolation: CLAUDE_STATUSLINE_COLUMNS / COLUMNS / SSH_CONNECTION 을 모두 unset →
#   bats 를 어떤 shell/SSH 환경에서 실행해도 비-SSH 케이스가 SSH branch 로 오염되지
#   않고, parent COLUMNS 누설도 차단. 케이스가 이들을 활성화하려면 명시적으로
#   `SSH_CONNECTION=...` / `COLUMNS=...` / `CLAUDE_STATUSLINE_COLUMNS=...` 를 추가
#   env 인자로 전달. HOME override 같은 커스텀 env 도 같은 인자 자리로 넘긴다.
# stdout 만 capture (stderr 누설 노이즈 차단).
run_statusline_with_input() {
  local stdin="$1"
  shift
  printf '%s' "$stdin" | env -u CLAUDE_STATUSLINE_COLUMNS -u COLUMNS -u SSH_CONNECTION "$@" bash "$STATUSLINE" 2>/dev/null
}

# setup 의 MOCK_JSON 을 stdin 으로 쓰는 thin wrapper. 대부분의 케이스가 이 경로.
run_statusline() {
  run_statusline_with_input "$MOCK_JSON" "$@"
}

# ANSI escape sequence 제거 (색 코드, OSC 8 hyperlink 분리). statusline.sh 출력은
# 토큰 사이에 escape 가 끼어 있어 grep 패턴이 직접 매치하지 못한다.
strip_ansi() {
  sed -E $'s/\x1b\\[[0-9;]*m//g; s/\x1b\\][0-9]*;[^\x07]*\x07//g'
}

@test "env override 200 enables full rate detail (detail=4)" {
  run run_statusline CLAUDE_STATUSLINE_COLUMNS=200
  [ "$status" -eq 0 ]
  local plain
  plain=$(echo "$output" | strip_ansi)
  # detail=4 시 reset_date 가 `(MM/DD HH:MM)` 형식으로 두 window 모두 표시.
  reset_count=$(echo "$plain" | grep -oE '\([0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}\)' | wc -l)
  [ "$reset_count" -eq 2 ] \
    || { echo "expected detail=4 (2 reset_date) from env=200; got count=$reset_count" >&2; false; }
  # detail=3 부터 `→ remaining` 도 양 window 모두 표시. detail=4 의 핵심 마커.
  remaining_count=$(echo "$plain" | grep -oE '→ [0-9]+[dhm]' | wc -l)
  [ "$remaining_count" -ge 2 ] \
    || { echo "expected → remaining (≥2) from env=200; got count=$remaining_count" >&2; false; }
}

@test "env override 50 collapses to compact rate detail (detail=2)" {
  # raw 50 → COLS<80 piecewise: EFF_COLS=50. EFF_COLS=50 은 RATE_DETAIL 임계값
  # (88/58/40) 중 ≥40 만 통과 → detail=2 (bar + pct + window, → remaining/reset_date 없음).
  run run_statusline CLAUDE_STATUSLINE_COLUMNS=50
  [ "$status" -eq 0 ]
  local plain
  plain=$(echo "$output" | strip_ansi)
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
  reset_count=$(echo "$output" | grep -oE '\([0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}\)' | wc -l)
  [ "$reset_count" -eq 2 ] \
    || { echo "expected detail=4 from COLUMNS=150 fallback; got count=$reset_count" >&2; false; }
}

@test "static default 140 enables full detail when all sources unset" {
  run run_statusline
  [ "$status" -eq 0 ]
  reset_count=$(echo "$output" | grep -oE '\([0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}\)' | wc -l)
  [ "$reset_count" -eq 2 ] \
    || { echo "expected detail=4 from static default 140; got count=$reset_count" >&2; false; }
}

@test "leading-zero env value falls through to default (octal regression guard)" {
  # 가드 부재 시 0140 은 bash 산술에서 octal 96으로 해석되어 EFF_COLS=56 → detail=2 로
  # 떨어졌다. decimal-only 가드가 0140 을 거부하고 default 140 으로 fallthrough 하면
  # EFF_COLS=100 → detail=4 (reset_date 2개 출현).
  run run_statusline CLAUDE_STATUSLINE_COLUMNS=0140
  [ "$status" -eq 0 ]
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
    reset_count=$(echo "$plain" | grep -oE '\([0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}\)' | wc -l)
    [ "$reset_count" -eq 2 ] \
      || { echo "case=\"$case\": expected detail=4 from default-140 fallthrough; got count=$reset_count plain=$plain" >&2; false; }
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
  run run_statusline_with_input "$stdin_json"
  [ "$status" -eq 0 ]
  local plain
  plain=$(echo "$output" | strip_ansi)
  # stdin terminal.columns=150 → EFF_COLS=110 → detail=4 (reset_date 2개)
  reset_count=$(echo "$plain" | grep -oE '\([0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}\)' | wc -l)
  [ "$reset_count" -eq 2 ] \
    || { echo "expected detail=4 from stdin terminal.columns=150; got count=$reset_count" >&2; false; }
}

# CLAUDE_STATUSLINE_COLUMNS 가 COLUMNS 와 동시에 설정되면 env override 가 우선해야 한다
# (명시 override 의도). 우선순위 역전 회귀를 잡는다.
@test "CLAUDE_STATUSLINE_COLUMNS wins over COLUMNS when both set" {
  run run_statusline CLAUDE_STATUSLINE_COLUMNS=50 COLUMNS=200
  [ "$status" -eq 0 ]
  local plain
  plain=$(echo "$output" | strip_ansi)
  # env=50 우선 → EFF_COLS=50 → detail=2 (reset_date 0개, → remaining 0개).
  # COLUMNS=200 이 우선이면 EFF_COLS=160 → detail=4 (reset_date 2개) → 회귀.
  reset_count=$(echo "$plain" | grep -oE '\([0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}\)' | wc -l)
  [ "$reset_count" -eq 0 ] \
    || { echo "expected CLAUDE_STATUSLINE_COLUMNS=50 to win (detail=2, no reset_date); COLUMNS=200 leaked detail=4: $plain" >&2; false; }
  remaining_count=$(echo "$plain" | grep -oE '→ [0-9]+[dhm]' | wc -l)
  [ "$remaining_count" -eq 0 ] \
    || { echo "expected CLAUDE_STATUSLINE_COLUMNS=50 to win (detail=2, no → remaining); COLUMNS=200 leaked detail=3+: $plain" >&2; false; }
}

# SSH 분기: vertical bracket `▏…▕` 으로 압축 (default 140 → EFF_COLS=100 → detail=4).
# 5h/7d 두 윈도우 모두 bracket 출현. mock SSH_CONNECTION 만 set 하면 statusline.sh
# 가 IS_SSH=true 분기로 진입한다.
@test "SSH branch renders vertical bracket gauge" {
  run run_statusline SSH_CONNECTION=192.168.1.1
  [ "$status" -eq 0 ]
  local plain
  plain=$(echo "$output" | strip_ansi)
  # 5h + 7d 두 윈도우 모두 좌측 bracket `▏` 출현.
  bracket_count=$(echo "$plain" | grep -oE '▏' | wc -l)
  [ "$bracket_count" -ge 2 ] \
    || { echo "expected ≥2 SSH vertical brackets (5h + 7d); got count=$bracket_count plain=$plain" >&2; false; }
  # detail=4 토큰은 SSH 분기에서도 동일 (helper 추출은 bar 영역만 분기).
  reset_count=$(echo "$plain" | grep -oE '\([0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}\)' | wc -l)
  [ "$reset_count" -eq 2 ] \
    || { echo "expected detail=4 in SSH branch too; got reset_count=$reset_count plain=$plain" >&2; false; }
}

# SSH 0% gauge edge: pct=0 일 때 core 가 literal " " (공백) 으로 치환되어 `▏ ▕` 가
# 보장돼야 한다. naive `pct*8/100=0` → array[0]=empty string 으로 떨어지면 출력이
# `▏▕` (공백 없음) 으로 깨진다. detail>=2 면 bracket 이 출력되므로 raw 50 → EFF_COLS=50
# → detail=2 환경에서 검증한다.
@test "SSH branch 0% gauge renders empty core '▏ ▕'" {
  local now five_h
  now=$(date +%s)
  five_h=$((now + 5 * 3600))
  local zero_stdin
  zero_stdin=$(cat <<EOF
{
  "session_id": "abc12345-def6-7890-abcd-ef1234567890",
  "transcript_path": "/tmp/nonexistent.jsonl",
  "cwd": "/tmp",
  "model": {"display_name": "test"},
  "workspace": {"current_dir": "/tmp"},
  "rate_limits": {
    "five_hour": {"used_percentage": 0, "resets_at": $five_h}
  }
}
EOF
)
  run run_statusline_with_input "$zero_stdin" SSH_CONNECTION=test CLAUDE_STATUSLINE_COLUMNS=50
  [ "$status" -eq 0 ]
  local plain
  plain=$(echo "$output" | strip_ansi)
  echo "$plain" | grep -qF '▏ ▕' \
    || { echo "expected 0% SSH gauge '▏ ▕' (empty core literal); got: $plain" >&2; false; }
}

# SSH detail=1 (EFF_COLS<40): horizontal/SSH 양쪽 모두 bar 영역 자체가 출력되지
# 않는다. raw 30 → EFF_COLS=30 (<40) → detail=1. bracket 누설 시 fail.
@test "SSH detail=1 (EFF_COLS<40) suppresses bracket gauge" {
  run run_statusline SSH_CONNECTION=test CLAUDE_STATUSLINE_COLUMNS=30
  [ "$status" -eq 0 ]
  local plain
  plain=$(echo "$output" | strip_ansi)
  if echo "$plain" | grep -qE '▏|▕'; then
    echo "expected no bracket in SSH detail=1 branch; leaked: $plain" >&2
    false
  fi
}

# sid 기반 sidecar I/O 회귀 가드: positive sidecar fixture. transcript_path 가
# `$HOME/.claude/projects/<encoded>/<sid>.jsonl` canonical 경로일 때
# SIDECAR_IO_ENABLED 가 켜지고 ICONS_FILE 에서 jira label 이 L1 에 출력되는지
# 검증. session-id 출력이 제거되어 sid 기반 sidecar 경로(validate transcript +
# session_id resolution + lib SESSION_STATE_DIR + ICONS_FILE 추출) 동작이 더
# 이상 출력으로 간접 검증되지 않으므로, 본 케이스가 positive path 를 직접 검증한다.
# SSH_CONNECTION 은 unset 이라 jira icon 활성.
@test "positive sidecar I/O reads jira label from ICONS_FILE" {
  local fake_home sid encoded transcript_dir
  fake_home=$(mktemp -d /tmp/bats-home-XXXXXX)
  sid="test-sid-abc123"
  # encoded 는 Claude Code 의 실제 인코딩과 매칭하지 않아도 됨 —
  # validate_transcript_path 가 canonical $HOME/.claude/projects/ 경계만 검사.
  encoded="bats-fixture-project"
  transcript_dir="$fake_home/.claude/projects/$encoded"
  mkdir -p "$transcript_dir" "$fake_home/.claude/status-icons"
  printf '' > "$transcript_dir/$sid.jsonl"
  cat > "$fake_home/.claude/status-icons/$sid.json" <<JSON
{
  "jira": {"url": "https://example.atlassian.net/browse/TEST-123", "label": "TEST-123"}
}
JSON
  local now five_h seven_d
  now=$(date +%s)
  five_h=$((now + 5 * 3600))
  seven_d=$((now + 5 * 86400))
  local stdin_json
  stdin_json=$(cat <<EOF
{
  "session_id": "$sid",
  "transcript_path": "$transcript_dir/$sid.jsonl",
  "cwd": "/tmp",
  "model": {"display_name": "test"},
  "workspace": {"current_dir": "/tmp"},
  "rate_limits": {
    "five_hour": {"used_percentage": 6, "resets_at": $five_h},
    "seven_day": {"used_percentage": 82, "resets_at": $seven_d}
  }
}
EOF
)
  # HOME override 로 lib 의 SESSION_STATE_DIR (=\$HOME/.claude/status-icons) 와
  # statusline.sh 의 transcript canonical 경계(\$HOME/.claude/projects) 를 fake HOME
  # 으로 redirect. statusline.sh 는 HEAVY_CACHE_DIR 와 CACHE_TTL_DIR 에서 XDG_*
  # 변수를 직접 참조하므로(`${XDG_RUNTIME_DIR:-${XDG_STATE_HOME:-\$HOME/.local/state}/...}`,
  # `${XDG_DATA_HOME:-\$HOME/.local/share}/...`), 부모 shell 의 XDG_* 가 set 이면
  # 실제 시스템 경로로 leak 되어 테스트 부산물이 host 에 남고 다음 run 의 cached
  # vars 가 오염될 수 있다. 4 개 모두 fake_home 하위로 pin.
  run run_statusline_with_input "$stdin_json" \
    HOME="$fake_home" \
    XDG_CONFIG_HOME="$fake_home/.config" \
    XDG_CACHE_HOME="$fake_home/.cache" \
    XDG_STATE_HOME="$fake_home/.local/state" \
    XDG_DATA_HOME="$fake_home/.local/share" \
    XDG_RUNTIME_DIR="$fake_home/.run"
  [ "$status" -eq 0 ]
  local plain
  plain=$(echo "$output" | strip_ansi)
  echo "$plain" | grep -q 'TEST-123' \
    || { echo "expected jira label 'TEST-123' from sidecar (sid-based ICONS_FILE path regression); got: $plain" >&2; false; }
  rm -rf "$fake_home"
}

# 비-SSH (default run_statusline) 에서는 vertical bracket 이 leak 되면 안 된다.
# helper 분기 회귀 (SSH glyph 가 비-SSH 로 흘러나옴) 가드 + horizontal bar 의
# minimum-fill 보정 (pct>0 && filled=0 → filled=1) 회귀 가드. 5h 6% fixture 에
# 대해 `█░░░░░░░░░` 정확 패턴, 7d 82% fixture 에 대해 `████████░░` 정확 패턴을
# 검증한다 — 보정이 깨져 `░░░░░░░░░░` 만 출력돼도 통과하던 loose 패턴 회귀 방지.
@test "non-SSH branch keeps horizontal bar (no vertical bracket leak)" {
  run run_statusline
  [ "$status" -eq 0 ]
  local plain
  plain=$(echo "$output" | strip_ansi)
  # 좌측 `▏` (U+258F) + 우측 `▕` (U+2595) 양쪽 모두 leak 가드. 한쪽만 검사하면
  # 부분 회귀 (예: 한쪽 bracket 만 비-SSH 분기로 흘러나오는 경우)를 놓친다.
  if echo "$plain" | grep -qE '▏|▕'; then
    echo "expected no vertical bracket (▏ or ▕) in non-SSH branch; leaked: $plain" >&2
    false
  fi
  # 5h 6% → minimum-fill 보정으로 filled=1 → `█░░░░░░░░░ 6%`. 보정 회귀 시 fail.
  echo "$plain" | grep -q '█░░░░░░░░░ 6%' \
    || { echo "expected minimum-fill bar '█░░░░░░░░░ 6%' for 5h in non-SSH; got: $plain" >&2; false; }
  # 7d 82% → filled=8 → `████████░░ 82%`. horizontal helper 회귀 시 fail.
  echo "$plain" | grep -q '████████░░ 82%' \
    || { echo "expected filled=8 bar '████████░░ 82%' for 7d in non-SSH; got: $plain" >&2; false; }
}
