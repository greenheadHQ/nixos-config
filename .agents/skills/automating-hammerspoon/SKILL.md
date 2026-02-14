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
- Ghostty 바이너리를 직접 실행하면 새 인스턴스로 열릴 수 있음 (Dock에 여러 아이콘)
- 해결: 실행 중이면 `hs.application.get("Ghostty")` + `Cmd+N`, 미실행이면 `open -a Ghostty`

## 빠른 참조

### 주요 단축키

| 단축키 | 동작 |
|--------|------|
| `Ctrl+Option+Cmd+T` | Finder에서 현재 폴더로 Ghostty 열기 |
| `Ctrl+;` | 영어 입력으로 전환 |
| `Cmd+Shift+Space` | 영어 전환 후 Homerow 실행 |
| `Ctrl+B` | 영어 전환 후 tmux prefix 전달 |
| `Ctrl+C/U/K/W/A/E/L/F` | Ghostty 전용 Ctrl 단축키 (CSI u 우회) |
| `Opt+B/F` | 터미널 앱에서 단어 단위 이동 |

### 설정 파일 위치

| 파일 | 용도 |
|------|------|
| `~/.hammerspoon/init.lua` | Hammerspoon 메인 설정 |
| `~/.hammerspoon/foundation_remapping.lua` | Caps Lock → F18 리매핑 |
| `~/.hammerspoon/atuin_menubar.lua` | Atuin 메뉴바 상태 표시 |
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
