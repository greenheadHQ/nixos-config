---
name: sharing-text
description: |
  Terminal-to-iPhone text sharing via the `push` shell function and Pushover
  push notifications. Supports direct text, pipe input, and tmux buffer.
  Triggers: "share text", "push text", "terminal to iPhone",
  "텍스트 공유", "Pushover로 보내", "텍스트를 아이폰으로",
  "push 함수", "push 명령어", "아이폰으로 보내",
  "pipe to push", "tmux buffer to phone", "URL 공유".
---

# Pushover로 텍스트 공유

macOS/NixOS 터미널에서 iPhone으로 텍스트를 공유하는 방법입니다.

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
[macOS/NixOS] push "텍스트" → Pushover 전송
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

## 지원 범위

| 항목 | 지원 |
|------|------|
| 한글/일본어/중국어 | O |
| 이모지 | O |
| 특수문자 (ñ é © € 등) | O |
| 여러 줄 텍스트 | O |
| 파이프 입력 | O |

## 제한사항

| 제한 | 설명 |
|------|------|
| Pushover 메시지 제한 | 1,024자 (초과 시 잘림) |
| 네트워크 | 인터넷 연결 필요 |

## 구현 위치

- **함수**: `modules/shared/programs/shell/default.nix` 내 `push()` 함수
- **Credentials**: `$HOME/.config/pushover/claude-code` (agenix 관리)
- **입력 우선순위**: 인자 > 파이프(stdin) > tmux buffer

## 참조

- push() 함수 구현 상세: [references/push-implementation.md](references/push-implementation.md)
- QR 코드 방식 (deprecated): [references/archive-qr.md](references/archive-qr.md)
