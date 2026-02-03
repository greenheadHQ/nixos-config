---
name: sharing-qr
description: |
  This skill should be used when the user asks to "create QR code", "share text via QR",
  "MiniPC to iPhone", "qr 코드 생성", "QR로 공유", "텍스트를 QR로",
  or wants to transfer text from MiniPC/NixOS terminal to mobile device.
---

# QR 코드로 텍스트 공유

MiniPC(NixOS) 터미널에서 iPhone/모바일 기기로 텍스트를 공유하는 방법입니다.

## 핵심 명령어

터미널에서 `qr` 함수를 사용하여 텍스트를 QR 코드로 출력합니다. Unix-like 파이프 지원.

```bash
# 직접 텍스트 입력
qr "복사할 텍스트"
qr "https://github.com/user/repo"

# 파이프 입력 (Unix-like)
echo "hello" | qr
cat file.txt | qr
hostname -I | awk '{print $1}' | qr

# tmux buffer에서 읽기 (인자 없이 실행)
qr
```

## 사용 시나리오

### 1. URL 공유

```bash
qr "https://github.com/anthropics/claude-code"
```

### 2. 명령어 결과 공유

```bash
# IP 주소 공유
qr "$(hostname -I | awk '{print $1}')"

# 현재 경로 공유
qr "$(pwd)"
```

### 3. tmux-thumbs와 연계

```bash
# 1. prefix + F → 힌트 선택 → tmux buffer에 복사
# 2. qr (인자 없이 실행)
qr
```

### 4. Claude Code에서 QR 코드 생성 요청 시

사용자가 "QR 코드 만들어줘", "이거 QR로 공유해줘" 등의 요청을 하면:

```bash
# Bash 도구로 qr 함수 실행
qr "공유할 텍스트"
```

**중요**: 외부 QR 코드 생성 웹사이트나 API를 사용하지 않습니다. 로컬 `qr` 함수만 사용합니다.

## 워크플로우

```
[MiniPC] qr "텍스트" → QR 코드 출력 (UTF8 터미널)
    ↓
[iPhone] 카메라로 스캔 → 복사 (2-3탭, 약 5초)
```

## 제한사항

| 제한 | 설명 |
|------|------|
| 길이 제한 | ~2,000자 (더 길면 스캔 어려움) |
| 출력 환경 | UTF8 지원 터미널 필요 |
| 한글 | UTF8 인코딩으로 정상 지원 |

## 구현 위치

- **패키지**: `libraries/packages.nix` → `pkgs.qrencode`
- **함수**: `modules/shared/programs/shell/default.nix` → `qr()` 함수

## qr 함수 동작

```bash
qr() {
  local text
  if [ $# -gt 0 ]; then
    text="$*"                              # 1순위: 인자
  elif [ ! -t 0 ]; then
    text=$(cat)                            # 2순위: 파이프 (stdin)
  elif [ -n "$TMUX" ]; then
    text=$(tmux save-buffer - 2>/dev/null) # 3순위: tmux buffer
  fi
  [ -z "$text" ] && { echo "Usage: qr <text> or pipe input"; return 1; }
  echo "QR (${#text} chars):"
  echo "$text" | qrencode -t UTF8
}
```

**우선순위**: 인자 > 파이프 > tmux buffer

## 자주 묻는 질문

### Q: 긴 텍스트는 어떻게 공유하나요?

A: QR 코드는 ~2,000자 제한이 있습니다. 긴 텍스트는:
- 파일로 저장 후 immich 모바일 SSH로 전송
- 여러 개의 QR 코드로 분할

### Q: iPhone에서 스캔이 안 됩니다

A: 터미널 글꼴 크기를 키우거나, 터미널 창을 확대하여 QR 코드가 더 크게 표시되도록 합니다.

### Q: macOS에서도 사용 가능한가요?

A: `qrencode` 패키지가 shared에 포함되어 있어 macOS에서도 동일하게 사용 가능합니다.
