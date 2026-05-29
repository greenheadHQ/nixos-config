---
name: managing-mise
description: |
  Manage mise runtime: Node.js, pnpm, shims.
  Trigger: 'mise 설정', 'pnpm not found', '.nvmrc', 'mise shims', 'mise activate', '런타임 버전 불일치'.
---

# mise 런타임 버전 관리

mise를 사용한 Node.js, pnpm 등 런타임 버전 관리 가이드.

## 목적과 범위

런타임 버전 선택, shims 경로, SSH 비대화형 셸 이슈를 안정적으로 운영하는 절차를 다룬다.
macOS·NixOS 모두 `pkgs.mise`(nix, `libraries/packages.nix`의 shared)로 설치한다. 과거 macOS에서 Homebrew로 mise를 수동 설치했다면 PATH 경합을 피하기 위해 `brew uninstall mise`를 권장한다.

## 빠른 참조

### 플랫폼별 설치 구조

| 항목 | macOS | NixOS |
|------|-------|-------|
| mise 설치 | `libraries/packages.nix` (shared, nix) | `libraries/packages.nix` (shared, nix) |
| 소스 빌드 | 기본값 사용 | `MISE_ALL_COMPILE=0` 환경변수로 비활성화 |
| Node 빌드 | 기본값 사용 | `MISE_NODE_COMPILE=0` 환경변수로 비활성화 |
| 환경변수 위치 | - | `modules/shared/programs/shell/nixos.nix` |

### mise 설정 위치

| 파일 | 용도 |
|------|------|
| `~/.config/mise/config.toml` | 전역 설정 |
| `mise.toml` / `.mise.toml` | 프로젝트별 설정 |
| `mise.local.toml` | 프로젝트 로컬 (gitignore됨) |
| `.nvmrc`, `.node-version` | Node.js 버전 (idiomatic files) |

### 주요 명령어

```bash
# 현재 버전 확인
mise current

# 전역 버전 설정
mise use -g node@lts

# 프로젝트 버전 설치
mise install node@20.18

# 프로젝트 설정 신뢰
mise trust
```

### 관련 설정 파일

| 파일 | 용도 |
|------|------|
| `modules/shared/programs/shell/default.nix` | zsh mise 활성화 (shims + activate) |
| `modules/shared/programs/shell/nixos.nix` | NixOS 환경변수 (`MISE_ALL_COMPILE=0`, `MISE_NODE_COMPILE=0`) |
| `libraries/packages.nix` | `pkgs.mise` 패키지 설치 (shared — macOS+NixOS 공통) |

## 셸 활성화 구조

mise는 두 계층으로 활성화된다:

| 계층 | 파일 | 명령어 | 용도 |
|------|------|--------|------|
| `.zshenv` | `shell/default.nix` envExtra | `mise activate zsh --shims` | snapshot 미경유 비대화형(SSH `zsh -c` 등)에서 PATH에 shim 추가 |
| `.zshrc` | `shell/default.nix` initContent | `mise activate zsh` + shims prepend | 대화형 훅(cd-time 버전 전환) + Claude Code snapshot 경유 비대화형 보강 |

중복 활성화 방지 가드는 shims 경로의 PATH 실재 여부로 판단한다 (`[[ ":$PATH:" != *":$shims:"* ]]`). 과거 `MISE_SHELL` 기반 가드는 부모 대화형 셸의 `MISE_SHELL`이 자식 비대화형 셸로 상속되어 shims 활성화를 조기 스킵하는 회귀를 만들어 폐기됐다. `.zshrc`에서 추가로 shims를 prepend하는 이유는 Claude Code 같은 도구가 세션 시작 시 interactive 셸 PATH를 snapshot으로 박제하고 비대화형 호출마다 그 PATH를 복원하기 때문이다 — snapshot 캡처 시점에는 `_mise_hook`이 발동 전이라 hook 모드의 install-bins도 PATH에 없는 baseline이 박제되므로, shim 노출 도구(mise npm backend)는 명시적 prepend 없이는 비대화형에 노출되지 않는다.

## 핵심 절차

1. `mise current`로 현재 선택된 런타임을 확인한다.
2. 전역 버전이 필요하면 `mise use -g node@lts`로 고정한다.
3. 프로젝트별 버전은 `mise.toml` 또는 `.nvmrc` 기준으로 `mise install`을 실행한다.
4. `.nvmrc` 인식이 필요하면 `mise settings add idiomatic_version_file_enable_tools node`를 실행한다.
5. 비대화형 셸 문제는 `~/.zshenv`의 shims 경로와 `mise activate` 적용 여부를 점검한다.

## 자주 발생하는 문제

1. SSH 비대화형 세션에서 pnpm not found: `.zshenv`에 mise shims 누락 → 셸 활성화 구조 참조
2. .nvmrc 인식 안 됨: mise 2025.10.0부터 기본 비활성화 → `idiomatic_version_file_enable_tools` 설정 필요
3. NixOS에서 node 빌드 실패: `MISE_NODE_COMPILE=0` 필요 (현재 `nixos.nix`에서 영구 설정됨)
4. mise.local.toml 미신뢰: `mise trust` 실행 필요 (최초 1회)

## 레퍼런스

- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
