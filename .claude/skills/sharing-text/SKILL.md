---
name: sharing-text
description: |
  This skill should be used when the user asks to "share text", "push text",
  "MiniPC to iPhone", "텍스트 공유", "Pushover로 보내", "텍스트를 아이폰으로",
  or wants to transfer text from MiniPC/NixOS terminal to mobile device.
---

# Pushover로 텍스트 공유

MiniPC(NixOS) 터미널에서 iPhone으로 텍스트를 공유하는 방법입니다.

## 핵심 명령어

터미널에서 `push` 함수를 사용하여 텍스트를 Pushover로 iPhone에 전송합니다.

```bash
# 직접 텍스트 입력
push "복사할 텍스트"
push "https://github.com/user/repo"

# 파이프 입력 (Unix-like)
echo "hello" | push
cat file.txt | push
hostname -I | awk '{print $1}' | push

# tmux buffer에서 읽기 (인자 없이 실행)
push
```

## 워크플로우

```
[MiniPC] push "텍스트" → Pushover 전송
    ↓
[iPhone] 알림 수신 → 복사 버튼 탭 (1탭, 약 1초)
```

## 사용 시나리오

### 1. URL 공유

```bash
push "https://github.com/anthropics/claude-code"
```

### 2. 명령어 결과 공유

```bash
# IP 주소 공유
push "$(hostname -I | awk '{print $1}')"

# 현재 경로 공유
push "$(pwd)"
```

### 3. tmux-thumbs와 연계

```bash
# 1. prefix + F → 힌트 선택 → tmux buffer에 복사
# 2. push (인자 없이 실행)
push
```

### 4. Claude Code에서 텍스트 공유 요청 시

사용자가 "이거 공유해줘", "Pushover로 보내줘" 등의 요청을 하면:

```bash
# Bash 도구로 push 함수 실행
push "공유할 텍스트"
```

## 제한사항

| 제한 | 설명 |
|------|------|
| Pushover 메시지 제한 | 1,024자 (긴 메시지는 잘림) |
| 네트워크 | 인터넷 연결 필요 |

## 구현 위치

- **함수**: `modules/shared/programs/shell/default.nix` → `push()` 함수
- **Credentials**: `$HOME/.config/pushover/claude-code` (agenix 관리)

## push 함수 동작

```bash
push() {
  local text
  if [ $# -gt 0 ]; then
    text="$*"                              # 1순위: 인자
  elif [ ! -t 0 ]; then
    text=$(cat)                            # 2순위: 파이프 (stdin)
  elif [ -n "$TMUX" ]; then
    text=$(tmux save-buffer - 2>/dev/null) # 3순위: tmux buffer
  fi
  [ -z "$text" ] && return 1

  source "$HOME/.config/pushover/claude-code"
  curl -s --data-urlencode "message=$text" \
    --data-urlencode "token=$PUSHOVER_TOKEN" \
    --data-urlencode "user=$PUSHOVER_USER" \
    https://api.pushover.net/1/messages.json
}
```

**우선순위**: 인자 > 파이프 > tmux buffer

---

## 아카이브: QR 코드 방식 (deprecated)

> 이전에 QR 코드를 사용한 텍스트 공유를 시도했으나, Pushover의 클립보드 복사 기능이
> 더 편리하여 deprecated 되었습니다. 기록 목적으로 남겨둡니다.

### QR 코드 방식의 문제점

1. **스캔 필요**: iPhone 카메라로 QR 코드를 스캔해야 함 (2-3탭)
2. **크기 제한**: 600 bytes 초과 시 iPhone Termius 화면에 다 안 들어감
3. **폰트 의존성**: Termius에서 JetBrains Mono 폰트 필요 (Fira Code는 블록 문자 깨짐)
4. **한글 문제**: UTF-8에서 한글은 3바이트라 실제 200자 정도만 가능

### QR 코드 생성 방법 (참고용)

```bash
# qrencode 패키지 필요
echo "텍스트" | qrencode -t UTF8

# PNG 파일로 저장
echo "텍스트" | qrencode -o output.png
```

### Pushover vs QR 코드 비교

| 항목 | Pushover | QR 코드 |
|------|----------|---------|
| 복사 방법 | 알림에서 1탭 | 카메라 스캔 후 2-3탭 |
| 길이 제한 | 1,024자 | ~600 bytes (한글 ~200자) |
| 네트워크 | 필요 | 불필요 |
| 편의성 | ⭐⭐⭐ | ⭐ |
