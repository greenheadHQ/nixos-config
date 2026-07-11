# greenheadHQ/nixos-config

macOS와 NixOS 개발 환경을 **nix-darwin/NixOS + Home Manager**로 선언적으로 관리하는 프로젝트입니다.

## Quick Reference

| 작업 | 명령 / 위치 |
|------|-------------|
| 빌드 | `nrs` (`darwin-rebuild`/`nixos-rebuild` 직접 실행 금지) |
| 플랫폼 판별 | Environment `Platform`: `darwin` → Mac · `linux` → MiniPC |
| MiniPC 접속 | `ssh minipc` (Tailscale VPN 연결 시). 호스트/IP: [`libraries/constants.nix`](./libraries/constants.nix) |
| LLM 행동 규칙 | [`CLAUDE.md`](./CLAUDE.md) |

---

## 플랫폼 구성

| 호스트 | OS | 용도 | 접속 방법 |
|--------|-----|------|----------|
| MacBook Pro | macOS (nix-darwin) | 메인 개발 환경 | 로컬 |
| greenhead-minipc | NixOS | 홈서버 + 원격 개발 서버 | `ssh minipc` |

**공유 설정** (`modules/shared/`):
- 쉘 환경 (zsh, starship, atuin, fzf, zoxide)
- 개발 도구 (git, tmux, neovim (LazyVim), lazygit, direnv, yazi)
- AI 도구 (Claude Code, Codex CLI)
- 시크릿 관리 (agenix)

**플랫폼별 설정**:
- macOS: Homebrew GUI 앱, Hammerspoon, VSCode, Ghostty, Shottr, 폴더 액션
- NixOS: 홈서버 서비스, Tailscale VPN, SSH/mosh, 하드웨어 모니터링

---

## 아키텍처

**주요 진입점**:
- [`flake.nix`](./flake.nix) — `mkDarwinConfig` / `mkNixosConfig`
- [`libraries/constants.nix`](./libraries/constants.nix) — IP/포트/경로/SSH 키/UID 상수 (단일 소스)
- [`modules/nixos/options/homeserver.nix`](./modules/nixos/options/homeserver.nix) — 홈서버 서비스 옵션 선언
- [`modules/shared/programs/`](./modules/shared/programs/) — 공통 개발 도구

**디렉토리 구조**:

```text
flake.nix
libraries/        # 상수, 공통 패키지, overlay
modules/
├── shared/       # Darwin + NixOS 공통 (zsh, git, tmux, neovim, yazi, secrets, claude, codex)
├── darwin/       # macOS 전용 (hammerspoon, vscode, ghostty, shottr, folder-actions)
└── nixos/        # NixOS 전용 (caddy, tailscale, 컨테이너 서비스, temp-monitor)
hosts/            # 호스트별 하드웨어 설정 (disko, WoL)
secrets/          # agenix 암호화 시크릿 (.age)
scripts/          # add-host.sh, fix-fod-hashes.sh
tests/            # eval-tests, shell-script-tests, test-codex-hook-fixtures
```

### 홈서버 서비스

NixOS 홈서버 서비스는 `homeserver.*` 옵션으로 선언적으로 활성화합니다.

- 옵션 선언: [`modules/nixos/options/homeserver.nix`](./modules/nixos/options/homeserver.nix)
- 활성화 위치: [`modules/nixos/configuration.nix`](./modules/nixos/configuration.nix)

**서비스 카테고리**: Immich(사진), Karakeep(웹 아카이버/북마크), Copyparty(파일 서버), Uptime Kuma(모니터링), Caddy(HTTPS 리버스 프록시). 전 서비스에 업데이트 체크/알림 서브시스템을, Immich·Karakeep에는 DB 백업 서브시스템을 포함합니다.

### 상수 관리

모든 공유 상수는 [`libraries/constants.nix`](./libraries/constants.nix)에서 단일 소스로 관리합니다:

