# macOS 시스템 설정

macOS 관련 시스템 설정 및 Homebrew 관리입니다.

## 목차

- [원격 접속 (SSH/mosh)](#원격-접속-sshmosh)
  - [SSH 세션 로케일 설정](#ssh-세션-로케일-설정)
- [Shell Alias](#shell-alias)
- [보안](#보안)
- [Dock](#dock)
- [Finder](#finder)
- [키보드](#키보드)
- [마우스/트랙패드](#마우스트랙패드)
- [자동 수정 비활성화](#자동-수정-비활성화)
- [키보드 단축키 (Symbolic Hotkeys)](#키보드-단축키-symbolic-hotkeys)
- [키 바인딩 (백틱/원화)](#키-바인딩-백틱원화)
- [폰트 관리](#폰트-관리)
- [GUI 앱 (Homebrew Casks)](#gui-앱-homebrew-casks)
- [폴더 액션 (launchd)](#폴더-액션-launchd)

---

`modules/darwin/configuration.nix`에서 관리됩니다.

## 원격 접속 (SSH/mosh)

`modules/darwin/programs/sshd/`와 `modules/darwin/programs/mosh/`에서 관리됩니다.

Termius 등 외부 기기에서 맥북에 SSH/mosh로 원격 접속할 수 있도록 설정합니다.

**구성 요소:**

| 모듈 | 파일 | 설명 |
|------|------|------|
| SSH 서버 보안 | `programs/sshd/default.nix` | 공개키 인증만 허용, 비밀번호 비활성화 |
| mosh | `programs/mosh/default.nix` | mosh-server 설치 (불안정한 네트워크 대응) |
| authorized_keys | `configuration.nix` | SSH 접속 허용 키 등록 |

**SSH 서버 보안 설정:**

```nix
environment.etc."ssh/sshd_config.d/200-security.conf".text = ''
  PubkeyAuthentication yes
  PasswordAuthentication no
  KbdInteractiveAuthentication no
  PermitRootLogin no
  PermitEmptyPasswords no
  X11Forwarding no
  ClientAliveInterval 60
  ClientAliveCountMax 3
'';
```

**사전 준비 (1회):**

macOS 원격 로그인은 nix-darwin으로 활성화할 수 없으므로 수동 설정이 필요합니다:

```bash
# 방법 1: 명령어
sudo launchctl load -w /System/Library/LaunchDaemons/ssh.plist

# 방법 2: 시스템 설정
# 시스템 설정 → 일반 → 공유 → 원격 로그인 → 켜기
```

**허용된 SSH 키:**

| 키 | 용도 |
|---|---|
| `greenhead-home-mac-2025-10` | Termius 등 외부 기기 접속 |
| `greenhead@minipc` | MiniPC에서 접속 |

**Termius 연결 정보:**

| 항목 | 값 |
|------|-----|
| Host | Tailscale IP (예: `100.65.50.98`) |
| Port | `22` |
| Username | `green` |
| Auth | SSH Key (Ed25519) |

**mosh 사용:**

```bash
# Termius에서 mosh 연결 시 자동으로 mosh-server 사용
# 또는 CLI에서:
mosh green@100.65.50.98
```

> **참고**: macOS의 launchd가 SSH 소켓을 직접 관리하므로 `sshd_config`의 `ListenAddress` 설정은 적용되지 않습니다. LAN 접근 제한이 필요한 경우 pf 방화벽을 사용해야 합니다.

### SSH 세션 로케일 설정

`modules/shared/programs/shell/darwin.nix`에서 관리됩니다.

SSH로 맥북에 접속할 때 로케일이 `C`로 폴백되는 문제를 방지합니다.

**문제 원인:**

| 시스템 | 로케일 설정 방식 | SSH 세션 적용 |
|--------|------------------|---------------|
| NixOS | `/etc/locale.conf` (시스템 전역) | 자동 적용 |
| macOS | GUI 앱이 시스템 설정 상속 | 별도 설정 필요 |

macOS는 NixOS의 `/etc/locale.conf`처럼 시스템 전역 로케일 파일이 없습니다. 터미널 앱(Terminal.app, Ghostty 등)은 시스템 설정을 읽어서 `LANG`을 설정하지만, SSH 세션은 이 혜택을 받지 못합니다.

**해결:**

`home.sessionVariables`에 `LANG` 환경변수를 명시적으로 설정합니다. Home Manager가 `~/.zshenv`에서 로드하는 `hm-session-vars.sh`에 `export LANG=...`를 추가하므로, 모든 zsh 세션(로컬, SSH 포함)에서 로케일이 설정됩니다.

```nix
# modules/shared/programs/shell/darwin.nix
home.sessionVariables = {
  LANG = "en_US.UTF-8";
};
```

**검증:**

```bash
# SSH 접속 후
locale          # LANG=en_US.UTF-8 확인
locale charmap  # UTF-8 확인
```

## Shell Alias

`modules/shared/programs/shell/darwin.nix`에서 관리됩니다.

| Alias | 명령어 | 설명 |
|------|--------|------|
| `nrs` | `~/.local/bin/nrs.sh` | rebuild (미리보기 + 적용) |
| `nrs-offline` | `~/.local/bin/nrs.sh --offline` | 오프라인 rebuild |
| `nrp` | `~/.local/bin/nrp.sh` | 미리보기 전용 |
| `nrp-offline` | `~/.local/bin/nrp.sh --offline` | 오프라인 미리보기 |
| `nrh` | `~/.local/bin/nrh.sh` | 최근 10개 세대 |
| `nrh-all` | `~/.local/bin/nrh.sh --all` | 전체 세대 |

**Rebuild 스크립트 아키텍처:**

nrs/nrp 스크립트는 공통 함수를 `~/.local/lib/rebuild-common.sh`에서 source합니다.
각 스크립트는 `REBUILD_CMD` 변수를 설정한 후 공통 라이브러리를 로드합니다.

| 파일 | 역할 |
|------|------|
| `modules/shared/scripts/rebuild-common.sh` | 공통 라이브러리 (로깅, 인수 파싱, worktree 감지, 빌드 미리보기, 아티팩트 정리) |
| `modules/darwin/scripts/nrs.sh` | darwin switch (launchd 정리, Hammerspoon 재시작) |
| `modules/darwin/scripts/nrp.sh` | darwin 미리보기 전용 |

**Worktree 감지 (`detect_worktree()`):**

git worktree에서 nrs/nrp 실행 시 `git rev-parse --show-toplevel` + `--git-common-dir`로 worktree를 감지합니다. 감지 시 `FLAKE_PATH`만 worktree 경로로 오버라이드하여 빌드를 해당 worktree flake로 수행합니다. 심링크 타깃(`nixosConfigPath`)은 항상 메인 레포 경로를 유지합니다.

Staleness 방지: `rebuild-common.sh`의 `@flakePath@`는 `nixosConfigDefaultPath`(항상 메인 레포)를 사용하여, worktree 빌드 후에도 다음 `nrs` 실행 시 올바른 기본 경로에서 시작합니다.

## 보안

- **Touch ID sudo 인증**: 터미널에서 sudo 실행 시 Touch ID 사용

## Dock

- 자동 숨김 활성화
- 최근 앱 숨김
- 아이콘 크기 36px
- Spaces 자동 재정렬 비활성화
- 최소화 효과: Suck

## Finder

- 숨김 파일 표시
- 모든 확장자 표시
- **네트워크 볼륨 `.DS_Store` 생성 방지**: `DSDontWriteNetworkStores = true`
  - NAS/SMB/WebDAV 등 네트워크 볼륨에만 적용 (로컬 디스크 무관)
  - 네트워크 폴더별 Finder 보기 설정(아이콘 크기, 정렬)이 저장되지 않는 트레이드오프 있음

## 키보드

- **KeyRepeat = 1**: 최고 속도 키 반복
- **InitialKeyRepeat = 15**: 빠른 초기 반복

## 마우스/트랙패드

- **자연스러운 스크롤 비활성화**: `com.apple.swipescrolldirection = false`

## 자동 수정 비활성화

- 자동 대문자화
- 맞춤법 자동 수정
- 마침표 자동 삽입
- 따옴표 자동 변환
- 대시 자동 변환

## 키보드 단축키 (Symbolic Hotkeys)

`modules/darwin/configuration.nix`의 `CustomUserPreferences."com.apple.symbolichotkeys"`에서 관리됩니다.

macOS 시스템 키보드 단축키를 nix-darwin으로 선언적으로 관리합니다. `darwin-rebuild switch` 시 `activateSettings -u`로 즉시 적용됩니다.

**스크린샷 설정:**

| ID  | 단축키 | 기능                  | 상태     |
| --- | ------ | --------------------- | -------- |
| 28  | ⇧⌘3    | 화면 → 파일           | 비활성화 |
| 29  | ⌃⇧⌘3   | 화면 → 클립보드       | 활성화   |
| 30  | ⇧⌘4    | 선택 영역 → 파일      | 비활성화 |
| 31  | ⇧⌘4    | 선택 영역 → 클립보드  | 활성화   |
| 32  | ⇧⌘5    | 스크린샷 및 기록 옵션 | 활성화   |

**입력 소스 설정:**

| ID  | 단축키 | 기능           | 상태     |
| --- | ------ | -------------- | -------- |
| 60  | ⌃Space | 이전 입력 소스 | 비활성화 |
| 61  | F18    | 다음 입력 소스 | 활성화   |

> **참고**: Hammerspoon에서 Caps Lock → F18 리매핑을 담당합니다.

**Spotlight 설정:**

| ID  | 단축키  | 기능               | 상태                    |
| --- | ------- | ------------------ | ----------------------- |
| 64  | ⌘Space  | Spotlight 검색     | 비활성화 (Raycast 사용) |
| 65  | ⌥⌘Space | Finder 검색 윈도우 | 활성화                  |

**Mission Control 설정:**

| ID  | 단축키 | 기능            | 상태   |
| --- | ------ | --------------- | ------ |
| 32  | F3     | Mission Control | 활성화 |

**기능 키 설정:**

- `com.apple.keyboard.fnState = true`: F1-F12 키를 표준 기능 키로 사용 (밝기/볼륨 조절 대신)

**Modifier 비트마스크 참조:**

| Modifier | 값                 |
| -------- | ------------------ |
| Shift    | 131072 (0x20000)   |
| Control  | 262144 (0x40000)   |
| Option   | 524288 (0x80000)   |
| Command  | 1048576 (0x100000) |
| Fn       | 8388608 (0x800000) |

**설정 확인:**

```bash
defaults read com.apple.symbolichotkeys AppleSymbolicHotKeys | grep -A 5 '"61"'
```

**즉시 적용**:

`darwin-rebuild switch` 시 `activateSettings -u`를 실행하여 키보드 단축키가 즉시 반영됩니다. 재시작/로그아웃 불필요.

> **참고**: `activateSettings -u`는 `마우스` > `자연스러운 스크롤` 옵션을 **활성화**시키는 부작용이 있어, 직후에 `defaults write`로 재설정합니다.

## 키 바인딩 (백틱/원화)

`modules/darwin/programs/keybindings/`에서 관리됩니다.

한국어 키보드에서 백틱(`) 키 입력 시 원화(₩)가 입력되는 문제를 해결합니다. macOS Cocoa Text System의 `DefaultKeyBinding.dict`를 사용합니다.

| 입력         | 출력    | 설명                       |
| ------------ | ------- | -------------------------- |
| `₩` 키       | `` ` `` | 백틱 입력 (기본 동작 변경) |
| `Option + 4` | `₩`     | 원화 기호 입력 (필요시)    |

**설정 파일 위치:** `~/Library/KeyBindings/DefaultKeyBinding.dict`

**참고:**

- 적용 후 앱 재시작 필요 (일부 앱은 로그아웃/재로그인 필요)
- 참고 자료: [ttscoff/KeyBindings](https://github.com/ttscoff/KeyBindings)

## 폰트 관리

`modules/darwin/configuration.nix`에서 관리됩니다.

nix-darwin의 `fonts.packages` 옵션을 사용하여 폰트를 선언적으로 관리합니다. 폰트는 `/Library/Fonts/Nix Fonts/`에 자동 설치됩니다.

**현재 설치된 폰트:**

| 폰트                       | 패키지                                              | 역할     | 용도                                      |
| -------------------------- | --------------------------------------------------- | -------- | ----------------------------------------- |
| Sarasa Mono K Nerd Font    | 커스텀 derivation (`libraries/packages/sarasa-mono-k-nerd-font.nix`) | 주 폰트  | CJK 2:1 정확한 너비 + Nerd Font 글리프    |
| JetBrains Mono Nerd Font   | `nerd-fonts.jetbrains-mono`                         | fallback | Sarasa에 없는 글리프 대비                 |

**폰트 사용처:**

| 앱       | 설정 파일                                          | 폰트 이름                   |
| -------- | -------------------------------------------------- | --------------------------- |
| Ghostty  | `modules/darwin/programs/ghostty/default.nix`      | Sarasa Mono K Nerd Font (주) + JetBrainsMono Nerd Font (fallback) |
| Cursor   | `modules/darwin/programs/cursor/files/settings.json`| Sarasa Mono K Nerd Font (주) + JetBrainsMono Nerd Font (fallback) |

> Sarasa Gothic은 Iosevka(라틴 모노스페이스) + Source Han Sans(CJK)를 합성한 폰트입니다. CJK 문자가 ASCII의 정확히 2배 너비여서 한글+영문 코드 블록이 완벽히 정렬됩니다. jonz94/Sarasa-Gothic-Nerd-Fonts에서 Nerd Font 글리프가 패치된 버전을 사용합니다.

**설치 경로:** `/Library/Fonts/Nix Fonts/`

**확인 방법:**

```bash
# 설치된 폰트 확인
ls "/Library/Fonts/Nix Fonts/"

# 폰트 목록에서 확인
fc-list | grep -i "Sarasa\|JetBrains"
```

## GUI 앱 (Homebrew Casks)

`modules/darwin/programs/homebrew.nix`에서 관리됩니다.

### 서드파티 Tap Formula 주의사항

서드파티 tap의 formula는 **전체 경로**로 지정해야 자동 설치됩니다:

```nix
taps = [ "laishulu/homebrew" ];
brews = [ "laishulu/homebrew/macism" ];  # ✅ 전체 경로
# brews = [ "macism" ];  # ❌ homebrew/core에서 찾으려고 함 → 설치 안 됨
```

### Cask 목록

| 앱             | 용도                       |
| -------------- | -------------------------- |
| Cursor         | AI 코드 에디터             |
| Ghostty        | 터미널                     |
| Raycast        | 런처 (Spotlight 대체)      |
| Rectangle      | 창 관리                    |
| Hammerspoon    | 키보드 리매핑/자동화       |
| Homerow        | 키보드 네비게이션          |
| Docker         | 컨테이너                   |
| Fork           | Git GUI                    |
| Slack          | 메신저                     |
| Figma          | 디자인                     |
| MonitorControl | 외부 모니터 밝기 조절      |

## 폴더 액션 (launchd)

`modules/darwin/programs/folder-actions/`에서 관리됩니다.

macOS launchd의 WatchPaths를 사용하여 특정 폴더를 감시하고, 파일이 추가되면 자동으로 스크립트를 실행합니다.

| 감시 폴더                               | 기능                                  |
| --------------------------------------- | ------------------------------------- |
| `~/FolderActions/compress-rar/`         | RAR 압축 + SHA-256 체크섬 가이드 생성 |
| `~/FolderActions/compress-video/`       | H.265 (HEVC) 비디오 압축              |
| `~/FolderActions/rename-asset/`         | 타임스탬프 기반 파일명 변경           |
| `~/FolderActions/convert-video-to-gif/` | GIF 변환 (15fps, 480px)               |
| `~/FolderActions/upload-immich/`        | Immich 자동 업로드 + Pushover 알림    |

### 사용 방법

1. 감시 폴더에 파일을 드래그 앤 드롭
2. 자동으로 스크립트가 실행됨
3. 결과물은 `~/Downloads/`에 저장됨

### 로그 확인

```bash
cat ~/Library/Logs/folder-actions/*.log
```

## Nix CLI 패키지 (darwin-only)

`libraries/packages.nix`의 `darwinOnly` 리스트에서 관리됩니다.

Homebrew가 GUI 앱(Cask)을 담당하는 반면, CLI 도구는 Nix로 선언적 관리합니다.

| 패키지 | 용도 |
|--------|------|
| `broot` | 파일 탐색기 TUI |
| `ffmpeg` | 미디어 처리 |
| `imagemagick` | 이미지 처리 |
| `rar` | 압축 |
| `ttyper` | 타이핑 연습 CLI |
| `unzip` | 압축 해제 |

**추가 방법:**

```nix
# libraries/packages.nix
darwinOnly = [
  ...
  pkgs.새패키지
];
```

`nrs`로 적용. 새 패키지 추가 시 `nrs-offline`은 사용 불가 (다운로드 필요).
