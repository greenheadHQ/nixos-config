---
name: managing-cursor
description: |
  This skill should be used when the user asks about Cursor IDE management
  including Nix extensions.json, settings, file associations, and snippets.
  Triggers: "add Cursor extension", "install extension via Nix",
  "manage Cursor settings", "Extensions have been modified on disk",
  "확장 0개 표시", "Cursor 확장", extension loading, duti file associations,
  "keybindings.json", "Cursor 설정", "Cursor 스니펫".
---

# Cursor IDE 관리

Cursor AI 코드 에디터의 확장, 설정, 파일 연결을 Nix로 선언적 관리하는 가이드.

## 목적과 범위

Cursor 앱은 Homebrew Cask로 설치하고, 확장/설정/키바인딩/스니펫은 Nix(Home Manager)로 관리한다.
GUI에서의 확장 설치/제거는 불가능하며, 모든 변경은 Nix 설정을 통해야 한다.

## 빠른 참조

### 파일 구조

```
modules/darwin/programs/cursor/
├── default.nix                 # 확장 목록, 심볼릭 링크, duti 설정
└── files/
    ├── settings.json           # → ~/Library/.../User/settings.json
    ├── keybindings.json        # → ~/Library/.../User/keybindings.json
    └── snippets/*.json         # → ~/Library/.../User/snippets/

~/.cursor/
├── extensions/                 # Nix buildEnv (읽기 전용)
│   └── extensions.json         # Nix 자동 생성
└── (메타데이터/캐시)

~/Library/Application Support/Cursor/User/
├── settings.json               # mkOutOfStoreSymlink (양방향 수정)
├── keybindings.json            # mkOutOfStoreSymlink (양방향 수정)
└── snippets/*.json             # Nix 관리
```

### 확장 추가/제거 절차

1. `modules/darwin/programs/cursor/default.nix`에서 `cursorExtensions` 수정
2. `nrs` 실행
3. Cursor 재시작

확장 소스 선택: 먼저 `open-vsx`에서 검색, 없으면 `vscode-marketplace` 사용.
상세 가이드: [references/extensions.md](references/extensions.md)

### Shell wrapper

`modules/shared/programs/shell/darwin.nix`에서 `cursor()` 함수 제공.
인수 없이 `cursor` 실행 시 현재 디렉터리를 자동으로 여는 `cursor .` 래퍼.

## 자주 발생하는 문제

1. **확장 0개 표시**: `extensions.json`에 `location`/`metadata` 필드 누락 → `default.nix` 형식 확인
2. **"Extensions have been modified on disk" 경고**: 정상 동작, Cursor 재시작으로 해결
3. **GUI에서 확장 설치 안 됨**: `~/.cursor/extensions`가 Nix store 심볼릭 링크 → Nix 설정에서 추가 후 `nrs`
4. **Spotlight에 Cursor 2개 표시**: `/Applications/Cursor.app` 외 다른 Cursor 삭제

## 기본 앱 연결 (duti)

텍스트/코드 파일 더블클릭 시 Cursor로 열리도록 `duti`를 사용한다.
`home.activation`에서 `nrs` 시 자동 적용. 상세: [references/settings.md](references/settings.md)

## 레퍼런스

- 확장 관리: [references/extensions.md](references/extensions.md)
- Cursor 설정/duti: [references/settings.md](references/settings.md)
- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
