# 트러블슈팅

Hammerspoon 및 Ghostty 터미널 관련 문제와 해결 방법을 정리합니다.

## 목차

- [Hammerspoon 관련](#hammerspoon-관련)
  - [Ghostty가 새 인스턴스로 열림](#ghostty가-새-인스턴스로-열림-dock에-여러-아이콘)
  - [Ghostty +new-window가 macOS에서 동작하지 않음](#ghostty-new-window가-macos에서-동작하지-않음)
  - [open --args가 이미 실행 중인 앱에 인수 전달 안 됨](#open---args가-이미-실행-중인-앱에-인수-전달-안-됨)
  - [cd 명령어가 기존 창에 입력됨](#cd-명령어가-기존-창에-입력됨-타이밍-문제)
  - [경로에 특수문자가 있으면 zsh 에러 발생](#경로에-특수문자가-있으면-zsh-에러-발생)
  - [hs CLI 명령어가 작동하지 않음](#hs-cli-명령어가-작동하지-않음-ipc-오류)
  - [keyStrokes로 한글 경로 입력 시 깨짐](#keystrokes로-한글-경로-입력-시-깨짐)
- [Ghostty 관련](#ghostty-관련)
  - [한글 입력소스에서 Ctrl/Opt 단축키가 동작하지 않음](#한글-입력소스에서-ctrlopt-단축키가-동작하지-않음)
  - [Ctrl+C 입력 시 "5u9;" 같은 문자가 출력됨](#ctrlc-입력-시-5u9-같은-문자가-출력됨)

---

## Hammerspoon 관련

Finder → Ghostty 터미널 열기 단축키 구현 시 발생한 문제들입니다.

### Ghostty가 새 인스턴스로 열림 (Dock에 여러 아이콘)

증상: 단축키로 Ghostty를 열 때마다 Dock에 새로운 Ghostty 아이콘이 생성됨

원인: `hs.task.new`로 바이너리를 직접 실행하면 매번 새 인스턴스가 생성됨

```lua
-- ❌ 새 인스턴스 생성됨
hs.task.new("/Applications/Ghostty.app/Contents/MacOS/ghostty", nil, args):start()
```

해결: 미실행이면 `/usr/bin/open -a Ghostty`를 사용하고, 실행 중이면 기존 앱의 AppleScript `new window`로 창을 만든다. 바이너리를 직접 실행하거나 `Cmd+N`을 전역으로 보내지 않는다.

---

### Ghostty +new-window가 macOS에서 동작하지 않음

이 단축키는 `+new-window` CLI 경로를 사용하지 않는다. macOS에서는 Ghostty의 AppleScript 새 창 API로 초기 작업 폴더를 전달한다.

- 미실행: `open -a Ghostty --args --working-directory=<path>`를 인자 배열로 실행한다.
- 실행 중: `new surface configuration`의 `initial working directory`를 설정하고 `new window with configuration`을 호출한다.

API 정본은 설치된 앱의 `Ghostty.sdef`와 [공식 AppleScript 문서](https://ghostty.org/docs/features/applescript)다. 지원 API가 없는 버전에서는 생성 오류를 알리고 중단한다.

---

### open --args가 이미 실행 중인 앱에 인수 전달 안 됨

`open --args`는 실행 중인 앱에 초기 실행 인수를 전달하는 경로로 사용할 수 없다. 그래서 `init.lua`는 앱 실행 여부에 따라 위 두 경로를 나눈다.

실행 중 분기는 고정 AppleScript의 `on run argv`로 폴더 경로를 받는다. `hs.task`가 `/usr/bin/osascript`에 문자열 배열을 넘기므로 폴더 이름을 셸이나 스크립트 코드로 해석하지 않는다. 생성 요청이 반환한 창만 활성화하고, 기존 창에는 명령·Enter를 보내지 않는다.

Ghostty가 AppleScript를 지원하지 않거나 `macos-applescript = false`이면 실패 알림을 확인한다. macOS 자동화 권한이 없으면 요청이 거절되거나 시스템 확인창이 나타날 수 있다. 권한 변경은 사용자가 실행 주체와 Ghostty 대상을 확인한 뒤 승인한다. 실패 시 키 입력 방식으로 자동 재시도하지 않는다.

---

### cd 명령어가 기존 창에 입력됨 (타이밍 문제)

이전 구현은 활성화와 `Cmd+N` 뒤 고정 시간만 기다린 다음 `cd`를 붙여넣었다. 그 사이 포커스가 바뀌거나 창 생성이 늦으면 다른 창에 입력될 수 있었다.

현재 구현은 새 창 생성 API에 초기 경로를 함께 전달한다. 대기 시간을 늘리거나 포커스를 추측하는 타이머가 없으며, 각 호출은 별도의 설정과 새 창을 사용한다. 요청이 실패하면 알림만 남기고 입력을 보내지 않는다.

---

### 경로에 특수문자가 있으면 zsh 에러 발생

이전 `cd` 문자열 방식에서는 공백·따옴표·확장 문자가 셸 구문으로 해석될 수 있어 작은따옴표 인용을 사용했다 (#1405, #1475).

현재 Finder 단축키는 셸 명령을 만들지 않는다. 한글·공백·따옴표·역슬래시 등은 초기 작업 폴더의 데이터로 전달한다. 기존 개행 거부 정책은 유지하며, 프로세스 인자로 전달할 수 없는 NUL도 거부한다. 문자를 지우거나 경로를 바꾸지 않고 새 창 요청 전에 중단한다.

합성 검증은 `nix develop --command bash tests/run-finder-ghostty-tests.sh`를 사용한다. 실제 macOS에서의 새 창 생성·경로 전달과 자동화 권한 확인은 별도이며, 합성 검사 성공만으로 실측 성공을 기록하지 않는다.

---

### hs CLI 명령어가 작동하지 않음 (IPC 오류)

증상: `hs -c 'hs.notify...'` 실행 시 오류 발생

```text
error: can't access Hammerspoon message port Hammerspoon; is it running with the ipc module loaded?
```

원인: `init.lua`에 IPC 모듈이 로드되지 않음

해결: `init.lua` 상단에 IPC 모듈 로드 추가

```lua
-- init.lua 최상단에 추가
require("hs.ipc")
```

추가 문제: IPC 포트 불안정 (장시간 실행 후)

```text
ipc port is no longer valid (early)
stack overflow
```

해결: Hammerspoon 재시작

```bash
pkill Hammerspoon && open -a Hammerspoon
# 또는
hsr  # alias 사용 (IPC가 작동할 때만)
```

영향: IPC 모듈이 없으면 `darwin-rebuild` 시 자동 리로드가 작동하지 않음

`modules/darwin/configuration.nix`의 activation script에서 `hs -c "hs.reload()"`를 실행하는데, IPC 모듈이 로드되지 않은 상태에서는 이 명령이 실패합니다 (`|| true`로 무시됨).

```nix
# darwin-rebuild 시 실행되는 activation script
/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs -c "hs.reload()" 2>/dev/null || true
```

결과: IPC 모듈 추가 전에는 `nrs` 실행 후에도 Hammerspoon 설정이 자동 리로드되지 않아 수동 리로드가 필요했음. 오랫동안 원인을 모른 채 수동 리로드를 해왔는데, IPC 모듈 누락이 원인이었음.

---

### keyStrokes로 한글 경로 입력 시 깨짐

Finder 단축키는 `keyStrokes`와 클립보드 붙여넣기를 모두 사용하지 않는다. 한글을 포함한 경로를 새 창의 초기 작업 폴더로 전달하므로 입력 소스나 붙여넣기 순서를 맞추지 않는다.

클립보드는 읽거나 덮어쓰지 않는다. 따라서 텍스트뿐 아니라 이미지·파일 참조·복합 표현을 텍스트로 축소하지 않으며, 요청 도중 사용자가 새로 복사한 내용도 복원 타이머에 덮이지 않는다. 합성 검사에서는 클립보드 API 호출 자체를 거부한다. 적용 후 실제 macOS에서 정상 전달과 대표 비텍스트 형식 보존을 따로 확인한다.

---

## Ghostty 관련

### 한글 입력소스에서 Ctrl/Opt 단축키가 동작하지 않음

증상: Claude Code 2.1.0+ 사용 시, 한글 입력소스에서 Ctrl+C, Ctrl+U, Ctrl+S, Ctrl+V, Opt+B, Opt+D 등의 단축키가 동작하지 않음. 영문 입력소스로 전환하면 정상 동작.

원인: Claude Code 2.1.0이 enhanced keyboard 모드(CSI u)를 적극 활용하면서 발생하는 문제입니다.

| 환경 | Ctrl 단축키 | Opt 단축키 |
|------|------------|---------|
| Terminal.app | ✅ 입력소스 무관 | ❌ 한글일 때 문제 |
| Ghostty + Claude Code | ❌ 영문일 때만 | ❌ 영문일 때만 |

왜 Ghostty keybind로 해결 안 되는가?

```
[일반 CLI 앱] (cat, vim 등)
Ghostty keybind → legacy 시퀀스 전송 → 정상 동작 ✓

[Claude Code 2.1.0+]
Claude Code가 enhanced keyboard 모드 활성화 → Ghostty keybind 우회됨 ✗
```

`cat -v`에서는 한글 입력소스에서도 `^C`가 정상 출력되지만, Claude Code에서는 동작하지 않습니다.

해결: Hammerspoon에서 시스템 레벨로 처리

Hammerspoon이 키 입력을 시스템 레벨에서 가로채서 영어로 전환 후 키를 다시 전달합니다. Claude Code보다 먼저 처리되므로 확실히 동작합니다.

현행 처리 키 목록은 `references/hotkeys.md`에만 유지합니다. 정본 배열과 실제 분기 로직은 `modules/darwin/programs/hammerspoon/files/init.lua`에서 확인합니다.

```bash
grep -n "ghosttyCtrlKeys" modules/darwin/programs/hammerspoon/files/init.lua
grep -n "terminalOptKeys" modules/darwin/programs/hammerspoon/files/init.lua
```

검증:

```bash
# Hammerspoon 콘솔에서 확인
hs -c 'print(hs.application.frontmostApplication():bundleID())'
# 예상: com.mitchellh.ghostty

# Ghostty에서 한글 입력소스로 테스트
# 1. claude 실행
# 2. Ctrl+C → 정상 중단되어야 함
# 3. Ctrl+U/S/V/Z 등 → 해당 Ctrl 동작이 전달되어야 함
# 4. Opt 단축키 → 단어 이동/삭제 동작이 전달되어야 함
```

주의사항:

| 항목 | 설명 |
|------|------|
| Ghostty 외 앱 | Ctrl+V/Z/S 등 확장된 Ctrl 키도 원래 앱 동작으로 재전달 |
| 터미널 외 앱 | Opt 키는 원래 동작 유지 (브라우저에서 특수문자 입력) |
| 입력소스 전환 | 메뉴바 아이콘이 잠깐 깜빡일 수 있음 (기능 문제 없음) |

---

### Ctrl+C 입력 시 "5u9;" 같은 문자가 출력됨

증상: Ghostty 터미널에서 Ctrl+C를 누르면 프로세스가 중단되지 않고 `5u9;` 같은 문자가 출력됨. 간헐적으로 발생하며, 새 탭을 열거나 Ghostty를 재시작하면 정상으로 돌아옴.

원인: CSI u (Kitty Keyboard Protocol) 이스케이프 시퀀스가 해석되지 않고 raw 문자로 출력됨.

```
"5u9;" = ESC [ 99 ; 5 u 의 일부
         ↑    ↑    ↑
         |    |    └── Ctrl modifier 비트
         |    └── ASCII 'c' (99)
         └── CSI u 형식
```

근본 원인: Claude Code 등 일부 CLI 도구가 CSI u 모드를 활성화한 후 비활성화하지 않음. 터미널이 CSI u 모드에 "갇힌" 상태가 됨.

해결:

이 프로젝트에서는 Hammerspoon으로 해결합니다. 자세한 내용은 [한글 입력소스에서 Ctrl/Opt 단축키가 동작하지 않음](#한글-입력소스에서-ctrlopt-단축키가-동작하지-않음)을 참고하세요.

임시 복구 (CSI u 모드에 갇힌 경우):

```bash
# 직접 실행
printf "\033[?u\033[<u"

# 또는 새 탭 열기/Ghostty 재시작
```

> Ghostty 1.3.0부터 CSI u 복원이 자체 처리되어 `reset-term` alias는 제거됨 (PR #184).