| 카테고리 | 내용 |
|----------|------|
| `network` | Tailscale IP, 서비스 포트, Podman 서브넷 |
| `domain` | `greenhead.dev` + 서브도메인 |
| `paths` | Docker 데이터(SSD), 미디어 데이터(HDD), Immich 업로드 캐시 |
| `sshKeys` | MacBook/MiniPC SSH 공개키 (`secrets/secrets.nix`에서도 import) |
| `containers` | 서비스별 리소스 제한 (메모리, CPU) |
| `ids` | UID/GID (postgres, user, users, render) |
| `macos` | Dock, 키보드, Shottr 경로 |
| `ssh` | 타임아웃 설정 (Darwin sshd + NixOS openssh 공통) |
| `tempMonitor` | CPU/NVMe 온도 경고/긴급 임계값, 쿨다운 |

---

## 검증 / 훅

[`lefthook.yml`](./lefthook.yml)로 pre-commit/commit-msg/pre-push 훅 관리.

**통합 검증 (push 전 / 온보딩 시 권장)**: [`bash tests/run-all-tests.sh`](./tests/run-all-tests.sh) — eval-tests · shell-script-tests · codex-hook-fixtures · codex-exec-supervised · skill-doc-sync · analyzing-da-sessions-tests · da-weekly-report-tests · flake-check · statusline-bats · precommit-staged-snapshot를 한 번에 순차 실행하고 통과/SKIP/실패를 구분 요약한다(하나라도 실패 시 non-zero). 로컬 훅을 우회(`git commit --no-verify` / `LEFTHOOK=0`)했거나 fresh clone에서 훅 설치 전이라도 전체 테스트를 재검증한다. PR에서는 main branch protection의 required `check` job이 devShell 안에서 이 명령을 실행하며 SKIP도 실패로 처리한다. main은 최신 base 재검증(`strict`)과 한 명의 승인·CODEOWNER review를 요구하며, [`.github/CODEOWNERS`](./.github/CODEOWNERS)가 required workflow와 ownership 규칙 자체를 저장소 소유자에게 귀속한다. 개인 소유·단독 관리자 저장소이므로 소유자는 관리자 우회 trust anchor이고, 비관리자 write collaborator는 required workflow를 자가 수정해 병합할 수 없다.

**pre-commit** (병렬):
- `lefthook-guard-self-check` — 현재 worktree에서 Git이 해석한 hooks 경로(`git rev-parse --git-path hooks`)를 기준으로, (1) `pre-commit`의 staged-config guard marker, (2) 세 hook(`pre-commit`/`commit-msg`/`pre-push`)의 설치 여부와 lefthook 호출부의 `--no-auto-install` 플래그가 사라지면 commit fail-fast. lefthook의 암묵 auto-sync(`lefthook.yml` 변경 후 첫 실행)와 인접 worktree의 `lefthook install` 덮어쓰기, 두 회귀 경로를 함께 막는다
- `ai-skills-consistency` — staged snapshot 기준 `.claude/skills`, `.agents/skills`, `modules/shared/programs/codex` 구조 일관성
- `gitleaks` — staged policy/config 기준 시크릿 유출 방지
- `nixfmt` — Nix 포매팅 검증
- `shellcheck` — 셸 스크립트 린팅
- `eval-tests` — staged snapshot 기준 Nix 평가 테스트 ([`tests/eval-tests.nix`](./tests/eval-tests.nix))
- `codex-hook-fixtures` — staged snapshot 기준 Codex 0.124+ stable hook 회귀 차단 deterministic fixture (`--no-live`) ([`tests/test-codex-hook-fixtures.sh`](./tests/test-codex-hook-fixtures.sh))
- `skill-noise-check` — staged snapshot 기준 shared skill markdown noise 검사
- `local-skill-noise-check` — staged snapshot 기준 `.claude/skills` markdown noise 검사

