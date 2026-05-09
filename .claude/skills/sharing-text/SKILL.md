---
name: sharing-text
description: |
  Share text from terminal to iPhone via Pushover push function.
  Trigger: '텍스트 공유', 'push 명령어', '아이폰으로 보내', 'Pushover로 보내', 'URL 공유'.
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

# IP 주소 공유 (플랫폼별 분기 — hostname -I는 macOS 미지원)
hostname -I | awk '{print $1}' | push      # NixOS/Linux
ipconfig getifaddr en0 | push              # macOS

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
# 현재 경로 공유 (플랫폼 독립)
push "$(pwd)"

# 커널 정보 공유
push "$(uname -sr)"

# IP 주소 분기 예시는 위 "핵심 명령어" 섹션 참조
```

### 3. tmux-thumbs와 연계

```bash
# 1. prefix + F → 힌트 선택 → tmux buffer에 복사
# 2. push (인자 없이 실행)
push
```

### 4. AI 에이전트에서 텍스트 공유 요청 시

사용자가 "이거 공유해줘", "Pushover로 보내줘" 등의 요청을 하면, canonical 호출 형태는 **heredoc + stdin** 경로다. `push`는 `.zshrc`의 셸 함수이므로 `zsh -ic`(interactive)로 호출해야 로드된다 (`zsh -c` non-interactive는 `.zshrc` 미로드로 `push not found`).

```bash
zsh -ic 'push' <<'PUSH_END'
공유할 텍스트
PUSH_END
```

heredoc content는 stdin으로 전달되어 zsh 해석을 거치지 않는다. 사용자 제공 텍스트에 `$(...)`, backtick, quote가 포함돼도 안전하다. interactive zsh 초기화 과정에서 stderr에 `can't change option: zle` 경고가 표시될 수 있으나, `✓ Pushover 전송` 출력이면 전송 성공이다.

인자 형태(`zsh -ic 'push "<텍스트>"'`)는 사용자가 직접 터미널에 입력하는 경우에만 사용한다. AI 에이전트가 사용자 텍스트를 인자 문자열로 인터폴레이션하면 `$(...)`/backtick/quote가 push 호출 전 zsh에서 확장되므로 사용하지 마라.

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
| Pushover credentials | `$HOME/.config/pushover/share` 필요 (agenix 관리). 부재 시 함수가 `Error: Pushover credentials not found`을 stderr로 출력하고 `return 1` (non-zero) |
| zsh 함수 의존 | `push`는 `.zshrc`의 셸 함수. `zsh -c` (non-interactive) 호출은 `push not found`로 실패. canonical 호출은 `zsh -ic` |
| tmux buffer 경로 | 무인자 `push`는 `TMUX` 환경변수가 설정된 tmux 세션 필요. AI 에이전트 exec 세션에서는 기본 부재 — 인자 또는 stdin 경로를 사용하라 |

## 구현 위치

- **함수**: `modules/shared/programs/shell/default.nix` 내 `push()` 함수
- **Credentials**: `$HOME/.config/pushover/share` (agenix 관리)
- **입력 우선순위**: 인자 > 파이프(stdin) > tmux buffer

## 참조

- push() 함수 구현 상세: [references/push-implementation.md](references/push-implementation.md)
- QR 코드 방식 (deprecated): [references/archive-qr.md](references/archive-qr.md)
