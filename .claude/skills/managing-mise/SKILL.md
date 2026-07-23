---
name: managing-mise
description: |
  Manage mise runtime: Node.js, pnpm, shims.
  Trigger: 'mise 설정', 'pnpm not found', 'node not found', '.nvmrc', 'mise shims',
  'mise activate', 'mise trust', 'mise exec', '런타임 버전 불일치', 'No version is set',
  'worktree에서 node/pnpm 실패', '여러 node 버전 공존', 'activation에서 mise 실패'.
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

# 프로젝트 설정 신뢰 (실행 전 아래 "trust 선행 조건" 참조)
mise trust
```

### trust 선행 조건 (정본)

`mise trust`는 config의 env·template·hook 같은 실행성 기능을 활성화하는 보안 승인이다.
실행 전 config 내용을 검토하고, 사용자 소유이거나 사용자가 신뢰를 명시한 저장소에서만 실행한다
(글로벌 CLAUDE.md 규약과 동일). 본 문서의 모든 `mise trust` 안내는 이 조건을 전제한다.

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

## 비대화형/LLM 마찰 경계면

mise 사용은 아래 비대화형·자동화 컨텍스트에서 서로 다른 이유로 깨지는 사례가 반복 관측됐다 (2026-07 세션 로그·히스토리 전수조사) — 앞 두 행은 hook/shims 활성화 문제(`mise activate zsh` hook 모드는 대화형 셸 기준, `--shims`는 비대화형용 — 위 표 참조), activation 행은 제한 PATH, worktree 행은 config trust 문제다. 사람의 대화형 셸에서는 재현되지 않으므로 "내 셸에선 되는데"로 진단이 지연되기 쉽다.

| 경계면 | 전형적 증상 | 대응 |
|---|---|---|
| 비대화형 셸 (SSH `zsh -c`, LLM shell) | pnpm/node not found | `.zshenv` shims가 선언적 환경 방어. 즉시 복구는 `mise exec -- <명령>` |
| hook 실행 환경 (lefthook·플러그인 hook) | 런타임 not found로 품질 게이트 조용한 무력화 | hook 스크립트가 mise 도구를 부르면 shims PATH 보강 또는 `mise exec` 경유 |
| home-manager activation 제한 PATH | `mise: command not found`, reshim exit 127 | activation에서 mise 실행 금지 (#814→#890 교훈) |
| worktree cwd | 프로젝트 config 미신뢰로 도구 비활성 | 버전·모드·연결 상태에 따라 trust 공유 여부가 다름 — 아래 "worktree trust 공유 조건" 참조 |

비대화형에서 PATH 문제의 안전한 복구 규약: `mise exec -- <명령>` — 버전 resolve와 PATH 주입을 mise가 한 번에 처리하므로 shims/activate 상태와 무관하게 동작한다. 대화형 성공을 근거로 다른 컨텍스트도 동작할 것이라 가정하지 않는다. 단 이는 PATH 복구 경로일 뿐 trust 경계의 우회가 아니다 — 검토하지 않은 config가 로드되는 컨텍스트라면 실행 전에 trust 선행 조건을 먼저 적용한다.

### worktree trust 공유 조건

| 조건 | trust 공유 | 조치 |
|---|---|---|
| 2026.7.5 이상, 일반 모드, linked worktree — main checkout의 동일 config 경로가 이미 trusted이고 worktree에서 `--ignore`하지 않은 경우 | 공유 (main→worktree 단방향) | 추가 trust 불요 |
| 2026.7.4 이하 (검증 당시 배포본 2025.12.13 포함) | 비공유 | worktree별 `mise trust` (선행 조건 적용) |
| paranoid mode | 비공유 (의도된 재승인 경계) | 수동 재승인 |
| git 비연결 디렉토리 | 비공유 | `mise trust` (선행 조건 적용) |

주의: trust는 경로 기준 신뢰이지 config 내용의 검증이 아니다 (콘텐츠 기준 재승인은 paranoid mode만 제공). worktree든 main checkout이든 branch 전환·pull로 이미 trusted인 경로의 config 내용이 바뀌어도 재승인을 묻지 않으므로, 외부/타인 브랜치를 받았다면 mise config 변경 여부를 먼저 검토한다 (env·template은 로드 시 셸 명령을 실행할 수 있다).

근거: worktree trust 공유는 mise 2026.7.5에서 도입 ([upstream 릴리스](https://github.com/jdx/mise/releases/tag/v2026.7.5)). 재검증: `mise trust --help`의 worktree 공유 문구.

## 핵심 절차

1. `mise current`로 현재 선택된 런타임을 확인한다.
2. 전역 버전 변경은 `modules/shared/programs/mise/config.toml` 수정 후 `nrs`로 배포한다.
3. 프로젝트별 버전은 `mise.toml` 또는 `.nvmrc` 기준으로 `mise install`을 실행한다.
4. `.nvmrc` 인식(`idiomatic_version_file_enable_tools`)은 전역 config에 선언돼 있다 — 별도 실행 불필요.
5. 비대화형 셸 실패의 즉시 복구는 `mise exec -- <명령>` 경유가 우선이다. 같은 실패가 반복되거나 셸 환경의 영구 복구가 필요할 때만 `~/.zshenv`의 shims 경로와 `mise activate` 적용 여부를 점검한다.

## 자주 발생하는 문제

1. SSH 비대화형 세션에서 pnpm not found: `.zshenv`에 mise shims 누락 → 셸 활성화 구조 참조
2. .nvmrc 인식 안 됨: node는 전역 SoT에 이미 idiomatic 선언돼 있으므로 nrs 배포 상태부터 확인 → 상세·다른 도구 추가는 troubleshooting 참조
3. NixOS에서 node 빌드 실패: `MISE_NODE_COMPILE=0` 필요 (현재 `nixos.nix`에서 영구 설정됨)
4. mise.local.toml 미신뢰: `mise trust` 실행 필요 (최초 1회; trust 선행 조건 참조. worktree는 trust 공유 조건 표 참조)
5. `mise use -g`/`mise settings add·set·unset` 실패 (read-only config): 의도된 가드 — 전역 변경은 SoT 파일 수정 + nrs, 임시 도구는 `~/.config/mise/conf.d/` (읽기 명령 `mise settings`는 정상 동작)

## 레퍼런스

- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
