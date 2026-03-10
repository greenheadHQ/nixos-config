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

**증상**: 단축키로 Ghostty를 열 때마다 Dock에 새로운 Ghostty 아이콘이 생성됨

**원인**: `hs.task.new`로 바이너리를 직접 실행하면 매번 새 인스턴스가 생성됨

```lua
-- ❌ 새 인스턴스 생성됨
hs.task.new("/Applications/Ghostty.app/Contents/MacOS/ghostty", nil, args):start()
```

**해결**: `open` 명령어를 사용하거나, 실행 중인 앱에 키 입력 시뮬레이션 사용

```lua
-- ✅ 기존 인스턴스 사용
hs.task.new("/usr/bin/open", nil, {"-a", "Ghostty"}):start()

-- ✅ 또는 키 입력 시뮬레이션
ghostty:activate()
hs.eventtap.keyStroke({"cmd"}, "n")  -- 새 창
```

---

### Ghostty +new-window가 macOS에서 동작하지 않음

**증상**: `ghostty +new-window --working-directory=/path` 실행해도 아무 일도 일어나지 않음

**원인**: Ghostty의 `+new-window` 액션은 **GTK (Linux) 전용**이며 macOS에서는 지원되지 않음

```bash
$ ghostty +new-window --help
# ...
# Only supported on GTK.
```

**해결**: macOS에서는 다른 방법 사용 필요:
- Ghostty 미실행 시: `open -a Ghostty --args --working-directory=/path`
- Ghostty 실행 중: `Cmd+N` 키 입력 + `cd` 명령어 타이핑

---

### open --args가 이미 실행 중인 앱에 인수 전달 안 됨

**증상**: `open -a Ghostty --args --working-directory=/path` 실행해도 Ghostty가 해당 경로에서 열리지 않음

**원인**: macOS의 `open` 명령어는 앱이 이미 실행 중이면 **인수를 전달하지 않고 단순 활성화**만 함

**해결**: Ghostty가 실행 중인지 확인하고 분기 처리

```lua
local ghostty = hs.application.get("Ghostty")

if ghostty then
  -- 실행 중: Cmd+N으로 새 창 + cd 명령어
  ghostty:activate()
  hs.timer.doAfter(0.2, function()
    hs.eventtap.keyStroke({"cmd"}, "n")
    hs.timer.doAfter(0.6, function()
      hs.eventtap.keyStrokes('cd "' .. path .. '" && clear')
      hs.eventtap.keyStroke({}, "return")
    end)
  end)
else
  -- 미실행: open으로 시작
  hs.task.new("/usr/bin/open", nil, {"-a", "Ghostty", "--args", "--working-directory=" .. path}):start()
end
```

---

### cd 명령어가 기존 창에 입력됨 (타이밍 문제)

**증상**: 단축키 실행 시 새 창이 아닌 기존 창에 `cd` 명령어가 입력됨

**원인**: `Cmd+N`으로 새 창이 열리기 전에 `cd` 명령어가 입력됨 (딜레이 부족)

**해결**: 적절한 딜레이 추가

```lua
-- ❌ 딜레이 부족
hs.timer.doAfter(0.1, function()
  hs.eventtap.keyStroke({"cmd"}, "n")
  hs.timer.doAfter(0.2, function()  -- 너무 짧음
    hs.eventtap.keyStrokes('cd ...')
  end)
end)

-- ✅ 충분한 딜레이
hs.timer.doAfter(0.2, function()
  hs.eventtap.keyStroke({"cmd"}, "n")
  hs.timer.doAfter(0.6, function()  -- 새 창이 완전히 열릴 때까지 대기
    hs.eventtap.keyStrokes('cd ...')
  end)
end)
```

> **참고**: 딜레이는 시스템 성능에 따라 조정이 필요할 수 있음. 0.6초가 안정적.

---

### 경로에 특수문자가 있으면 zsh 에러 발생

**증상**: `[FA]Get Compressed Video` 같은 폴더에서 실행 시 에러

```
zsh: no matches found: /Users/green/FolderActions/[FA]Get
```

