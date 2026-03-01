---
name: managing-mise
description: |
  This skill should be used when the user asks about mise runtime version management
  including Node.js, pnpm, shims, .nvmrc, and activate configuration.
  Triggers: "pnpm not found", "node version mismatch", ".nvmrc",
  "mise shims", "mise activate", "mise 설정", "SSH에서 pnpm 안 됨",
  "Node.js source build", "런타임 버전 불일치".
---

# mise 런타임 버전 관리

mise를 사용한 Node.js, pnpm 등 런타임 버전 관리 가이드입니다.

## 목적과 범위

런타임 버전 선택, shims 경로, SSH 비대화형 셸 이슈를 안정적으로 운영하는 절차를 다룬다.

## 빠른 참조

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

# NixOS에서 node 설치 (바이너리)
MISE_NODE_COMPILE=0 mise use -g node@lts
```

### 관련 설정 파일

| 파일 | 용도 |
|------|------|
| `modules/shared/programs/shell/default.nix` | zsh mise 활성화 |
| `libraries/packages.nix` | `pkgs.mise` 패키지 설치 (nixosOnly) |

## 핵심 절차

1. `mise current`로 현재 선택된 런타임을 확인한다.
2. 전역 버전이 필요하면 `mise use -g node@lts`로 고정한다.
3. 프로젝트별 버전은 `mise.toml` 또는 `.nvmrc` 기준으로 `mise install`을 실행한다.
4. 비대화형 셸 문제는 `~/.zshenv`의 shims 경로와 `mise activate` 적용 여부를 점검한다.

## 자주 발생하는 문제

1. **SSH 비대화형 세션에서 pnpm not found**: `.zshenv`에 mise shims 누락
2. **.nvmrc 인식 안 됨**: `idiomatic_version_file_enable_tools` 설정 필요
3. **NixOS에서 node 빌드 실패**: `MISE_NODE_COMPILE=0` 환경변수 필요

## 레퍼런스

- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
