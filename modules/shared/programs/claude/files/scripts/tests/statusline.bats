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
  # tmux/stty 폴백 격리: bats 를 실제 tmux/TTY 환경에서 실행해도 비-SSH/기본폭
  # 케이스가 parent session 상태에 오염되지 않도록 fake bin을 PATH 앞에 둔다.
  # SSH 케이스는 SSH_CONNECTION 을 직접 주입한다. stty fallback은 `</dev/tty`
  # 리다이렉션 때문에 no-tty 환경에서 fake가 실행되기 전 실패할 수 있으므로,
  # 여기서는 항상 실패시켜 static default 경로를 deterministic하게 검증한다.
  FAKE_BIN="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$FAKE_BIN"
  printf '#!/bin/sh\nexit 0\n' > "$FAKE_BIN/tmux"
  chmod +x "$FAKE_BIN/tmux"
  printf '#!/bin/sh\nexit 1\n' > "$FAKE_BIN/stty"
  chmod +x "$FAKE_BIN/stty"
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
  printf '%s' "$stdin" | env -u CLAUDE_STATUSLINE_COLUMNS -u COLUMNS -u SSH_CONNECTION PATH="$FAKE_BIN:$PATH" "$@" bash "$STATUSLINE" 2>/dev/null
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

# SSH 평문 URL: Jira 아이콘 URL 이 OSC 8 hyperlink 가 아니라 평문 URL 로 출력돼야
# SSH 클라이언트(Termius 등)의 URL regex 감지에 걸린다. sidecar 아이콘 + transcript
# 가 valid 해야 SIDECAR_IO_ENABLED 가 켜지므로 fake HOME 으로 projects 경계를 만든다.
@test "SSH renders Jira icon as plain URL (no OSC 8)" {
  local fake_home="$BATS_TEST_TMPDIR/home"
  local sid="abc12345-def6-7890-abcd-ef1234567890"
  mkdir -p "$fake_home/.claude/projects/proj" "$fake_home/.claude/status-icons"
  local tr="$fake_home/.claude/projects/proj/$sid.jsonl"
  printf '{}\n' > "$tr"
  printf '{"jira":{"url":"https://ex.atlassian.net/browse/PROJ-1","label":"PROJ-1"}}\n' \
    > "$fake_home/.claude/status-icons/$sid.json"
  local stdin
  stdin=$(printf '{"session_id":"%s","transcript_path":"%s","cwd":"/tmp","rate_limits":{"five_hour":{"used_percentage":5}}}' "$sid" "$tr")
  run run_statusline_with_input "$stdin" SSH_CONNECTION=192.168.1.1 HOME="$fake_home" SESSION_STATE_DIR="$fake_home/.claude/status-icons"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'https://ex.atlassian.net/browse/PROJ-1' \
    || { echo "expected plain Jira URL in SSH branch; got: $output" >&2; false; }
  if printf '%s' "$output" | grep -q $'\x1b]8;;'; then
    echo "expected NO OSC 8 sequence in SSH plain mode; got: $output" >&2; false
  fi
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
  # 으로 redirect. statusline.sh 는 HEAVY_CACHE_DIR 에서 XDG_* 변수를 직접
  # 참조하므로(`${XDG_RUNTIME_DIR:-${XDG_STATE_HOME:-\$HOME/.local/state}/...}`),
  # 부모 shell 의 XDG_* 가 set 이면 실제 시스템 경로로 leak 되어 테스트 부산물이
  # host 에 남고 다음 run 의 cached vars 가 오염될 수 있다. 관련 XDG_* 를 모두
  # fake_home 하위로 pin.
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

# worktree dir==branch: plugin 은 basename-hide 가드가 없어 폴더명과 branch 가
# 같아도 branch 를 L2 에 인라인으로 표시한다(별도 L3 라인 없음). 입력은
# cwd=/tmp (basename=tmp) + workspace.git_branch=tmp.
# macOS 에서 /tmp 는 /private/tmp symlink 지만 basename 은 동일하게 tmp.
@test "worktree dir==branch still shows inline 🌿 (no basename-hide guard)" {
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
  "workspace": {"current_dir": "/tmp", "git_worktree": "/tmp", "git_branch": "tmp"},
  "rate_limits": {
    "five_hour": {"used_percentage": 6, "resets_at": $five_h},
    "seven_day": {"used_percentage": 82, "resets_at": $seven_d}
  }
}
EOF
)
  run run_statusline_with_input "$stdin_json"
  [ "$status" -eq 0 ]
  local plain
  plain=$(echo "$output" | strip_ansi)
  branch_count=$(echo "$plain" | grep -oF '🌿' | wc -l | tr -d ' ')
  [ "$branch_count" -eq 1 ] \
    || { echo "expected exactly 1 🌿 inline branch even when dir==branch (plugin has no basename-hide guard); got count=$branch_count plain=$plain" >&2; false; }
  echo "$plain" | grep -qF 'tmp' \
    || { echo "expected branch label 'tmp' in output; got: $plain" >&2; false; }
}

