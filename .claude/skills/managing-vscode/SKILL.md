---
name: managing-vscode
description: |
  This skill should be used when the user asks about VSCode management
  including Nix extensions, settings, file associations, and snippets.
  Triggers: "add VSCode extension", "install extension via Nix",
  "manage VSCode settings", "확장 로드 오류", "VSCode 확장",
  extension loading, duti file associations,
  "keybindings.json", "VSCode 설정", "VSCode 스니펫",
  "nix-ide", "nixd LSP".
---

# VSCode 관리

VSCode 에디터의 확장, 설정, 파일 연결을 Nix(Home Manager `programs.vscode` 모듈)로 선언적 관리하는 가이드.

## 목적과 범위

VSCode 앱과 확장은 HM `programs.vscode` 모듈로 설치하고, settings/keybindings는 mkOutOfStoreSymlink으로 양방향 관리한다.
GUI에서의 확장 설치/제거는 불가능하며(`mutableExtensionsDir = false`), 모든 변경은 Nix 설정을 통해야 한다.

## 빠른 참조

### 파일 구조

```
modules/darwin/programs/vscode/
├── default.nix                 # 확장 목록, HM 모듈, duti 설정
└── files/
    ├── settings.json           # → ~/Library/.../Code/User/settings.json
    └── keybindings.json        # → ~/Library/.../Code/User/keybindings.json

~/Applications/Home Manager Apps/
└── Visual Studio Code.app      # HM이 자동 설치

~/Library/Application Support/Code/User/
├── settings.json               # mkOutOfStoreSymlink (양방향 수정)
├── keybindings.json            # mkOutOfStoreSymlink (양방향 수정)
└── snippets/*.json             # HM languageSnippets가 자동 생성
```

### 확장 추가/제거 절차

1. `modules/darwin/programs/vscode/default.nix`에서 `profiles.default.extensions` 수정
2. `nrs` 실행
3. VSCode 재시작

확장 소스 선택: 먼저 `open-vsx`에서 검색, 없으면 `vscode-marketplace` 사용.
상세 가이드: [references/extensions.md](references/extensions.md)

### Nix LSP (nixd)

VSCode에서 `.nix` 파일 편집 시 nixd LSP가 자동완성/포맷팅을 제공합니다.
nixd와 nixfmt는 VSCode 모듈의 `home.packages`에 co-locate되어 macOS에서만 설치됩니다.

## 자주 발생하는 문제

1. **확장 로드 오류**: `nrs` 후 VSCode 재시작 필요
2. **GUI에서 확장 설치 안 됨**: `mutableExtensionsDir = false` → Nix 설정에서 추가 후 `nrs`
3. **settings.json 충돌**: `profiles.default.userSettings` 사용 금지 — mkOutOfStoreSymlink과 충돌

## 기본 앱 연결 (duti)

텍스트/코드 파일 더블클릭 시 VSCode로 열리도록 `duti`를 사용한다.
`home.activation`에서 `nrs` 시 자동 적용. 상세: [references/settings.md](references/settings.md)

## 레퍼런스

- 확장 관리: [references/extensions.md](references/extensions.md)
- VSCode 설정/duti: [references/settings.md](references/settings.md)
- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