pre-commit 정책:
- whole-repo / whole-corpus hook은 [`scripts/ai/run-staged-snapshot.sh`](./scripts/ai/run-staged-snapshot.sh)를 통해 staged index snapshot에서 실행한다.
- `gitleaks`는 [`scripts/ai/run-gitleaks-staged-policy.sh`](./scripts/ai/run-gitleaks-staged-policy.sh)를 통해 copied temp index, staged snapshot worktree, staged `.gitleaks.toml` / `.gitleaksignore`만 사용한다.
- installed `git commit` 경로는 [`scripts/ai/install-lefthook-hooks.sh`](./scripts/ai/install-lefthook-hooks.sh)가 메인 repo에서는 git default hook path(`.git/hooks`)에, 워크트리에서는 worktree-local hook path(`.git/worktrees/<name>/hooks`)에 pre-Lefthook guard를 주입한다. 이 guard는 `lefthook.yml`과 repo-local hook scripts의 index/working-tree drift, unsupported Lefthook merged config surface, `LEFTHOOK_CONFIG` / `LEFTHOOK_BIN` / `LEFTHOOK_EXCLUDE`를 차단한다. 같은 스크립트가 설치된 모든 hook의 lefthook 호출부에 `--no-auto-install`을 주입한다 — `lefthook run`은 `lefthook.checksum`이 stale하면 hook을 암묵 재설치(`sync hooks`)하면서 이 guard를 지우기 때문이다(그래서 `lefthook.yml`을 바꾼 뒤 첫 commit이 실패했다). hook checksum 갱신은 이 스크립트의 `lefthook install`이 전담하므로 자동 재설치를 잃어도 손해가 없다. guard 블록이나 플래그가 사라지는 경우(암묵 auto-sync, 또는 인접 worktree의 `lefthook install` 덮어쓰기)는 `lefthook-guard-self-check` command가 commit-time에 fail-fast로 차단한다.
- 표준 우회인 `git commit --no-verify`와 `LEFTHOOK=0`은 여전히 hook을 실행하지 않는다.
- 직접 스크립트 실행은 pre-commit staged snapshot 경로와 동일하지 않다.

**commit-msg**:
- `lefthook-guard-self-check` — pre-commit self-check의 복제. `git commit --allow-empty`처럼 staged files가 0이라 pre-commit command가 skip되는 경로까지 차단한다
- `pinning` — commit message LLM 박제 패턴 감지 (warn-only) ([`scripts/ai/commit-msg-pinning.sh`](./scripts/ai/commit-msg-pinning.sh))

**LLM durable-output pinning guard layers**:
- Runtime hard-fail: Claude/Codex PreToolUse `pinning-guard.sh` blocks new volatile review/session metadata before supported edit/apply_patch tools and targeted git/gh durable commands write eligible markdown, shell, notebook, body-temp, commit, PR, or issue text.
- Runtime warn-only: Claude/Codex PostToolUse `pinning-alert.sh` remains as a second signal after supported edit/apply_patch tools run.
- Commit-message warn-only: `commit-msg-pinning.sh` still reports the same shared pattern family for commit messages.
- Shared source: pattern definitions and reporting live in [`modules/shared/programs/claude/files/lib/pinning-patterns.sh`](./modules/shared/programs/claude/files/lib/pinning-patterns.sh); Codex fixture coverage is in [`tests/fixtures/codex-hooks/README.md`](./tests/fixtures/codex-hooks/README.md).
- Codex config ownership: `hooks.PreToolUse` is now template-owned like `UserPromptSubmit`, `Stop`, and `PostToolUse`; add user hooks under events not declared by the template unless `sync-codex-config.py` is changed.

**pre-push**:
- devShell 진입 시 [`scripts/ai/test-runtime-profile.sh`](./scripts/ai/test-runtime-profile.sh)가 worktree별 `prePushRuntime` GC-root를 content stamp 기반으로 사전 빌드한다. hook은 이 PATH를 공유하고 profile 부재/stale 시 동일 flake package로 폴백한다.
- `analyzing-da-sessions-tests` — analyzing-da-sessions/run-da 계약 변경에만 pytest fixture를 실행한다.
- `flake-check` — `.nix`/`flake.lock` push에만 `nix flake check --no-build --all-systems`를 실행한다.
- `statusline-bats` — statusline 소스/테스트 push에만 Bats fixture를 실행하고 비대화형 hook에 기본 `TERM`을 주입한다.
- 전체 shell fixture와 Codex hook fixture는 모든 PR의 required CI에서 검증하고, Codex fixture는 관련 staged 변경의 pre-commit에서도 실행한다. 삭제 파일 등 Lefthook `push_files` 필터의 사각지대도 required CI가 보완한다. 수동 push 전 전체 로컬 검증이 필요하면 `bash tests/run-all-tests.sh`를 실행한다.

