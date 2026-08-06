# Hammerspoon 단축키

Hammerspoon을 사용한 키보드 자동화 및 단축키 설정입니다.

## 목차

- [터미널 Ctrl/Opt 단축키 (한글 입력소스 문제 해결)](#터미널-ctrlopt-단축키-한글-입력소스-문제-해결)
- [Finder → Ghostty 터미널 열기](#finder--ghostty-터미널-열기)
- [Split 키보드(NocFree &) F키](#split-키보드nocfree--f키)

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

## Split 키보드(NocFree &) F키

`NocFree &` split 키보드는 펌웨어가 F10~F12를 macOS 미디어키로 내보냅니다. Hammerspoon은 그중 수식키 없는 F11만 가로채 "바탕화면 보기"로 바꿉니다.

| 입력 | 동작 | 처리 주체 |
| ---- | ---- | --------- |
| `F11` | 바탕화면 보기 | Hammerspoon eventtap |
| `Shift+F10` | 음소거 | 키보드 펌웨어 (통과) |
| `Shift+F11` | 볼륨 다운 | 키보드 펌웨어 (통과) |
| `Shift+F12` | 볼륨 업 | 키보드 펌웨어 (통과) |

내장 키보드 영향 없음: 미디어키 이벤트는 `keyboardType`이 0으로 들어와 장치를 구분할 수 없지만(일반 키 이벤트는 split=40 / 내장=91), 내장 키보드는 `fnState=true` 때문에 볼륨 조절 시 `fn` 플래그가 붙습니다 (내장 `fn+F11` → `SOUND_DOWN flags=[fn]`). 수식키가 전혀 없는 `SOUND_DOWN`만 가로채므로 내장 키보드의 볼륨 조절은 그대로 유지됩니다.

한계: 다른 외장 키보드를 연결하면 그 키보드의 볼륨 다운도 바탕화면 보기로 바뀝니다.

### F3 입력 불일치와 해결

이 키보드의 F키 대역은 펌웨어가 macOS 기본 레이아웃대로 할당해 두었지만, 일부 기능은 macOS에 신호가 도달하지 않거나 잘못 구현되어 있습니다. 키보드 설정 도구(`link.nocfree.com`)의 할당과 eventtap 실측을 대조한 결과:

| 물리 키 | 펌웨어 할당 | macOS가 실제로 받는 신호 |
| ------- | ----------- | ------------------------ |
| `F1` / `F2` | 밝기 -/+ | 밝기 다운 / 밝기 업 (정상) |
| `F3` | Mission Control | `Ctrl+Up` — 현재 macOS 단축키 설정과 불일치 |
| `F3` | Basic의 일반 `F3`로 교체 후 | Mission Control 정상 동작 (유선/Bluetooth/2.4GHz) |
| `F4` | Spotlight | `Cmd+S` (한글 입력 상태에서 "ㄴ"이 입력됨) |
| `F5` | 키보드 백라이트 - | 없음 — 신호가 도달하지 않음 |
| `F10` / `F11` / `F12` | 음소거 / Vol- / Vol+ | 음소거 / 볼륨 다운 / 볼륨 업 (정상) |

`Mission Control` 할당은 실제로 `Ctrl+Up`을 보내지만, 이 저장소는 macOS Mission Control 단축키를 `Fn+F3`(`AppleSymbolicHotKeys` 32번 = keycode 99 + fn 마스크 `0x800000`)로 선언합니다. 또한 `Ctrl+Up`은 Neovim 창 높이 조절에 사용하므로, 이를 전역 Mission Control 단축키로 되돌리거나 Hammerspoon에서 가로채면 기존 편집기 조작과 충돌합니다. 키보드 백라이트 F5는 기존 기록에서 신호가 관측되지 않았지만 이번 작업에서는 다시 검증하지 않았으므로 F3와 같은 원인이라고 단정하지 않습니다.

해결: 설정 도구에서 `layer 1`의 물리 F3 한 자리만 선택하고 `Basic`의 일반 `F3`로 바꿉니다. 그러면 현재 macOS Mission Control 단축키와 맞아 정상 동작합니다. 유선에서 변경한 뒤 Bluetooth와 2.4GHz로 전환해도 설정이 유지되는 것을 실측했습니다. 펌웨어 설정만으로 해결되며 Hammerspoon 개입은 필요 없습니다.

설정 도구는 키보드를 wired 모드로 전환한 뒤 `link.nocfree.com`에 접속해 사용합니다 (NocFree Lite의 Vial과 달리 이 모델은 전용 웹 도구를 사용). 같은 계열인 NocFree Lite 문서에는 유선/무선 설정이 분리 저장된다는 서술이 있으나, 이 모델에서는 유선으로 재할당한 뒤 도구를 닫고 Bluetooth로 되돌려도 설정이 유지되는 것을 실측 확인했습니다.

> F11도 같은 방식(일반 `F11` 키로 교체)으로 macOS 기본 "데스크탑 보기" 단축키에 걸릴 가능성이 있습니다. 다만 현재는 펌웨어가 `Vol -`를 보내는 상태를 전제로 위의 eventtap이 처리하며, 이쪽이 실측 검증을 마친 경로입니다.
>
> 미디어키 이벤트의 `data1` 디코딩: `NX_KEYTYPE = data1 >> 16` (0=볼륨 업, 1=볼륨 다운, 2=밝기 업, 3=밝기 다운, 7=음소거)