# dir!=branch 면 worktree branch 가 L2 에 인라인으로 정확히 1번 + branch 라벨 출력된다.
# plugin 은 worktree 를 main repo 처럼 단일 라인 인라인 표시한다 (별도 L3 라인/basename-hide
# 가드 없음). branch 가 누락되거나 2번 이상 새면 fail.
@test "worktree dir!=branch shows inline 🌿 branch" {
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
  "workspace": {"current_dir": "/tmp", "git_worktree": "/tmp", "git_branch": "feat-foo"},
  "rate_limits": {
    "five_hour": {"used_percentage": 6, "resets_at": $five_h},
    "seven_day": {"used_percentage": 82, "resets_at": $seven_d}
  }
}
EOF
)
  run run_statusline_with_input "$stdin_json"
  [ "$status" -eq 0 ]
  local plain
  plain=$(echo "$output" | strip_ansi)
  branch_count=$(echo "$plain" | grep -oF '🌿' | wc -l | tr -d ' ')
  [ "$branch_count" -eq 1 ] \
    || { echo "expected exactly 1 🌿 inline branch when dir!=branch; got count=$branch_count plain=$plain" >&2; false; }
  echo "$plain" | grep -qF 'feat-foo' \
    || { echo "expected branch label 'feat-foo' in output; got: $plain" >&2; false; }
}

# cwd 구문 검증과 branch 표시의 독립성 회귀 가드: plugin 은 worktree branch 를 stdin 의
# workspace.git_branch(=WORKTREE_BRANCH)에서 직접 읽으므로, cwd 가 비-canonical 이어도
# git_branch 가 있으면 GIT_BRANCH 가 설정되어 branch 가 인라인 표시된다. cwd 를 상대경로
# (="tmp")로 보내면 validate_cwd_syntax 의 절대경로 가드(case "$cwd" in /*) ;; *) return ;;
# esac)에 걸려 CWD_VALID="" → CWD_RESOLVED="" 이 자연 유도된다 (상대경로는 raw fallback
# 대상도 아니다). 그래도 branch 표시는 영향받지 않아야 한다.
@test "worktree with non-canonical cwd still shows inline 🌿 (branch from git_branch)" {
  local now five_h seven_d
  now=$(date +%s)
  five_h=$((now + 5 * 3600))
  seven_d=$((now + 5 * 86400))
  local stdin_json
  stdin_json=$(cat <<EOF
{
  "session_id": "abc12345-def6-7890-abcd-ef1234567890",
  "transcript_path": "/tmp/nonexistent.jsonl",
  "cwd": "tmp",
  "model": {"display_name": "test"},
  "workspace": {"current_dir": "tmp", "git_worktree": "tmp", "git_branch": "tmp"},
  "rate_limits": {
    "five_hour": {"used_percentage": 6, "resets_at": $five_h},
    "seven_day": {"used_percentage": 82, "resets_at": $seven_d}
  }
}
EOF
)
  run run_statusline_with_input "$stdin_json"
  [ "$status" -eq 0 ]
  local plain
  plain=$(echo "$output" | strip_ansi)
  branch_count=$(echo "$plain" | grep -oF '🌿' | wc -l | tr -d ' ')
  [ "$branch_count" -eq 1 ] \
    || { echo "expected exactly 1 🌿 inline branch when CWD_RESOLVED=\"\"; got count=$branch_count plain=$plain" >&2; false; }
  echo "$plain" | grep -qF 'tmp' \
    || { echo "expected branch label 'tmp' in output; got: $plain" >&2; false; }
}

# ============================================================
# cwd URL raw fallback (canonical best-effort 회귀 가드)
# ============================================================
# canonical(cd+pwd -P) 실패 시 검증된 raw 절대경로로 vscode:// URL 을 유지해야 한다.
# OSC 8 URL 은 strip_ansi 가 제거하므로 raw $output 에서 직접 매칭한다.

