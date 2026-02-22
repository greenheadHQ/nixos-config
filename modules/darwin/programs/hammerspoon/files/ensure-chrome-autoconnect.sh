#!/usr/bin/env bash
set -euo pipefail

CHROME_APP="Google Chrome"
LOG_PREFIX="[ensure-chrome-auto-connect]"

if [ ! -d "/Applications/${CHROME_APP}.app" ]; then
  echo "$LOG_PREFIX Chrome app not found: /Applications/${CHROME_APP}.app" >&2
  exit 1
fi

# 이미 devtools 연결 가능 상태면 inspect 탭을 강제로 띄우지 않는다.
if curl -fsS "http://127.0.0.1:9222/json/version" >/dev/null 2>&1; then
  exit 0
fi

if ! pgrep -x "$CHROME_APP" >/dev/null 2>&1; then
  /usr/bin/open -a "$CHROME_APP"
fi

for _ in $(seq 1 30); do
  if pgrep -x "$CHROME_APP" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done

if ! pgrep -x "$CHROME_APP" >/dev/null 2>&1; then
  echo "$LOG_PREFIX Failed to launch Chrome" >&2
  exit 1
fi

# autoConnect 모드 초기 설정: 사용자가 chrome://inspect/#remote-debugging에서
# Remote Debugging 토글/승인을 완료할 수 있도록 탭을 열어둔다.
/usr/bin/osascript <<'APPLESCRIPT' >/dev/null
tell application "Google Chrome"
  activate
  try
    if (count of windows) = 0 then
      make new window
      delay 0.2
    end if
    tell window 1
      set newTab to make new tab at end of tabs
      set URL of newTab to "chrome://inspect/#remote-debugging"
      set active tab index to (count of tabs)
    end tell
  on error errMsg
    try
      make new window
      delay 0.2
      set URL of active tab of window 1 to "chrome://inspect/#remote-debugging"
    on error
      error "Failed to open chrome://inspect/#remote-debugging: " & errMsg
    end try
  end try
end tell
APPLESCRIPT

exit 0
