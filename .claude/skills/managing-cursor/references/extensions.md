# Cursor 확장 관리

Nix로 Cursor 확장을 선언적으로 관리하는 가이드.

## 설치된 확장 목록

### Open-VSX (오픈소스)

| 확장 ID | 설명 |
|---------|------|
| dbaeumer.vscode-eslint | ESLint 통합 |
| esbenp.prettier-vscode | Prettier 코드 포맷터 |
| usernamehw.errorlens | 인라인 에러 표시 |
| streetsidesoftware.code-spell-checker | 맞춤법 검사 |
| aaron-bond.better-comments | 주석 하이라이팅 |
| eamodio.gitlens | Git 기록/blame |
| github.vscode-pull-request-github | GitHub PR 통합 |
| bbenoist.nix | Nix 언어 지원 |
| buenon.scratchpads | 스크래치패드 |
| kisstkondoros.vscode-gutter-preview | 이미지 미리보기 |
| k--kato.intellij-idea-keybindings | IntelliJ 키바인딩 |
| anthropic.claude-code | Claude Code |

### VS Code Marketplace

| 확장 ID | 설명 |
|---------|------|
| fuzionix.code-case-converter | 케이스 변환 |
| wix.vscode-import-cost | import 크기 표시 |
| imekachi.webstorm-darcula | Darcula 테마 |
| atommaterial.a-file-icon-vscode | 파일 아이콘 |

## 확장 추가/제거 방법

### 1. 설정 파일 수정

`modules/darwin/programs/cursor/default.nix`에서 `cursorExtensions` 수정:

```nix
cursorExtensions =
  (with pkgs.open-vsx; [
    # 여기에 open-vsx 확장 추가
    dbaeumer.vscode-eslint
  ])
  ++ (with pkgs.vscode-marketplace; [
    # 여기에 marketplace 확장 추가
    ms-vscode.vscode-typescript-next
  ]);
```

### 2. 빌드 적용

```bash
nrs
```

### 3. Cursor 재시작

확장이 적용되려면 Cursor 재시작 필요.

## 확장 소스 선택 기준

| 소스 | 용도 | 예시 |
|------|------|------|
| `open-vsx` | 오픈소스 확장 (대부분) | ESLint, Prettier, GitLens |
| `vscode-marketplace` | MS 전용/open-vsx에 없는 확장 | TypeScript, C# |

**선택 방법:**
1. 먼저 https://open-vsx.org 에서 검색
2. 없으면 https://marketplace.visualstudio.com 사용

## 확장 ID 찾는 방법

1. VSCode Marketplace 또는 Open-VSX에서 확장 검색
2. URL에서 ID 확인: `marketplace.visualstudio.com/items?itemName=<publisher>.<name>`
3. 예: `dbaeumer.vscode-eslint`

## 확장 버전 업데이트

이 프로젝트는 `nix-community/nix-vscode-extensions` flake를 통해 확장을 가져옵니다.
`nrs`는 `flake.lock`에 고정된 버전을 사용하므로, 확장 버전을 업데이트하려면 flake input을 업데이트해야 합니다.

### 방법 1: nix-vscode-extensions만 업데이트

```bash
# 확장 소스만 업데이트
nix flake update nix-vscode-extensions

# 빌드 및 적용
nrs
```

### 방법 2: 모든 flake inputs 업데이트

```bash
# nixpkgs, home-manager, nix-darwin 등 모두 업데이트
nix flake update

# 빌드 및 적용
nrs
```

### 현재 고정 버전

`flake.lock` 기준:
- **날짜**: 2026-01-18
- **rev**: `45f1a82aa6940da7134e6b48d5870f8dc7a554d9`

### 동작 원리

```
flake.lock (버전 고정)
    ↓
nix-vscode-extensions flake
    ↓
pkgs.open-vsx / pkgs.vscode-marketplace (overlay)
    ↓
modules/darwin/programs/cursor/default.nix
    ↓
~/.cursor/extensions/
```

### 권장 워크플로우

```bash
# 1. 업데이트 전 현재 확장 버전 확인 (선택)
ls -la ~/.cursor/extensions/

# 2. flake input 업데이트
nix flake update nix-vscode-extensions

# 3. 변경사항 확인
git diff flake.lock

# 4. 빌드 및 적용
nrs

# 5. Cursor 재시작 (확장 변경 감지 경고 → 정상)
```
