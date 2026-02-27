---
name: configuring-codex
description: |
  Codex CLI config, skill projection, AGENTS.md, trust/sandbox.
  Triggers: "codex config", "codex setup", "codex trust", "Codex 설정",
  "AGENTS.md", ".agents/skills", "project-scope skill", "스킬 투영",
  "approval_policy", "sandbox_mode", "Codex compatibility".
---

# Codex CLI 설정

Codex CLI 호환 레이어와 프로젝트 스킬 발견 문제를 다룹니다.

## 목적과 범위

- `~/.codex/config.toml` 실행 정책(`approval_policy`, `sandbox_mode`) 및 모델 설정
- `AGENTS.md`/`.agents/skills` 투영 구조
- `.agents/skills/*` 디렉토리 심링크 검증
- `nrs`(또는 동등 activation) 이후 결과 검증
- Claude Code와 Codex CLI 동작 차이 정리

Claude 전용 플러그인/훅 세부 내용은 `configuring-claude-code` 스킬을 사용합니다.

## 빠른 진단 체크리스트

1. `.agents/skills/*`이 디렉토리 심링크인지 확인 (`ls -la .agents/skills/`)
2. `wt` 생성 직후 `.agents/.agents`, `.claude/.claude` 중첩이 없는지 확인
3. 프로젝트 루트 `AGENTS.md -> CLAUDE.md` 심링크 확인 (git-tracked)
4. `./scripts/ai/verify-ai-compat.sh` 실행
5. `codex exec`로 런타임에서 스킬 이름이 보이는지 확인
6. 권한 프롬프트 이슈는 `approval_policy`, `sandbox_mode` 설정으로 분리 진단

## 핵심 파일

- `modules/shared/programs/codex/default.nix` — 설정 및 스킬 투영
- `modules/shared/programs/codex/files/config.toml` — 실행 정책/모델 설정
- `scripts/ai/verify-ai-compat.sh` — 구조 검증
- `modules/shared/programs/claude/files/CLAUDE.md` — 글로벌 라우팅/지침
- `.claude/skills/*` (원본)
- `.agents/skills/*` (Codex 발견용 투영)

## 설치/업데이트 경로

Codex CLI 바이너리 설치/업데이트는 `modules/shared/programs/codex/default.nix`의
`home.activation.installCodexCli`에서 관리한다. 운영 절차는 `nrs` 적용 후
`codex --version`과 `./scripts/ai/verify-ai-compat.sh`로 검증한다.

## 진단 우선순위 (중요)

Skills 누락 이슈의 1차 원인은 `trust`보다 투영 방식이다.
Codex CLI는 **디렉토리 심링크**를 따라가지만 **파일 심링크**는 무시한다 (PR #8801).
`.agents/skills/<name>`은 반드시 디렉토리 심링크여야 하며, SKILL.md 파일 자체를 심링크하면 안 된다.

## 실행 정책 / Trust 메모

`codex-cli 0.101.0` 기준으로 `codex trust` 독립 서브커맨드는 확인되지 않았다.  
권한 프롬프트 동작은 전역 실행 정책으로 제어한다.

```toml
approval_policy = "never"
sandbox_mode = "danger-full-access"
```

`trust_level` 프로젝트 엔트리는 경로별 세부 제어가 필요할 때만 추가한다.

## 트러블슈팅 / FAQ

- **스킬이 안 보임**: `.agents/skills/*`가 파일 심링크인지 확인하고 디렉토리 심링크로 교정한다.
- **`wt` 직후 `?? .agents/.agents/`, `?? .claude/.claude/`**: worktree 복사 회귀다. `.agents/.agents`는 Codex가 기대하는 투영 경로가 아니므로 정리 후 원인(`wt`의 중복 `cp -R`)을 먼저 수정한다.
- **자동 회귀 방지 확인**: `tests/run-wt-regression.sh`를 실행하고, `lefthook.yml`의 `wt-regression` pre-commit 훅이 활성화되어 있는지 확인한다.
- **권한 프롬프트 반복**: `~/.codex/config.toml`의 `approval_policy`, `sandbox_mode`를 확인한다.
- **AGENTS 불일치**: 프로젝트 루트 `AGENTS.md -> CLAUDE.md` 심링크를 복구한다.
- **활성화 누락**: `nrs` 실행 후 `./scripts/ai/verify-ai-compat.sh`로 재검증한다.

## 투영 아키텍처

```
.claude/skills/<name>/                  # 단일 원본 (SKILL.md, references/ 등)
      -> directory symlink
.agents/skills/<name>/                  # ../../.claude/skills/<name> 심링크
```

Codex CLI는 디렉토리 심링크를 `follow_links(true)`로 순회한다 (PR #8801).
파일 심링크는 무시되므로 반드시 디렉토리 단위로 심링크해야 한다.

## 활성화

원칙은 `nrs` 실행이다.  
환경 제약으로 `nrs`를 실행하지 못하면, Codex 모듈 activation과 동등한 절차로 재생성해도 된다.

## 검증 명령

```bash
# 구조 검증
./scripts/ai/verify-ai-compat.sh

# 디렉토리 심링크 검증 (모두 심링크여야 함)
for d in .agents/skills/*; do
  [ -L "$d" ] && echo "OK: $(basename $d) -> $(readlink $d)" || echo "FAIL: $(basename $d)"
done

# 런타임 인식 검증
codex -a never exec "Answer YES or NO only: Is a skill named 'configuring-codex' available in this workspace?"
```

## 관련 스킬

- `syncing-codex-harness`: 다른 프로젝트에서 Codex 하네스 동기화 시 사용

## 레퍼런스

- 상세 장애 기록 및 회귀 체크: `references/runbook-codex-compat.md`

문서와 CLI 동작이 다를 때는 CLAUDE.md의 "스킬 문서 불일치 시 행동 원칙"을 따른다.
