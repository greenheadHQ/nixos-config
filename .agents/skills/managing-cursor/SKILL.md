---
name: managing-cursor
description: |
  Cursor IDE: Nix extensions.json, settings, file associations.
  Triggers: "add Cursor extension", "install extension via Nix",
  "manage Cursor settings", "Extensions have been modified on disk",
  "확장 0개 표시", extension loading, duti file associations.
---

# Cursor 확장 관리

Cursor IDE 확장 프로그램 관리 가이드.

## Known Issues

**Spotlight에 Cursor 2개 표시**
- Homebrew Cask로 설치된 Cursor와 다른 경로의 Cursor가 공존
- 해결: `/Applications/Cursor.app` 외 다른 Cursor 삭제

**"Extensions have been modified on disk" 경고**
- Nix로 확장이 관리되어 외부 수정 감지됨
- 무시해도 됨, 재시작하면 사라짐

**GUI에서 확장 설치/제거 안 됨**
- extensions.json이 Nix로 관리되어 읽기 전용
- 해결: Nix 설정에서 추가/제거 후 `nrs`

## 빠른 참조

### 확장 관리 구조

```
~/.cursor/
├── extensions/           # 확장 파일 (Nix buildEnv)
│   └── extensions.json   # 확장 목록 (Nix에서 자동 생성)
└── (확장 메타데이터/캐시)

~/Library/Application Support/Cursor/User/
├── settings.json         # mkOutOfStoreSymlink (양방향 수정)
├── keybindings.json      # mkOutOfStoreSymlink (양방향 수정)
└── snippets/*.json       # Nix 관리 스니펫
```

**mkOutOfStoreSymlink 패턴**
- Nix store 대신 실제 파일 경로로 심볼릭 링크
- 양방향 수정 가능

**Shell wrapper**
- `modules/shared/programs/shell/darwin.nix`에서 `cursor()` 함수를 제공
- 인수 없이 `cursor` 실행 시 현재 디렉터리를 자동으로 여는 `cursor .` 래퍼를 사용

### 확장 추가하기

확장 추가/제거/업데이트는 [references/extensions.md](references/extensions.md) 참조.

## 자주 발생하는 문제

1. **확장 0개 표시**: extensions.json 심볼릭 링크 확인
2. **설치 안 됨**: Nix 설정에서 추가 필요
3. **Spotlight 중복**: 불필요한 Cursor 앱 삭제

## 레퍼런스

- 확장 관리: [references/extensions.md](references/extensions.md)
- Cursor 설정: [references/settings.md](references/settings.md)
- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
