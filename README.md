# green/nixos-config

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

**서비스 카테고리**: Immich(사진), Vaultwarden(비밀번호), Karakeep(웹 아카이버/북마크), Copyparty(파일 서버), Anki(동기화 · AnkiConnect · awesome-anki), Uptime Kuma(모니터링), Caddy(HTTPS 리버스 프록시). 각 서비스별 백업/업데이트 체크/알림 서브시스템 포함.

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

[`lefthook.yml`](./lefthook.yml)로 pre-commit/pre-push 훅 관리.

**pre-commit** (병렬):
- `ai-skills-consistency` — `.claude/skills`, `.agents/skills`, `modules/shared/programs/codex` 구조 일관성
- `gitleaks` — 시크릿 유출 방지
- `nixfmt` — Nix 포매팅 검증
- `shellcheck` — 셸 스크립트 린팅
- `eval-tests` — Nix 평가 테스트 ([`tests/eval-tests.nix`](./tests/eval-tests.nix))
- `codex-hook-fixtures` — Codex 0.124+ stable hook 회귀 차단 deterministic fixture (`--no-live`) ([`tests/test-codex-hook-fixtures.sh`](./tests/test-codex-hook-fixtures.sh))

**commit-msg**:
- `pinning` — commit message LLM 박제 패턴 감지 (warn-only) ([`scripts/ai/commit-msg-pinning.sh`](./scripts/ai/commit-msg-pinning.sh))

**LLM durable-output pinning guard layers**:
- Runtime hard-fail: Claude/Codex PreToolUse `pinning-guard.sh` blocks new volatile review/session metadata before supported edit/apply_patch tools and targeted git/gh durable commands write eligible markdown, shell, notebook, body-temp, commit, PR, or issue text.
- Runtime warn-only: Claude/Codex PostToolUse `pinning-alert.sh` remains as a second signal after supported edit/apply_patch tools run.
- Commit-message warn-only: `commit-msg-pinning.sh` still reports the same shared pattern family for commit messages.
- Shared source: pattern definitions and reporting live in [`modules/shared/programs/claude/files/lib/pinning-patterns.sh`](./modules/shared/programs/claude/files/lib/pinning-patterns.sh); Codex fixture coverage is in [`tests/fixtures/codex-hooks/README.md`](./tests/fixtures/codex-hooks/README.md).
- Codex config ownership: `hooks.PreToolUse` is now template-owned like `UserPromptSubmit`, `Stop`, and `PostToolUse`; add user hooks under events not declared by the template unless `sync-codex-config.py` is changed.

**pre-push**:
- `shell-script-tests` — 배포 레이아웃 fixture 테스트. tomlkit bootstrap wrapper [`tests/run-shell-script-tests.sh`](./tests/run-shell-script-tests.sh)가 [`tests/shell-script-tests.sh`](./tests/shell-script-tests.sh)를 호출.
- `codex-hook-fixtures` — Codex 0.124+ stable hook 회귀 차단 deterministic fixture (`--no-live`) ([`tests/test-codex-hook-fixtures.sh`](./tests/test-codex-hook-fixtures.sh))
- `flake-check` — `nix flake check --no-build --all-systems`

`ai-skills-consistency` 훅 동작 ([`scripts/ai/warn-skill-consistency.sh`](./scripts/ai/warn-skill-consistency.sh)):
- **일반 커밋**: 불일치 감지 시 경고만 출력 (차단 없음)
- **스킬/Codex 관련 파일 staged 시**: 커밋 차단 — 해당 경로는 `.claude/skills/*`, `.agents/skills/*`, `modules/shared/programs/claude/*`, `modules/shared/programs/codex/*`, `scripts/ai/lib/*`, `libraries/python-runtimes.nix`, `flake.nix`, `lefthook.yml`, `AGENTS.md`, `AGENTS.override.md`, `CLAUDE.md`, `scripts/ai/verify-ai-compat.sh`, `scripts/ai/warn-skill-consistency.sh`, `scripts/ai/commit-msg-pinning.sh`
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
| Vaultwarden | `hosting-vaultwarden` |
| Karakeep | `hosting-karakeep` |
| Copyparty | `hosting-copyparty` |
| Anki 동기화 | `hosting-anki` |

추가 참고:
- [`CLAUDE.md`](./CLAUDE.md) — LLM 행동 규칙 (실행 환경 판별, 빌드, Bash tool 환경, 상수 관리 등)