# 부재 절대경로 cwd → raw fallback. 디렉토리가 그 순간 존재하지 않으면
# (LLM 이 삭제될 임시 디렉토리/워크트리로 작업 디렉토리를 옮긴 찰나, 또는 고부하
# fork 실패) canonicalize_dir 이 빈 값을 반환한다. canonical 단일 의존 시절엔 이
# 경우 OSC 8 링크가 통째로 사라져 클릭 시 에디터 대신 Finder 로 열리는 간헐 회귀가
# 있었다. 절대경로 + control-free 는 통과했으므로 raw 경로로 URL 을 유지해야 한다.
@test "absent absolute cwd still emits vscode:// URL (raw fallback)" {
  local gone="/tmp/statusline-bats-gone-$$-${RANDOM}"
  rm -rf "$gone"
  local stdin_json
  stdin_json=$(cat <<EOF
{
  "session_id": "abc12345-def6-7890-abcd-ef1234567890",
  "transcript_path": "/tmp/nonexistent.jsonl",
  "cwd": "$gone",
  "model": {"display_name": "test"}
}
EOF
)
  run run_statusline_with_input "$stdin_json"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "vscode://file${gone}/?windowId=_blank" \
    || { echo "expected raw-fallback vscode URL for absent cwd '$gone'; got: $output" >&2; false; }
}

# 보안 가드: 상대경로 cwd 는 raw fallback 대상이 아니다. validate_cwd_syntax 의
# 절대경로 가드가 거부 → CWD_RESOLVED="" → URL 미생성. raw fallback 도입이
# escape 방어(절대경로/control 검증)를 우회시키지 않음을 박제.
@test "relative cwd emits no vscode:// URL (fallback respects abs-path guard)" {
  local stdin_json
  stdin_json=$(cat <<EOF
{
  "session_id": "abc12345-def6-7890-abcd-ef1234567890",
  "transcript_path": "/tmp/nonexistent.jsonl",
  "cwd": "relative/path",
  "model": {"display_name": "test"}
}
EOF
)
  run run_statusline_with_input "$stdin_json"
  [ "$status" -eq 0 ]
  if echo "$output" | grep -qF 'vscode://'; then
    echo "expected NO vscode URL for relative cwd; got: $output" >&2
    false
  fi
}

# ============================================================
# Plan 아이콘 감지 (v5: 프로젝트 단위 fallback 제거 회귀 가드)
# ============================================================
# Plan 아이콘은 (1) transcript 직접 감지 또는 (2) 세션별 state 복원으로만
# 표시된다. v5 이전의 프로젝트 단위 fallback(.statusline-plan-current)은
# plan을 세운 적 없는 무관한 세션에 다른 세션의 plan을 상속시켜 false
# positive를 유발했으므로 제거됐다. 아래 케이스는 가짜 HOME 아래
# $HOME/.claude/projects/<dir>/ 구조를 만들어 TRANSCRIPT_VALID 신뢰 경계를
# 통과시킨 뒤 plan 분기를 직접 검사한다. plan 토큰은 아이콘 label "플랜"으로
# 식별한다 (strip_ansi가 OSC 8 hyperlink를 제거해도 label은 남는다).

# 가짜 HOME + canonical transcript dir + plan .md 생성.
# 인자: $1=session_id (고유). 전역 PLAN_HOME/PLAN_TDIR/PLAN_TRANSCRIPT/PLAN_MD 설정.
_setup_plan_home() {
  PLAN_HOME="$BATS_TEST_TMPDIR/h-$1"
  PLAN_TDIR="$PLAN_HOME/.claude/projects/test-proj"
  PLAN_TRANSCRIPT="$PLAN_TDIR/$1.jsonl"
  PLAN_MD="$PLAN_HOME/.claude/plans/the-plan.md"
  mkdir -p "$PLAN_TDIR" "$(dirname "$PLAN_MD")"
  printf '# plan body\n' > "$PLAN_MD"
}

# plan fixture용 stdin JSON. $1=session_id $2=transcript_path
_plan_json() {
  cat <<EOF
{
  "session_id": "$1",
  "transcript_path": "$2",
  "cwd": "/tmp",
  "model": {"display_name": "test"},
  "workspace": {"current_dir": "/tmp"}
}
EOF
}

