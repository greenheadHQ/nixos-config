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
| `~/.config/mise/config.toml` | 전역 설정 — nix 선언 read-only symlink. SoT: `modules/shared/programs/mise/config.toml` |
| `~/.config/mise/conf.d/*.toml` | 머신 로컬/임시 전역 도구 (nix 비관리 — config.toml과 병합 로드) |
| `mise.toml` / `.mise.toml` | 프로젝트별 설정 |
| `mise.local.toml` | 프로젝트 로컬 (gitignore됨) |
| `.nvmrc`, `.node-version` | Node.js 버전 (idiomatic files) |

### 주요 명령어

```bash
# 현재 버전 확인
mise current

# 전역 버전 변경: modules/shared/programs/mise/config.toml 수정 후 nrs
# (`mise use -g`·`mise settings add/set/unset` 같은 전역 쓰기 명령은 read-only config라 의도적으로 실패 — drift 가드)

# 프로젝트 버전 설치
mise install node@20.18

# 프로젝트 설정 신뢰
mise trust
```

### 관련 설정 파일

| 파일 | 용도 |
|------|------|
| `modules/shared/programs/mise/config.toml` | 전역 config SoT (`~/.config/mise/config.toml`로 심링크 배포) |
| `modules/shared/programs/shell/default.nix` | zsh mise 활성화 (shims + activate) |
| `modules/shared/programs/shell/nixos.nix` | NixOS 환경변수 (`MISE_ALL_COMPILE=0`, `MISE_NODE_COMPILE=0`) |
| `libraries/packages.nix` | `pkgs.mise` 패키지 설치 (shared — macOS+NixOS 공통) |

## 셸 활성화 구조

mise는 두 계층으로 활성화된다:

| 계층 | 파일 | 명령어 | 용도 |
|------|------|--------|------|
| `.zshenv` | `shell/default.nix` envExtra | `mise activate zsh --shims` | snapshot 미경유 비대화형(SSH `zsh -c` 등)에서 PATH에 shim 추가 |
| `.zshrc` | `shell/default.nix` initContent | `mise activate zsh` + shims prepend | 대화형 훅(cd-time 버전 전환) + Claude Code snapshot 경유 비대화형 보강 |

가드와 `.zshrc` 추가 prepend의 배경:

- 가드 기반: shims 경로의 PATH 실재 여부로 중복 활성화를 판단한다 (`[[ ":$PATH:" != *":$shims:"* ]]`). shims 경로 fallback은 mise 공식 우선순위 `MISE_DATA_DIR` → `$XDG_DATA_HOME/mise` → `$HOME/.local/share/mise`를 따른다 (`libraries/constants.nix`의 `mise.shimsDirExpr`이 SoT).
- 옛 `MISE_SHELL` 가드 폐기 (#845): 부모 대화형 셸의 `MISE_SHELL`이 자식 비대화형 셸로 상속되어 shims 활성화를 조기 스킵하는 회귀를 만들어 폐기됐다.
- `.zshrc`에서 shims prepend가 추가로 필요한 이유 (#857): Claude Code 같은 도구가 세션 시작 시 interactive 셸 PATH를 snapshot으로 박제하고 비대화형 호출마다 그 PATH를 복원한다. `mise activate zsh`(hook 모드)는 호출 끝에 `_mise_hook`을 즉시 발동시켜 install-bins를 PATH에 prepend하지만, hook 모드 정책상 shims는 PATH에 prepend하지 않는다 (shims는 `--shims` 플래그 경유에서만 PATH에 들어간다). 결과적으로 snapshot에는 install-bins는 들어가도 shims가 빠진 baseline이 박제되어, shim으로 노출되는 mise 도구(예: pnpm, per-project node)는 비대화형에 미노출된다. `.zshrc`에서 shims를 명시적으로 prepend하면 snapshot에 shims도 포함되어 비대화형 호출이 동작한다. (과거 이 회귀의 대표 사례였던 codex는 #890에서 nix overlay로 이관돼 더는 mise shim에 의존하지 않는다.)
- 위험·우려와 fallback 후보: 이 fix는 Claude Code snapshot 캡처 메커니즘에 간접 의존한다. 향후 캡처 방식 변경(예: sanitized PATH 기록) 시 회귀 재발 가능. fallback 후보는 (a) `~/.claude/settings.json`의 `env.PATH`에 shims를 직접 prepend, (b) login shell init(`.zprofile`/`.zlogin`)에 shims 보강. (과거 codex 비노출 회귀 조기 감지로 검토했던 `command -v codex` 자가 검사는 codex의 nix overlay 이관 이후 mise shim과 무관해졌고, `verify-ai-compat`에는 codex가 shim에 가려지지 않고 nix 경로로 resolve되는지 검사하는 가드가 별도로 추가됐다 — #890.)

## 핵심 절차

1. `mise current`로 현재 선택된 런타임을 확인한다.
2. 전역 버전 변경은 `modules/shared/programs/mise/config.toml` 수정 후 `nrs`로 배포한다.
3. 프로젝트별 버전은 `mise.toml` 또는 `.nvmrc` 기준으로 `mise install`을 실행한다.
4. `.nvmrc` 인식(`idiomatic_version_file_enable_tools`)은 전역 config에 선언돼 있다 — 별도 실행 불필요.
5. 비대화형 셸 문제는 `~/.zshenv`의 shims 경로와 `mise activate` 적용 여부를 점검한다.

## 자주 발생하는 문제

1. SSH 비대화형 세션에서 pnpm not found: `.zshenv`에 mise shims 누락 → 셸 활성화 구조 참조
2. .nvmrc 인식 안 됨: node는 전역 SoT에 이미 idiomatic 선언돼 있으므로 nrs 배포 상태부터 확인 → 상세·다른 도구 추가는 troubleshooting 참조
3. NixOS에서 node 빌드 실패: `MISE_NODE_COMPILE=0` 필요 (현재 `nixos.nix`에서 영구 설정됨)
4. mise.local.toml 미신뢰: `mise trust` 실행 필요 (최초 1회; worktree도 경로가 다르므로 별도 trust)
5. `mise use -g`/`mise settings add·set·unset` 실패 (read-only config): 의도된 가드 — 전역 변경은 SoT 파일 수정 + nrs, 임시 도구는 `~/.config/mise/conf.d/` (읽기 명령 `mise settings`는 정상 동작)

## 레퍼런스

- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
