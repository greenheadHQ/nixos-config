# VSCode 확장 관리

Nix(Home Manager `programs.vscode` 모듈)로 VSCode 확장을 선언적으로 관리하는 가이드.

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
| jnoortheen.nix-ide | Nix 언어 지원 (nixd LSP) |
| buenon.scratchpads | 스크래치패드 |
| kisstkondoros.vscode-gutter-preview | 이미지 미리보기 |
| k--kato.intellij-idea-keybindings | IntelliJ 키바인딩 |
| hashicorp.terraform | Terraform |
| anthropic.claude-code | Claude Code |

### VS Code Marketplace

| 확장 ID | 설명 |
|---------|------|
| fuzionix.code-case-converter | 케이스 변환 |
| wix.vscode-import-cost | import 크기 표시 |
| imekachi.webstorm-darcula | Darcula 테마 |
| atommaterial.a-file-icon-vscode | 파일 아이콘 |
| mermaidchart.vscode-mermaid-chart | Mermaid 다이어그램 미리보기 |

### Custom Pinned Source

| 확장 ID | 소스 | 설명 |
|---------|------|------|
| bwya77.islands-dark | `vscode-dark-islands` flake input | Marketplace/Open-VSX 대신 GitHub source를 고정하여 repo-local derivation으로 빌드 |

## 확장 추가/제거 방법

### 1. 설정 파일 수정

`modules/darwin/programs/vscode/default.nix`에서 `profiles.default.extensions` 수정:

```nix
profiles.default = {
  extensions =
    (with pkgs.open-vsx; [
      # 여기에 open-vsx 확장 추가
      dbaeumer.vscode-eslint
    ])
    ++ [
      # 여기에 custom pinned source 확장 추가
      islandsDark.extension
    ]
    ++ (with pkgs.vscode-marketplace; [
      # 여기에 marketplace 확장 추가
      ms-vscode.vscode-typescript-next
    ]);
};
```

### 2. 빌드 적용

```bash
nrs
```

### 3. VSCode 재시작

확장이 적용되려면 VSCode 재시작 필요.

## 확장 소스 선택 기준

| 소스 | 용도 | 예시 |
|------|------|------|
| `open-vsx` | 오픈소스 확장 (대부분) | ESLint, Prettier, GitLens |
| `vscode-marketplace` | MS 전용/open-vsx에 없는 확장 | TypeScript, C# |
| custom pinned source | Marketplace/Open-VSX 외부 GitHub 소스 고정 | Islands Dark |

**선택 방법:**
1. 먼저 https://open-vsx.org 에서 검색
2. 없으면 https://marketplace.visualstudio.com 사용
3. Marketplace/Open-VSX에 없거나 upstream source/font/CSS contract까지 함께 고정해야 하면 custom pinned source 사용

## 확장 ID 찾는 방법

1. VSCode Marketplace 또는 Open-VSX에서 확장 검색
2. URL에서 ID 확인: `marketplace.visualstudio.com/items?itemName=<publisher>.<name>`
3. 예: `dbaeumer.vscode-eslint`

## 확장 버전 업데이트

이 프로젝트는 `nix-community/nix-vscode-extensions` flake를 통해 확장을 가져옵니다.
`nrs`는 `flake.lock`에 고정된 버전을 사용하므로, 확장 버전을 업데이트하려면 flake input을 업데이트해야 합니다.

### 단일 input 업데이트

```bash
# 확장 소스만 업데이트 (다른 input에 영향 없음)
nix flake update nix-vscode-extensions

# 빌드 및 적용
nrs
```

전체 `nix flake update`는 nixpkgs/home-manager 등 무관한 input까지 함께 갱신하므로 IDE 작업 PR에서는 사용하지 않는다.
`nix flake lock --update-input <name>`은 deprecated이므로 `nix flake update <name>`만 사용한다.

### 동작 원리

```
flake.lock (버전 고정)
    ↓
nix-vscode-extensions flake
    ↓
pkgs.open-vsx / pkgs.vscode-marketplace (overlay)
    ↓
modules/darwin/programs/vscode/default.nix
    ↓
HM programs.vscode 모듈이 확장 디렉토리 자동 관리
```

### Custom pinned source 업데이트

`bwya77.islands-dark`는 `nix-vscode-extensions`가 아니라 별도 `vscode-dark-islands` flake input으로 고정한다.
이 테마만 업데이트할 때는 일반 확장 input과 분리해서 갱신한다.

```bash
# Islands Dark 소스만 업데이트
nix flake update vscode-dark-islands

# 빌드 및 적용
nrs
```

이 테마의 upstream glass/floating UI CSS는 `modules/darwin/programs/vscode/islands-dark.nix`에서 contract guard로 검증만 한다. VSCode.app 내부 CSS를 빌드 시 직접 수정하면 macOS code-signing sealed resource 검증이 깨지므로, 현재 Home Manager 구성은 notarized `pkgs.vscode` bundle을 그대로 사용하고 color theme extension과 Bear Sans UI font만 선언적으로 설치한다. 런타임에 VSCode 설치 파일을 수정하는 Custom UI Style extension 경로도 Nix store read-only 모델과 맞지 않으므로 사용하지 않는다.

### Custom pinned source 제거/교체 체크리스트

Custom pinned source는 단순히 `profiles.default.extensions` 항목만 제거하면 불완전하다.
Islands Dark를 제거하거나 다른 custom source로 교체할 때는 아래 결합 지점을 함께 정리한다.

- `flake.nix` / `flake.lock`: `vscode-dark-islands` input 제거 또는 교체
- `modules/darwin/programs/vscode/default.nix`: `islandsDark.extension` 연결 제거 또는 교체
- `modules/darwin/programs/vscode/islands-dark.nix`: helper 삭제 또는 새 source 전용 helper로 교체
- `modules/darwin/configuration.nix`: `islandsDark.fonts.bearSansUi` font 등록 제거 또는 교체
- `modules/darwin/programs/vscode/files/settings.json`: `workbench.colorTheme`를 설치된 테마로 되돌림
- 검증: `nix flake check`, 양쪽 Darwin system dry-run, VSCode extension build에서 CSS contract guard 확인, `codesign`/`spctl`로 VSCode.app 서명 유지 확인

### 권장 워크플로우

```bash
# 1. flake input 업데이트
nix flake update nix-vscode-extensions

# 2. 변경사항 확인
git diff flake.lock

# 3. 빌드 및 적용
nrs

# 4. VSCode 재시작
```
