# 트러블슈팅

nix-darwin 및 macOS 시스템 설정 관련 문제와 해결 방법을 정리합니다.

## 목차

- [왜 darwin-rebuild에 sudo가 필요한가?](#왜-darwin-rebuild에-sudo가-필요한가)
- [darwin-rebuild: command not found (부트스트랩 전)](#darwin-rebuild-command-not-found-부트스트랩-전)
- [darwin-rebuild: command not found (설정 적용 후)](#darwin-rebuild-command-not-found-설정-적용-후)
- [/etc/bashrc, /etc/zshrc 충돌](#etcbashrc-etczshrc-충돌)
- [primary user does not exist](#primary-user-does-not-exist)
- [killall cfprefsd로 인한 스크롤 방향 롤백](#killall-cfprefsd로-인한-스크롤-방향-롤백)
- [nrs 실행 시 빌드 없이 즉시 종료됨](#nrs-실행-시-빌드-없이-즉시-종료됨)
- [darwin-rebuild 시 setupLaunchAgents에서 멈춤](#darwin-rebuild-시-setuplaunchagents에서-멈춤)
- [darwin-rebuild 후 Hammerspoon HOME이 /var/root로 인식](#darwin-rebuild-후-hammerspoon-home이-varroot로-인식)

---

## 왜 darwin-rebuild에 sudo가 필요한가?

`darwin-rebuild switch`는 **시스템 수준 설정**을 변경하기 때문에 root 권한이 필요합니다.

**sudo가 필요한 이유**:

| 변경 대상 | 예시 |
|----------|------|
| `/etc/` 파일 | `/etc/nix/nix.conf`, `/etc/bashrc`, `/etc/zshrc` |
| 시스템 심볼릭 링크 | `/run/current-system` |
| launchd 서비스 | 시스템 데몬 등록 |
| macOS 시스템 설정 | `system.defaults` (Dock, Finder 등) |

**실행 방법**:
```bash
# Private 저장소 사용 시 SSH_AUTH_SOCK 유지 필요
sudo --preserve-env=SSH_AUTH_SOCK darwin-rebuild switch --flake .
```

> **참고**: Home Manager만 단독으로 사용하면 (`home-manager switch`) sudo 없이 가능합니다. 하지만 nix-darwin과 통합된 구조에서는 `darwin-rebuild`가 시스템 + 사용자 설정을 모두 처리하므로 sudo가 필요합니다.

---

## darwin-rebuild: command not found (부트스트랩 전)

**에러 메시지**:
```
zsh: command not found: darwin-rebuild
```

**원인**: `darwin-rebuild` 명령어는 nix-darwin이 설치된 후에만 사용할 수 있습니다. 새 Mac에서 처음 설정할 때 이 에러가 발생합니다.

**해결**: 먼저 nix-darwin 부트스트랩을 완료해야 합니다:
```bash
nix --extra-experimental-features "nix-command flakes" run nix-darwin -- switch --flake .
```

부트스트랩 완료 후에는 `darwin-rebuild switch --flake .` 명령어를 사용할 수 있습니다.

---

## darwin-rebuild: command not found (설정 적용 후)

새 터미널에서 `darwin-rebuild` 명령어를 찾지 못하는 경우:

```bash
# 방법 1: 전체 경로로 실행
sudo /run/current-system/sw/bin/darwin-rebuild switch --flake .

# 방법 2: 쉘 재시작 후 다시 시도
exec $SHELL
darwin-rebuild switch --flake .
```

---

## /etc/bashrc, /etc/zshrc 충돌

**에러 메시지**:
```
error: Unexpected files in /etc, aborting activation
The following files have unrecognized content and would be overwritten:

  /etc/bashrc
  /etc/zshrc

Please check there is nothing critical in these files, rename them by adding .before-nix-darwin to the end, and then try again.
```

**원인**: nix-darwin이 `/etc/bashrc`와 `/etc/zshrc`를 관리하려고 하지만, 기존 시스템 파일이 있어서 충돌이 발생합니다.

**해결**: 기존 파일을 백업 후 다시 시도:

```bash
sudo mv /etc/bashrc /etc/bashrc.before-nix-darwin
sudo mv /etc/zshrc /etc/zshrc.before-nix-darwin
sudo --preserve-env=SSH_AUTH_SOCK nix run nix-darwin -- switch --flake .
```

> **참고**: 백업된 파일은 나중에 필요하면 복원할 수 있습니다.

---

## primary user does not exist

**에러 메시지**:
```
error: primary user `username` does not exist, aborting activation
Please ensure that `system.primaryUser` is set to the name of an existing user.
```

**원인**: `flake.nix`의 `username` 변수가 현재 macOS 사용자와 일치하지 않습니다.

**해결**:

1. 현재 사용자명 확인:
   ```bash
   whoami
   ```

2. `flake.nix`에서 `username` 수정:
   ```nix
   username = "your-actual-username";  # whoami 결과로 변경
   ```

3. 다시 빌드:
   ```bash
   sudo --preserve-env=SSH_AUTH_SOCK nix run nix-darwin -- switch --flake .
   ```

---

## killall cfprefsd로 인한 스크롤 방향 롤백

**증상**: `darwin-rebuild switch` 후 스크롤 방향이 "자연스러운 스크롤"로 변경됨 (설정은 비활성화했는데)

**원인**: activation script에서 `killall cfprefsd` 실행 시 발생하는 타이밍 문제

```
1. killall cfprefsd 실행
   ↓
2. CFPreferences 데몬 종료 → 모든 사용자 설정 캐시 플러시
   ↓
3. 시스템이 자동으로 cfprefsd 재시작
   ↓
4. 재시작된 cfprefsd가 plist에서 설정 다시 로드
   ↓
5. nix-darwin의 새 설정과 기존 설정 간 타이밍 충돌
   ↓
6. 일부 설정(스크롤 방향)이 기본값으로 롤백
```

**해결**: `activateSettings -u` 실행 후 스크롤 방향을 명시적으로 재설정

```nix
# X 문제가 되는 코드: activateSettings만 사용
system.activationScripts.postActivation.text = ''
  /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
'';

# X 더 심각한 문제: killall cfprefsd 사용
system.activationScripts.postActivation.text = ''
  killall cfprefsd 2>/dev/null || true  # 모든 설정 캐시 플러시 → 다양한 설정 롤백
'';

# O 권장: activateSettings 후 스크롤 방향 재설정
system.activationScripts.postActivation.text = ''
  # 키보드 단축키 등 설정 즉시 적용
  /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u

  # activateSettings가 스크롤 방향을 롤백시키므로 명시적으로 재설정
  defaults write -g com.apple.swipescrolldirection -bool false
'';
```

**핵심**:
- `activateSettings -u`: 키보드 단축키 등 설정을 즉시 반영 (재시작/로그아웃 불필요)
- 단, 스크롤 방향을 롤백시키는 부작용이 있음
- 해결: `activateSettings` 직후 `defaults write`로 스크롤 방향 재설정
- `killall cfprefsd`는 **절대 사용 금지** (더 심각한 문제 유발)

**임시 복구** (이미 발생한 경우):

```bash
# 스크롤 방향 다시 적용 (자연스러운 스크롤 비활성화)
defaults write -g com.apple.swipescrolldirection -bool false
/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
```

---

## nrs 실행 시 빌드 없이 즉시 종료됨

> **발생 시점**: 2026-01-15

**증상**: `nrs` 명령 실행 시 SSH 키 로딩과 launchd 에이전트 정리 메시지만 출력되고, `darwin-rebuild`가 실행되지 않고 즉시 종료됨.

```
❯ nrs

🔑 Loading SSH key...
Identity added: /Users/glen/.ssh/id_ed25519 (greenhead-home-mac-2025-10)
🧹 Cleaning up launchd agents...

❯   ← 빌드 없이 즉시 프롬프트 복귀
```

**원인**: `set -e`와 bash 산술 연산 `(( ))` 조합의 함정.

```bash
set -euo pipefail  # -e: 명령이 실패하면 즉시 종료

local cleaned=0
# ...
((cleaned++))  # ❌ cleaned=0일 때 exit code 1 반환 → 스크립트 종료
```

bash에서 `((expression))`의 exit code는 표현식의 **평가 결과**에 따라 결정됩니다:

| 표현식 | 평가 결과 | Exit code |
|--------|----------|-----------|
| `((0))` | false | 1 |
| `((1))` | true | 0 |
| `((var++))` (var=0) | 0 (증가 전 값) | 1 |
| `((++var))` (var=0) | 1 (증가 후 값) | 0 |

`((var++))`는 **후위 증가**로, 증가 전 값(0)을 반환합니다. `set -e` 환경에서 exit code 1은 스크립트를 즉시 종료시킵니다.

**진단 방법**:

```bash
# 디버그 모드로 실행하여 어디서 멈추는지 확인
bash -x ~/IdeaProjects/nixos-config/modules/darwin/scripts/nrs.sh

# 출력 예시 (문제 발생 시):
# + ((cleaned++))
# ← 여기서 스크립트 종료
```

**해결**: 전위 증가 `((++var))` 사용

```bash
# ❌ 문제: 후위 증가 (증가 전 값 반환)
((cleaned++))   # cleaned=0일 때 exit code 1

# ✅ 해결: 전위 증가 (증가 후 값 반환)
((++cleaned))   # cleaned=0일 때 exit code 0
```

**대안적 해결책들**:

| 방법 | 예시 | 설명 |
|------|------|------|
| 전위 증가 | `((++var))` | 증가 후 값 반환 (권장) |
| 명령 대체 | `var=$((var + 1))` | exit code 문제 없음 |
| `\|\| true` | `((var++)) \|\| true` | 실패 무시 |

---

## darwin-rebuild 시 setupLaunchAgents에서 멈춤

> **발생 시점**: 2026-01-14

**증상**: `sudo darwin-rebuild switch --flake .` 실행 시 `Activating setupLaunchAgents` 단계에서 무한 대기.

```
Activating setCursorAsDefaultEditor
Setting Cursor as default editor for code files...
Cursor default settings applied successfully.
Activating setupLaunchAgents
← 여기서 멈춤
```

**원인**: Home Manager의 `setupLaunchAgents`가 launchd 에이전트를 reload할 때 발생하는 문제입니다.

| 원인 | 설명 |
|------|------|
| **launchd 상태 충돌** | 이전 darwin-rebuild가 중단(Ctrl+C)된 후 에이전트가 불완전한 상태로 남음 |
| **sudo GUI 도메인 접근** | sudo로 실행 시 UID가 0이 되어 `gui/501` 도메인 접근에 문제 발생 |
| **타이밍 문제** | `launchctl bootout` 후 내부 상태 정리가 완료되기 전에 재시도 |

**Home Manager의 setupLaunchAgents 동작**:

```bash
# 각 에이전트에 대해 순차 실행
/bin/launchctl bootout "gui/$UID/$agentName"  # 에이전트 중지
sleep 1                                        # 1초 대기
/bin/launchctl bootstrap "gui/$UID" "$dstPath" # 에이전트 시작
```

**해결**:

```bash
# 1. 멈춘 darwin-rebuild를 Ctrl+C로 중단

# 2. 에이전트 수동 정리 (sudo 없이 실행!)
launchctl bootout gui/$(id -u)/com.green.atuin-watchdog 2>/dev/null
launchctl bootout gui/$(id -u)/com.green.folder-action.compress-rar 2>/dev/null
launchctl bootout gui/$(id -u)/com.green.folder-action.compress-video 2>/dev/null
launchctl bootout gui/$(id -u)/com.green.folder-action.convert-video-to-gif 2>/dev/null
launchctl bootout gui/$(id -u)/com.green.folder-action.rename-asset 2>/dev/null

# 3. plist 파일 삭제
rm -f ~/Library/LaunchAgents/com.green.*.plist

# 4. 2-3초 대기 후 재시도
sleep 3
sudo darwin-rebuild switch --flake ~/IdeaProjects/nixos-config
```

**예방**: `nrs` alias 사용 시 자동으로 에이전트를 정리합니다.

---

## darwin-rebuild 후 Hammerspoon HOME이 /var/root로 인식

> **발생 시점**: 2026-01-14

**증상**: darwin-rebuild 완료 후 Atuin menubar가 "오류 발생" 상태 표시. Hammerspoon이 watchdog 스크립트 실행 실패.

```lua
-- Hammerspoon 콘솔에서 확인
hs -c 'return hs.execute(os.getenv("HOME") .. "/.local/bin/atuin-watchdog.sh --status 2>&1")'
-- 결과: sh: /var/root/.local/bin/atuin-watchdog.sh: Permission denied
```

**원인**: `sudo darwin-rebuild` 실행 중 Hammerspoon이 IPC를 통해 reload되면 환경변수가 오염됩니다.

```
sudo darwin-rebuild switch
   ↓
activation script에서 hs -c "hs.reload()" 실행
   ↓
Hammerspoon이 sudo 환경에서 reload됨
   ↓
os.getenv("HOME") = "/var/root" (root의 HOME)
   ↓
watchdog 스크립트 경로가 /var/root/.local/bin/...로 잘못 해석됨
```

**해결**: Hammerspoon 완전 재시작

```bash
# 방법 1: 메뉴바에서 Quit 후 재실행
# Hammerspoon 아이콘 → Quit Hammerspoon → Spotlight에서 다시 실행

# 방법 2: 터미널에서
killall Hammerspoon && open -a Hammerspoon
```

**예방**: `nrs` alias 사용 시 darwin-rebuild 완료 후 자동으로 Hammerspoon을 재시작합니다.

```bash
# modules/darwin/scripts/nrs.sh (일부)
restart_hammerspoon() {
    if pgrep -x "Hammerspoon" > /dev/null; then
        killall Hammerspoon 2>/dev/null || true
        sleep 1
    fi
    open -a Hammerspoon
}
```

---

## launchd 에이전트 상태 확인

```bash
# 등록된 에이전트 확인
launchctl list | grep com.green

# 로그 확인
cat ~/Library/Logs/folder-actions/*.log
```
