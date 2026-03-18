---
name: managing-macos
description: |
  Configure macOS/nix-darwin: Dock, Finder, Homebrew Cask, Folder Actions.
  Trigger: 'darwin-rebuild', 'shottr 설정', 'Folder Actions', 'compress-video', 'upload-immich'.
---

# macOS 관리 (nix-darwin)

nix-darwin 및 macOS 시스템 설정 가이드입니다.

## 빠른 참조

### macOS 전용 nrs 옵션

```bash
nrs --force               # activation scripts 강제 재실행 (NO_CHANGES 스킵 우회)
```

> nrs/nrp 소스: `modules/shared/scripts/rebuild-common.sh`, `modules/darwin/scripts/{nrs,nrp}.sh`

### 주요 설정 파일

| 파일 | 용도 |
|------|------|
| `modules/darwin/configuration.nix` | macOS 시스템 설정 |
| `modules/darwin/home.nix` | Home Manager (macOS) |
| `modules/darwin/programs/` | macOS 전용 프로그램 |

### Nix CLI 패키지 (darwin-only)

`libraries/packages.nix`의 `darwinOnly` 리스트에서 관리:

```nix
# 패키지 추가
darwinOnly = [ ... pkgs.패키지명 ];
```

자세한 내용: [references/features.md](references/features.md#nix-cli-패키지-darwin-only)

### macOS 시스템 설정

| 설정 | 파일 | 설명 |
|------|------|------|
| Dock | `configuration.nix` | 자동 숨김, 크기, 최근 앱 |
| Finder | `configuration.nix` | 숨김 파일, 확장자, 네트워크 .DS_Store 방지 |
| 키보드 | `configuration.nix` | 키 반복 속도 |
| 트랙패드 | `configuration.nix` | 탭 클릭, 자연스러운 스크롤 |

### Homebrew 관리

`modules/darwin/programs/homebrew.nix`에서 선언적으로 관리됩니다 (personal 호스트만 적용).

```nix
# cleanup = "none" — 선언되지 않은 앱을 삭제하지 않음 (수동 설치 cask 보호)
# upgrade = true + greedyCasks = true — 자체 업데이터 앱의 버전 드리프트 방지
homebrew.casks = [
  "codex" "ghostty" "raycast" "rectangle"
  "hammerspoon" "homerow" "docker-desktop"
  "fork" "monitorcontrol"
];
homebrew.brews = [ "laishulu/homebrew/macism" "sox" ]; # Neovim 한영 전환, 오디오 처리
# shottr → Nix 패키지로 관리 (libraries/packages.nix darwinOnly)
# figma → Homebrew에서 제거 (자체 업데이터가 버전을 변경하여 adopt 시 버전 충돌)
# slack → Homebrew에서 제거 (수동 설치 선호, 자체 업데이터에 위임)
```

**새 Mac 세팅 시**: 직접 설치된 앱은 `brew install --cask --adopt <앱>`으로 Homebrew 관리로 전환 필요.

자세한 내용: [references/features.md](references/features.md#gui-앱-homebrew-casks)

### Shottr 선언 관리 (Nix + agenix)

Shottr 설정과 라이센스를 선언적으로 관리합니다.

| 파일 | 용도 |
|------|------|
| `modules/darwin/programs/shottr/default.nix` | Shottr 앱 고유 설정 + 라이센스 pre-fill |
| `modules/darwin/configuration.nix` | symbolic hotkeys (스크린샷 단축키) + activateSettings + Shottr 재시작 |
| `libraries/constants.nix` | Shottr 기본 저장경로 상대 경로 상수 |
| `secrets/shottr-license.age` | agenix 암호화 라이센스 키 (`KC_LICENSE` + `KC_VAULT`) |
| `modules/shared/programs/secrets/default.nix` | `~/.config/shottr/license` 배포 |

> **아키텍처 노트**: symbolic hotkeys와 Shottr 재시작은 `configuration.nix`의 postActivation에서 처리합니다.
> HM activation의 `activateSettings -u`가 `launchctl asuser + sudo` 컨텍스트에서 WindowServer와 통신하지 못하기 때문입니다.

운영 순서:

```bash
# 설정 적용 (라이센스 pre-fill 포함)
nrs
# 새 맥북: Shottr 실행 후 Activate 버튼 1회 클릭
```

크레덴셜 이중 저장 구조(Keychain + defaults), HM activation 주의사항, defaults 테스트 절차 상세: [references/shottr-credentials.md](references/shottr-credentials.md)

### Folder Actions (launchd WatchPaths)

`modules/darwin/programs/folder-actions/default.nix`에서 launchd WatchPaths 기반 폴더 감시 자동화를 관리합니다.

| 액션 | 감시 폴더 | 용도 |
|------|-----------|------|
| compress-rar | `~/FolderActions/compress-rar` | RAR 압축 |
| compress-video | `~/FolderActions/compress-video` | FFmpeg 비디오 압축 |
| rename-asset | `~/FolderActions/rename-asset` | 파일 이름 변경 |
| convert-video-to-gif | `~/FolderActions/convert-video-to-gif` | FFmpeg 비디오→GIF 변환 |
| upload-immich | Shottr 스크린샷 폴더 | Immich 자동 업로드 (personal 전용) |

로그: `~/Library/Logs/folder-actions/`

## 자주 발생하는 문제

1. **sudo 권한 필요**: darwin-rebuild는 시스템 파일 수정에 sudo 필요
2. **/etc/bashrc 충돌**: 기존 설정 파일과 nix-darwin 충돌
3. **스크롤 방향 롤백**: cfprefsd 재시작 시 설정 초기화

## 레퍼런스

- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
- 기능 목록: [references/features.md](references/features.md)