`ai-skills-consistency` 훅 동작 ([`scripts/ai/warn-skill-consistency.sh`](./scripts/ai/warn-skill-consistency.sh)):
- **일반 커밋**: 불일치 감지 시 경고만 출력 (차단 없음)
- **스킬/Codex 관련 파일 staged 시**: 커밋 차단 — 해당 경로는 `.claude/skills/*`, `.agents/skills/*`, `modules/shared/programs/claude/*`, `modules/shared/programs/codex/*`, `scripts/ai/lib/*`, `libraries/python-runtimes.nix`, `flake.nix`, `lefthook.yml`, `AGENTS.md`, `AGENTS.override.md`, `CLAUDE.md`, `scripts/ai/verify-ai-compat.sh`, `scripts/ai/warn-skill-consistency.sh`, `scripts/ai/commit-msg-pinning.sh`
- pre-commit에서는 staged file list를 snapshot runner가 NUL-delimited env file로 전달한다. 직접 실행 시에만 `git diff --cached` fallback을 사용한다.
- 긴급 우회: `SKIP_AI_SKILL_CHECK=1 git commit ...`
- `SKILL.md` 도구-중립성 lint는 [`scripts/ai/verify-ai-compat.sh`](./scripts/ai/verify-ai-compat.sh) 일반 실행에서 FAIL finding을 exit 1로 처리
- lint fixture만 검증: [`scripts/ai/verify-ai-compat.sh --run-fixture-tests`](./scripts/ai/verify-ai-compat.sh)
- 해결 후: `nrs` + [`scripts/ai/verify-ai-compat.sh`](./scripts/ai/verify-ai-compat.sh) 재검증

---

## Getting Started

### 새 Mac 설정

```bash
# 1. Nix 설치
curl -L https://nixos.org/nix/install | sh
# 설치 후 터미널 재시작

# 2. 저장소 클론
mkdir -p ~/Workspace && cd ~/Workspace
git clone https://github.com/greenheadHQ/nixos-config.git
cd nixos-config

# 3. SSH 키 복원 (~/.ssh/id_ed25519)
# 상세: .claude/skills/managing-ssh/ 참고

# 4. flake.nix에서 username/hostname 수정
# username: whoami 출력값
# hostname: scutil --get LocalHostName 출력값

# 5. nix-darwin 부트스트랩
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
sudo mv /etc/bashrc /etc/bashrc.before-nix-darwin
sudo mv /etc/zshrc /etc/zshrc.before-nix-darwin
ssh-add ~/.ssh/id_ed25519
sudo --preserve-env=SSH_AUTH_SOCK nix run nix-darwin -- switch --flake .

# 6. 이후 설정 적용
nrs

# 7. 전체 검증 (push 전·온보딩 시 권장)
bash tests/run-all-tests.sh
```

### 새 호스트 추가 / MiniPC 설치

- 새 호스트: `bash scripts/add-host.sh` → `flake.nix`, `constants.nix` 수정 → 시크릿 재암호화
- MiniPC 설치/복구: [`managing-minipc`](./.claude/skills/managing-minipc/) 스킬

---

## 문서 / 스킬

상세 문서는 [`.claude/skills/`](./.claude/skills/)에서 관리합니다.
Claude Code 세션에서 질문하면 관련 스킬이 자동으로 로드됩니다.

| 주제 | 스킬 |
|------|------|
| macOS 설정 | `managing-macos` |
| NixOS/MiniPC | `managing-minipc` |
| Nix/flake | `understanding-nix` |
| SSH/Tailscale | `managing-ssh` |
| 시크릿 관리 | `managing-secrets` |
| 컨테이너 서비스 | `running-containers` |
| Karakeep | `hosting-karakeep` |
| Copyparty | `hosting-copyparty` |

추가 참고:
- [`CLAUDE.md`](./CLAUDE.md) — LLM 행동 규칙 (실행 환경 판별, 빌드, Bash tool 환경, 상수 관리 등)
