# Hammerspoon 단축키

Hammerspoon을 사용한 키보드 자동화 및 단축키 설정입니다.

## 목차

- [터미널 Ctrl/Opt 단축키 (한글 입력소스 문제 해결)](#터미널-ctrlopt-단축키-한글-입력소스-문제-해결)
- [Finder → Ghostty 터미널 열기](#finder--ghostty-터미널-열기)

---

`modules/darwin/programs/hammerspoon/files/init.lua`에서 관리됩니다.

## 터미널 Ctrl/Opt 단축키 (한글 입력소스 문제 해결)

Claude Code 2.1.0+에서 한글 입력소스일 때 Ctrl/Opt 단축키가 동작하지 않는 문제를 Hammerspoon에서 시스템 레벨로 해결합니다.

문제 원인:

- Claude Code가 enhanced keyboard 모드(CSI u)를 활성화
- 한글 입력소스에서 Ctrl/Opt+알파벳 키가 다르게 처리됨
- Ghostty keybind 설정도 CSI u 모드에서 우회됨

해결 방식: Hammerspoon이 시스템 레벨에서 키 입력을 가로채서 영어로 전환 후 키 전달

정본 확인:

```bash
grep -n "ghosttyCtrlKeys" modules/darwin/programs/hammerspoon/files/init.lua
grep -n "terminalOptKeys" modules/darwin/programs/hammerspoon/files/init.lua
```

### Ghostty 전용 (Ctrl 키)

| 단축키 | 동작 |
|--------|------|
| `Ctrl+C` | 영어 전환 후 원래 Ctrl+C 전달 |
| `Ctrl+U` | 영어 전환 후 원래 Ctrl+U 전달 |
| `Ctrl+K` | 영어 전환 후 원래 Ctrl+K 전달 |
| `Ctrl+W` | 영어 전환 후 원래 Ctrl+W 전달 |
| `Ctrl+A` | 영어 전환 후 원래 Ctrl+A 전달 |
| `Ctrl+E` | 영어 전환 후 원래 Ctrl+E 전달 |
| `Ctrl+L` | 영어 전환 후 원래 Ctrl+L 전달 |
| `Ctrl+F` | 영어 전환 후 원래 Ctrl+F 전달 |
| `Ctrl+S` | 영어 전환 후 원래 Ctrl+S 전달 |
| `Ctrl+V` | 영어 전환 후 원래 Ctrl+V 전달 |
| `Ctrl+Z` | 영어 전환 후 원래 Ctrl+Z 전달 |
| `Ctrl+D` | 영어 전환 후 원래 Ctrl+D 전달 |
| `Ctrl+R` | 영어 전환 후 원래 Ctrl+R 전달 |
| `Ctrl+G` | 영어 전환 후 원래 Ctrl+G 전달 |
| `Ctrl+O` | 영어 전환 후 원래 Ctrl+O 전달 |
| `Ctrl+T` | 영어 전환 후 원래 Ctrl+T 전달 |
| `Ctrl+Y` | 영어 전환 후 원래 Ctrl+Y 전달 |

> Ghostty 외 앱에서는 Ctrl+V/Z/S 등 확장된 처리 키도 원래 앱 동작으로 재전달됩니다.

### 모든 터미널 앱 (Opt 키)

| 단축키  | 기능             |
| ------- | ---------------- |
| `Opt+B` | 단어 뒤로 이동   |
| `Opt+F` | 단어 앞으로 이동 |
| `Opt+D` | 단어 삭제        |

> 터미널 앱: Ghostty, Terminal.app, Warp, iTerm2

### 전역 (모든 앱)

| 단축키   | 기능                            |
| -------- | ------------------------------- |
| `Ctrl+B` | tmux prefix (영어 전환 후 전달) |

> 참고: 자세한 트러블슈팅은 [`references/troubleshooting.md`의 "한글 입력소스에서 Ctrl/Opt 단축키가 동작하지 않음"](troubleshooting.md#한글-입력소스에서-ctrlopt-단축키가-동작하지-않음) 섹션을 참고하세요.

## Finder → Ghostty 터미널 열기

| 단축키                    | 동작                                     |
| ------------------------- | ---------------------------------------- |
| `Ctrl + Option + Cmd + T` | 현재 Finder 경로에서 Ghostty 터미널 열기 |

동작 방식:

| 상황                     | 동작                                |
| ------------------------ | ----------------------------------- |
| Finder에서 실행          | 현재 폴더 경로로 Ghostty 새 창 열기 |
| Finder 바탕화면에서 실행 | Desktop 경로로 Ghostty 새 창 열기   |
| 다른 앱에서 실행         | Ghostty 새 창 열기 (기본 경로)      |
| Ghostty 미실행 시        | `open -a Ghostty`로 시작            |
| Ghostty 실행 중          | `Cmd+N`으로 새 창 + `cd` 명령어     |

구현 특징:

- AppleScript로 Finder 현재 경로 가져오기
- 경로에 특수문자(`[`, `]` 등)나 공백이 있어도 정상 동작 (따옴표 처리)
- Ghostty 실행 중일 때는 클립보드를 활용한 경로 전달 (한글 경로 문제 방지)
- IPC 모듈 로드로 CLI에서 `hs` 명령 사용 가능
- 설정 리로드 완료 시 macOS 알림 표시

> 참고: 구현 과정에서 발생한 문제와 해결 방법은 [`references/troubleshooting.md`의 "Hammerspoon 관련"](troubleshooting.md#hammerspoon-관련) 섹션을 참고하세요.