# plan fixture 실행 helper: HOME + XDG_* 를 모두 PLAN_HOME 하위로 pin 한다.
# statusline.sh 는 HEAVY_CACHE_DIR 에서 XDG_* 를 직접 참조하므로
# (sidecar test 와 동일 사유), HOME 만 override 하면 부모 shell 의 XDG_* 가 set 일 때
# heavy/cache 파일이 실제 시스템 경로로 leak 되어 호스트를 오염시키고 다음 run 의
# cached vars 가 stale 해져 비결정적이 된다. PLAN_HOME 은 BATS_TEST_TMPDIR 하위라
# 케이스마다 새로 생성된다.
_run_plan() {
  run run_statusline_with_input "$1" \
    HOME="$PLAN_HOME" \
    XDG_CONFIG_HOME="$PLAN_HOME/.config" \
    XDG_CACHE_HOME="$PLAN_HOME/.cache" \
    XDG_STATE_HOME="$PLAN_HOME/.local/state" \
    XDG_DATA_HOME="$PLAN_HOME/.local/share" \
    XDG_RUNTIME_DIR="$PLAN_HOME/.run"
}

@test "plan: project-level state alone does NOT show Plan (v5 false-positive guard)" {
  local sid="planfp01-1111-2222-3333-444455556666"
  _setup_plan_home "$sid"
  # transcript에 plan 경로 없음 (무관한 user 라인만)
  printf '%s\n' '{"type":"user","message":{"role":"user"}}' > "$PLAN_TRANSCRIPT"
  # 다른 세션이 남긴 프로젝트 단위 state만 존재 (v5 이전엔 이게 상속됐다)
  printf '%s' "$PLAN_MD" > "$PLAN_TDIR/.statusline-plan-current"

  _run_plan "$(_plan_json "$sid" "$PLAN_TRANSCRIPT")"
  [ "$status" -eq 0 ]
  local plain
  plain=$(echo "$output" | strip_ansi)
  if echo "$plain" | grep -qF '플랜'; then
    echo "expected NO 플랜 icon from project-level state alone (v5 removed project fallback); got: $plain" >&2
    false
  fi
  # 복사본도 생성되지 않아야 한다 (v3 복사본 로직 제거 확인)
  copy_count=$(find "$(dirname "$PLAN_MD")" -name 'the-plan-*.md' 2>/dev/null | wc -l | tr -d ' ')
  [ "$copy_count" -eq 0 ] \
    || { echo "expected no plan copy created (v5 removed v3 copy logic); got count=$copy_count" >&2; false; }
}

@test "plan: transcript with plan path shows Plan" {
  local sid="planok01-1111-2222-3333-444455556666"
  _setup_plan_home "$sid"
  printf '%s\n' "{\"type\":\"assistant\",\"planFilePath\":\"$PLAN_MD\"}" > "$PLAN_TRANSCRIPT"

  _run_plan "$(_plan_json "$sid" "$PLAN_TRANSCRIPT")"
  [ "$status" -eq 0 ]
  local plain
  plain=$(echo "$output" | strip_ansi)
  echo "$plain" | grep -qF '플랜' \
    || { echo "expected 플랜 icon from transcript planFilePath; got: $plain" >&2; false; }
}

@test "plan: session-level state restores Plan when transcript lacks it" {
  local sid="planss01-1111-2222-3333-444455556666"
  _setup_plan_home "$sid"
  printf '%s\n' '{"type":"user","message":{"role":"user"}}' > "$PLAN_TRANSCRIPT"
  # 같은 session_id가 과거에 감지해 남긴 세션별 state (resume/compact 복원 경로)
  printf '%s' "$PLAN_MD" > "$PLAN_TDIR/.statusline-plan-$sid"

  _run_plan "$(_plan_json "$sid" "$PLAN_TRANSCRIPT")"
  [ "$status" -eq 0 ]
  local plain
  plain=$(echo "$output" | strip_ansi)
  echo "$plain" | grep -qF '플랜' \
    || { echo "expected 플랜 icon restored from session-level state; got: $plain" >&2; false; }
}

