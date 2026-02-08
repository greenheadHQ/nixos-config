---
name: managing-macos
description: |
  This skill should be used when the user runs "darwin-rebuild", asks about
  Dock/Finder settings, Touch ID sudo, Homebrew Cask,
  or encounters "/etc/bashrc conflict", "/etc/zshrc conflict",
  "killall cfprefsd", "primary user does not exist" errors.
---

# macOS 관리 (nix-darwin)

nix-darwin 및 macOS 시스템 설정 가이드입니다.

## 빠른 참조

### Rebuild 명령어

```bash
# 설정 적용 (미리보기 + 적용)
nrs

# 오프라인 rebuild (캐시만 사용, 빠름)
nrs --offline

# 미리보기만
nrp
```

**nrs 안전 기능:**
- launchd 에이전트 정리 (setupLaunchAgents 멈춤 방지)
- Hammerspoon 재시작 (HOME 오염 방지)

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

```bash
# Cask 앱은 Homebrew로 설치
# modules/darwin/programs/homebrew.nix에서 관리

homebrew.casks = [
  "cursor"
  "ghostty"
  "raycast"
];
```

## 자주 발생하는 문제

1. **sudo 권한 필요**: darwin-rebuild는 시스템 파일 수정에 sudo 필요
2. **/etc/bashrc 충돌**: 기존 설정 파일과 nix-darwin 충돌
3. **스크롤 방향 롤백**: cfprefsd 재시작 시 설정 초기화

## 레퍼런스

- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
- 기능 목록: [references/features.md](references/features.md)
