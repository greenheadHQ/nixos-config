---
name: understanding-nix
description: |
  This skill should be used when the user encounters Nix fundamentals issues
  including flakes, derivations, substituters, devShell, direnv, and pre-commit hooks.
  Triggers: "nix flake update", "flake change detection", "slow build",
  "substituter", "derivation", "direnv", "direnv allow", "devShell",
  "experimental features", "Nix 빌드 느림", "flake 인식 안 됨",
  "gitleaks not found", "lefthook not found", "pre-commit hook 실패",
  "builtins.toJSON", "nix-ld", "pkgs.formats.json",
  "max-substitution-jobs", "병렬 다운로드", "nix.conf 설정".
  For NixOS/MiniPC hardware issues use managing-minipc.
  For macOS/nix-darwin system settings use managing-macos.
---

# Nix 공통 이슈

NixOS와 nix-darwin 모두에 해당하는 Nix 공통 개념 및 이슈입니다.

## 목적과 범위

flake 평가, derivation 해석, substituter/빌드 성능, 공통 오류 복구 절차를 다룬다.

## 빠른 참조

### 주요 설정 파일

| 파일 | 용도 |
|------|------|
| `flake.nix` | 입력과 출력 정의 (nixpkgs → `nixos-unstable-small`) |
| `flake.lock` | 입력 버전 고정 |
| `modules/shared/configuration.nix` | 공통 Nix 설정 (experimental-features, GC, substituter) |
| `modules/shared/programs/direnv/default.nix` | direnv + nix-direnv 설정 |
| `lefthook.yml` | Pre-commit hooks 정의 |
| `~/.config/nix/nix.conf` | 사용자별 Nix 설정 |

### Flake 명령어

```bash
nix flake update                          # 모든 input 업데이트
nix flake lock --update-input nixpkgs     # 특정 input만 업데이트
nix flake check --no-build --all-systems  # flake 평가 오류 검사
```

### Experimental Features

`experimental-features = nix-command flakes`가 `modules/shared/configuration.nix`에서 시스템 전역 설정됨.
부트스트랩 전에는 `--extra-experimental-features "nix-command flakes"` 플래그 필요.

### 빌드 속도 최적화

| 방법 | 명령어/설정 | 효과 |
|------|------------|------|
| 오프라인 빌드 | `nrs-offline` | 네트워크 요청 없음 (~10초, 18배 빠름) |
| 병렬 다운로드 | `max-substitution-jobs = 128` | 동시 128개 다운로드 (기본 16) |
| HTTP 연결 | `http-connections = 50` | 동시 50 연결 (기본 25) |
| GitHub 토큰 | `access-tokens = github.com=...` | rate limit 해제 |

### 에러 디버깅

```bash
nix build --show-trace                                   # 상세 빌드 로그
nix derivation show .#darwinConfigurations.<host>.system  # derivation 확인
```

## 핵심 절차

### Flake 변경 반영

1. `git add .` — Nix flakes는 git-tracked 파일만 인식한다.
2. `nix flake update <input-name>` — 외부 input 갱신이 필요한 경우.
3. `nrs` 또는 `nrs-offline`으로 빌드.

### 빌드 실패 진단

1. `--show-trace`로 에러 원인 모듈을 좁힌다.
2. `nix derivation show`로 derivation 구조를 확인한다.
3. 수정 후 `nrs`로 재검증한다.

## direnv + nix-direnv

프로젝트 디렉토리 진입 시 devShell 환경을 자동 활성화한다.

```bash
echo "use flake" > .envrc    # .envrc 생성 (nixos-config은 이미 커밋됨)
direnv allow                 # 최초 1회 허용
cd ~/Workspace/nixos-config  # 자동 활성화 (이후 이탈 시 자동 해제)
```

- nix-direnv가 `.direnv/`에 결과를 캐싱 (첫 로드 ~수 초, 이후 ~100ms)
- devShell 내 도구(gitleaks, lefthook 등)는 direnv 환경에서만 사용 가능

## Pre-commit Hooks (lefthook)

| Hook | 도구 | 기능 |
|------|------|------|
| gitleaks | `gitleaks protect --staged` | 민감 정보 커밋 차단 |
| nixfmt | `nixfmt --check` | Nix 포맷 검사 |
| shellcheck | `shellcheck -S warning` | Shell 스크립트 린팅 |
| eval-tests | `tests/run-eval-tests.sh` | NixOS 보안 검증 (~1.2s) |
| flake-check (pre-push) | `nix flake check` | Flake 평가 오류 검사 |

direnv 환경이 비활성 상태에서 커밋하면 hook이 실패한다. `direnv allow` 실행으로 해결.

## 자주 발생하는 문제

1. **flake 인식 안 됨**: `git add` 필요 (untracked 파일은 무시됨)
2. **experimental features 비활성화**: `nix-command flakes` 활성화 필요
3. **빌드 느림**: `nrs-offline` 사용 또는 substituter 설정 확인
4. **gitleaks/lefthook not found**: direnv 환경 미활성 — `direnv allow` 실행
5. **builtins.toJSON 한 줄 출력**: `pkgs.formats.json` 사용으로 pretty-print

## 레퍼런스

- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
- 기능 목록: [references/features.md](references/features.md)
