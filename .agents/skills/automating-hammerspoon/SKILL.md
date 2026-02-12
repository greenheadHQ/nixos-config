---
name: automating-hammerspoon
description: |
  Hammerspoon hotkeys, launchd agents, Ghostty terminal on macOS.
  Triggers: "open terminal from Finder", "setupLaunchAgents stuck",
  "HOME is /var/root" in launchd, Ghostty terminal issues.
---

# Hammerspoon 자동화

Hammerspoon 단축키, launchd 서비스, Ghostty 연동 가이드입니다.

## Known Issues

**darwin-rebuild 시 setupLaunchAgents 멈춤**
- launchd agent가 제대로 종료되지 않으면 멈출 수 있음
- 해결: `launchctl list | grep -v com.apple` 확인 후 문제 agent 제거

**한글 입력소스에서 Ctrl/Opt 단축키**
- macOS 기본 동작으로 한글 IME에서 Ctrl/Opt 키 조합이 동작 안 함
- Hammerspoon에서 eventtap으로 강제 처리

**Ghostty 새 인스턴스 문제**
- `open -a Ghostty` 시 새 인스턴스로 열림 (Dock에 여러 아이콘)
- Hammerspoon에서 `hs.application.find`로 기존 인스턴스 활용

## 빠른 참조

### 주요 단축키

| 단축키 | 동작 |
|--------|------|
| `Cmd+Shift+T` | Finder에서 현재 폴더로 Ghostty 열기 |
| `Ctrl+H/J/K/L` | Vim 스타일 방향키 (한글 IME 포함) |
| `Opt+H/L` | 단어 단위 이동 |

### 설정 파일 위치

| 파일 | 용도 |
|------|------|
| `~/.hammerspoon/init.lua` | Hammerspoon 메인 설정 |
| `~/Library/LaunchAgents/` | launchd 사용자 에이전트 |

### launchd 디버깅

```bash
# 현재 로드된 에이전트 확인
launchctl list | grep -v com.apple

# 특정 에이전트 상태
launchctl list <label>

# 에이전트 언로드
launchctl unload ~/Library/LaunchAgents/<plist>

# 에이전트 재로드
launchctl load ~/Library/LaunchAgents/<plist>
```

## 자주 발생하는 문제

1. **darwin-rebuild 멈춤**: launchd agent 충돌, 수동 언로드 필요
2. **HOME이 /var/root**: launchd 환경에서 HOME 미설정
3. **open --args 무시**: 이미 실행 중인 앱에 인수 전달 안 됨

## 레퍼런스

- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
- 단축키 목록: [references/hotkeys.md](references/hotkeys.md)