@test "plan: invalid session_id does NOT restore shared unknown state" {
  # stdin session_id가 validate_session_id 실패('..' 포함)면 SESSION_ID="" →
  # SIDECAR_IO_ENABLED=false → PLAN_STATE_FILE 미생성. 따라서 같은 transcript dir의
  # 다른 invalid identity가 남긴 .statusline-plan-unknown 공유 state를 복원하지 않아야 한다.
  # (가드 부재 시: .statusline-plan-${SESSION_ID:-unknown} = .statusline-plan-unknown 복원 → false positive)
  local sid="bad..sid"
  local validname="abcd1234-0000-1111-2222-333344445555"
  PLAN_HOME="$BATS_TEST_TMPDIR/h-invalidsid"
  PLAN_TDIR="$PLAN_HOME/.claude/projects/test-proj"
  local leak_md="$PLAN_HOME/.claude/plans/leaked.md"
  mkdir -p "$PLAN_TDIR" "$(dirname "$leak_md")"
  printf '# leaked\n' > "$leak_md"
  printf '%s\n' '{"type":"user","message":{"role":"user"}}' > "$PLAN_TDIR/$validname.jsonl"
  # unknown 공유 state가 실재 plan을 가리켜도 복원되면 안 된다
  printf '%s' "$leak_md" > "$PLAN_TDIR/.statusline-plan-unknown"

  _run_plan "$(_plan_json "$sid" "$PLAN_TDIR/$validname.jsonl")"
  [ "$status" -eq 0 ]
  local plain
  plain=$(echo "$output" | strip_ansi)
  if echo "$plain" | grep -qF '플랜'; then
    echo "expected NO 플랜 icon with invalid session_id (unknown state must not be restored); got: $plain" >&2
    false
  fi
}

# session-id 전용 줄: 항상 전체 id를 🆔 prefix와 함께 rate 바로 위(rate는 최하단)에
# 단독 출력한다. 이 줄에는 session-id 외 어떤 정보 아이콘도 병렬 출력되지 않아야 한다.
@test "session-id renders on its own line directly above rate with 🆔 prefix" {
  local now five_h
  now=$(date +%s)
  five_h=$((now + 5 * 3600))
  local sid="abc12345-def6-7890-abcd-ef1234567890"
  local stdin_json
  stdin_json=$(cat <<EOF
{
  "session_id": "$sid",
  "transcript_path": "/tmp/nonexistent.jsonl",
  "cwd": "/tmp",
  "workspace": {"git_branch": "main"},
  "rate_limits": {
    "five_hour": {"used_percentage": 23, "resets_at": $five_h}
  }
}
EOF
)
  run run_statusline_with_input "$stdin_json"
  [ "$status" -eq 0 ]
  local plain
  plain=$(echo "$output" | strip_ansi)
  # 🆔 prefix + 전체(축약 없는) session-id
  echo "$plain" | grep -qF "🆔 $sid" \
    || { echo "expected 🆔 prefix + full session-id; got: $plain" >&2; false; }
  # 전용 줄: 🆔 라인에 다른 정보 아이콘이 병렬 출력되지 않음
  local sid_line
  sid_line=$(echo "$plain" | grep -F '🆔')
  if echo "$sid_line" | grep -qE '📁|🌿|📝|🧠|⚡|💬|🎨|📓'; then
    echo "session-id line must contain ONLY session-id, no other icons; got: $sid_line" >&2
    false
  fi
  # rate(L_N)는 항상 session-id 줄보다 아래(최하단)
  local sid_lineno rate_lineno
  sid_lineno=$(echo "$plain" | grep -nF '🆔' | head -1 | cut -d: -f1)
  rate_lineno=$(echo "$plain" | grep -nF '5h' | head -1 | cut -d: -f1)
  [ -n "$sid_lineno" ] && [ -n "$rate_lineno" ] && [ "$rate_lineno" -gt "$sid_lineno" ] \
    || { echo "rate must render below session-id line (sid=$sid_lineno rate=$rate_lineno); got: $plain" >&2; false; }
}

# worktree branch 입력 schema 호환: 렌더러는 .workspace.git_branch 우선, 없으면
# .worktree.branch(공식 statusLine 계약 필드)로 fallback 한다. legacy/공식 schema
# (.worktree.branch 만 있는 입력)에서도 branch 가 인라인 표시되어야 한다.
@test "worktree branch from .worktree.branch schema also renders inline 🌿" {
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
  "workspace": {"current_dir": "/tmp", "git_worktree": "/tmp"},
  "worktree": {"branch": "feat-legacy"},
  "rate_limits": {
    "five_hour": {"used_percentage": 6, "resets_at": $five_h},
    "seven_day": {"used_percentage": 82, "resets_at": $seven_d}
  }
}
EOF
)
  run run_statusline_with_input "$stdin_json"
  [ "$status" -eq 0 ]
  local plain
  plain=$(echo "$output" | strip_ansi)
  echo "$plain" | grep -qF 'feat-legacy' \
    || { echo "expected branch from .worktree.branch schema fallback; got: $plain" >&2; false; }
}
