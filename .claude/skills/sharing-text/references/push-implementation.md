# push 함수 구현 상세

## 소스 위치

`modules/shared/programs/shell/default.nix` 내 `push()` 함수

## 함수 코드

```bash
push() {
  local text
  if [ $# -gt 0 ]; then
    text="$*"
  elif [ ! -t 0 ]; then
    text=$(cat)
  elif [ -n "$TMUX" ]; then
    text=$(tmux save-buffer - 2>/dev/null)
  fi
  [ -z "$text" ] && { echo "Usage: push <text> or pipe input"; return 1; }

  local cred="$HOME/.config/pushover/claude-code"
  if [ ! -f "$cred" ]; then
    echo "Error: Pushover credentials not found" >&2
    return 1
  fi

  local PUSHOVER_TOKEN="" PUSHOVER_USER=""
  source "$cred"
  [ -n "${PUSHOVER_TOKEN:-}" ] && [ -n "${PUSHOVER_USER:-}" ] || {
    echo "Error: Pushover credentials are incomplete" >&2
    return 1
  }

  local response
  if response=$(curl --fail-with-body --show-error --silent --max-time 10 -X POST \
    -H "Content-Type: application/x-www-form-urlencoded; charset=utf-8" \
    --data-urlencode "token=$PUSHOVER_TOKEN" \
    --data-urlencode "user=$PUSHOVER_USER" \
    --data-urlencode "title=📋 텍스트 공유 (${#text}자)" \
    --data-urlencode "message=$text" \
    https://api.pushover.net/1/messages.json); then
    echo "✓ Pushover 전송 (${#text}자)"
  else
    echo "Error: Pushover 전송 실패" >&2
    [ -n "$response" ] && echo "$response" >&2
    return 1
  fi
}
```

## 입력 우선순위

인자 > 파이프(stdin) > tmux buffer

## Credentials

- 경로: `$HOME/.config/pushover/claude-code`
- 관리: agenix로 암호화
- 내용: `PUSHOVER_TOKEN`, `PUSHOVER_USER` 환경변수

## 에러 처리

| 상황 | 메시지 | 출력 |
|------|--------|------|
| 입력 없음 | `Usage: push <text> or pipe input` | stdout |
| credential 파일 없음 | `Error: Pushover credentials not found` | stderr |
| token/user 비어있음 | `Error: Pushover credentials are incomplete` | stderr |
| HTTP 에러 (4xx/5xx) | `Error: Pushover 전송 실패` + API 응답 body | stderr |
| 네트워크 실패 / 타임아웃 | curl 에러 + `Error: Pushover 전송 실패` | stderr |