**원인**: `[`, `]` 등의 특수문자가 zsh glob 패턴으로 해석됨. 공백도 문제 발생.

**해결**: 경로를 큰따옴표로 감싸기

```lua
-- ❌ 특수문자/공백 문제
hs.eventtap.keyStrokes('cd ' .. path .. ' && clear')

-- ✅ 따옴표로 감싸기
hs.eventtap.keyStrokes('cd "' .. path .. '" && clear')
```

---

### hs CLI 명령어가 작동하지 않음 (IPC 오류)

**증상**: `hs -c 'hs.notify...'` 실행 시 오류 발생

```
error: can't access Hammerspoon message port Hammerspoon; is it running with the ipc module loaded?
```

**원인**: `init.lua`에 IPC 모듈이 로드되지 않음

**해결**: `init.lua` 상단에 IPC 모듈 로드 추가

```lua
-- init.lua 최상단에 추가
require("hs.ipc")
```

**추가 문제**: IPC 포트 불안정 (장시간 실행 후)

```
ipc port is no longer valid (early)
stack overflow
```

**해결**: Hammerspoon 재시작

```bash
pkill Hammerspoon && open -a Hammerspoon
# 또는
hsr  # alias 사용 (IPC가 작동할 때만)
```

**영향**: IPC 모듈이 없으면 `darwin-rebuild` 시 자동 리로드가 작동하지 않음

`modules/darwin/configuration.nix`의 activation script에서 `hs -c "hs.reload()"`를 실행하는데, IPC 모듈이 로드되지 않은 상태에서는 이 명령이 실패합니다 (`|| true`로 무시됨).

```nix
# darwin-rebuild 시 실행되는 activation script
/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs -c "hs.reload()" 2>/dev/null || true
```

**결과**: IPC 모듈 추가 전에는 `nrs` 실행 후에도 Hammerspoon 설정이 자동 리로드되지 않아 수동 리로드가 필요했음. 오랫동안 원인을 모른 채 수동 리로드를 해왔는데, IPC 모듈 누락이 원인이었음.

---

### keyStrokes로 한글 경로 입력 시 깨짐

**증상**: 경로에 한글이 포함되면 `cd` 명령어가 제대로 입력되지 않음

**원인**: `hs.eventtap.keyStrokes`는 글자를 한 자씩 타이핑하므로, 입력 소스 상태에 영향받음

**해결**: 클립보드를 활용한 방식으로 변경

```lua
-- ❌ keyStrokes 방식 (한글 경로 문제)
hs.eventtap.keyStrokes('cd "' .. path .. '" && clear')

-- ✅ 클립보드 방식 (한글 경로 안전)
local prevClipboard = hs.pasteboard.getContents()
hs.pasteboard.setContents('cd "' .. path .. '" && clear')
hs.eventtap.keyStroke({"cmd"}, "v")
hs.eventtap.keyStroke({}, "return")
-- 클립보드 복원
hs.timer.doAfter(0.1, function()
    if prevClipboard then
        hs.pasteboard.setContents(prevClipboard)
    end
end)
```

---

## Ghostty 관련

### 한글 입력소스에서 Ctrl/Opt 단축키가 동작하지 않음

**증상**: Claude Code 2.1.0+ 사용 시, 한글 입력소스에서 Ctrl+C, Ctrl+U, Opt+B 등의 단축키가 동작하지 않음. 영문 입력소스로 전환하면 정상 동작.

**원인**: Claude Code 2.1.0이 enhanced keyboard 모드(CSI u)를 적극 활용하면서 발생하는 문제입니다.

| 환경 | Ctrl 단축키 | Opt+B/F |
|------|------------|---------|
| Terminal.app | ✅ 입력소스 무관 | ❌ 한글일 때 문제 |
| Ghostty + Claude Code | ❌ 영문일 때만 | ❌ 영문일 때만 |

**왜 Ghostty keybind로 해결 안 되는가?**

```
[일반 CLI 앱] (cat, vim 등)
Ghostty keybind → legacy 시퀀스 전송 → 정상 동작 ✓

[Claude Code 2.1.0+]
Claude Code가 enhanced keyboard 모드 활성화 → Ghostty keybind 우회됨 ✗
```

`cat -v`에서는 한글 입력소스에서도 `^C`가 정상 출력되지만, Claude Code에서는 동작하지 않습니다.

**해결**: Hammerspoon에서 시스템 레벨로 처리

Hammerspoon이 키 입력을 **시스템 레벨**에서 가로채서 영어로 전환 후 키를 다시 전달합니다. Claude Code보다 먼저 처리되므로 확실히 동작합니다.

**설정 파일**: `modules/darwin/programs/hammerspoon/files/init.lua`

```lua
-- Ghostty 전용: Ctrl 키 조합
local ghosttyCtrlKeys = {'c', 'u', 'k', 'w', 'a', 'e', 'l', 'f'}

for _, key in ipairs(ghosttyCtrlKeys) do
    local bind
    bind = hs.hotkey.bind({'ctrl'}, key, function()
        if isGhostty() then
            convertToEngAndSendKey(bind, {'ctrl'}, key)
        else
            bind:disable()
            hs.eventtap.keyStroke({'ctrl'}, key)
            bind:enable()
        end
    end)
end

-- 모든 터미널: Opt 키 조합
local terminalOptKeys = {'b', 'f'}

for _, key in ipairs(terminalOptKeys) do
    local bind
    bind = hs.hotkey.bind({'alt'}, key, function()
        if isTerminalApp() then
            convertToEngAndSendKey(bind, {'alt'}, key)
        else
            bind:disable()
            hs.eventtap.keyStroke({'alt'}, key)
            bind:enable()
        end
    end)
end
```

**검증**:

```bash
# Hammerspoon 콘솔에서 확인
hs -c 'print(hs.application.frontmostApplication():bundleID())'
# 예상: com.mitchellh.ghostty

# Ghostty에서 한글 입력소스로 테스트
# 1. claude 실행
# 2. Ctrl+C → 정상 중단되어야 함
# 3. Ctrl+U → 줄 삭제되어야 함
# 4. Opt+B/F → 단어 이동되어야 함
```

**주의사항**:

| 항목 | 설명 |
|------|------|
| Ghostty 외 앱 | Ctrl 키는 원래 동작 유지 (VS Code에서 Ctrl+C는 복사) |
| 터미널 외 앱 | Opt 키는 원래 동작 유지 (브라우저에서 특수문자 입력) |
| 입력소스 전환 | 메뉴바 아이콘이 잠깐 깜빡일 수 있음 (기능 문제 없음) |

---

### Ctrl+C 입력 시 "5u9;" 같은 문자가 출력됨

**증상**: Ghostty 터미널에서 Ctrl+C를 누르면 프로세스가 중단되지 않고 `5u9;` 같은 문자가 출력됨. 간헐적으로 발생하며, 새 탭을 열거나 Ghostty를 재시작하면 정상으로 돌아옴.

**원인**: CSI u (Kitty Keyboard Protocol) 이스케이프 시퀀스가 해석되지 않고 raw 문자로 출력됨.

```
"5u9;" = ESC [ 99 ; 5 u 의 일부
         ↑    ↑    ↑
         |    |    └── Ctrl modifier 비트
         |    └── ASCII 'c' (99)
         └── CSI u 형식
```

**근본 원인**: Claude Code 등 일부 CLI 도구가 CSI u 모드를 활성화한 후 비활성화하지 않음. 터미널이 CSI u 모드에 "갇힌" 상태가 됨.

**해결**:

이 프로젝트에서는 **Hammerspoon**으로 해결합니다. 자세한 내용은 [한글 입력소스에서 Ctrl/Opt 단축키가 동작하지 않음](#한글-입력소스에서-ctrlopt-단축키가-동작하지-않음)을 참고하세요.

**임시 복구** (CSI u 모드에 갇힌 경우):

```bash
# 직접 실행
printf "\033[?u\033[<u"

# 또는 새 탭 열기/Ghostty 재시작
```

> Ghostty 1.3.0부터 CSI u 복원이 자체 처리되어 `reset-term` alias는 제거됨 (PR #184).
