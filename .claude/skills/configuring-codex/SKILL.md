---
name: configuring-codex
description: |
  Codex CLI config, skill projection, AGENTS.md, trust/sandbox.
  Triggers: "codex config", "codex setup", "codex trust", "AGENTS.md",
  ".agents/skills", "project-scope skill", Codex skill discovery
  failures, approval/sandbox policy, Claude/Codex compatibility.
---

# Codex CLI 설정

Codex CLI 호환 레이어와 프로젝트 스킬 발견 문제를 다룹니다.

## 범위

- `~/.codex/config.toml` 실행 정책(`approval_policy`, `sandbox_mode`) 및 모델 설정
- `AGENTS.md`/`.agents/skills` 투영 구조
- `.agents/skills/*` 디렉토리 심링크 검증
- `nrs`(또는 동등 activation) 이후 결과 검증
- Claude Code와 Codex CLI 동작 차이 정리

Claude 전용 플러그인/훅 세부 내용은 `configuring-claude-code` 스킬을 사용합니다.

## 빠른 진단 체크리스트

1. `.agents/skills/*`이 디렉토리 심링크인지 확인 (`ls -la .agents/skills/`)
2. 프로젝트 루트 `AGENTS.md -> CLAUDE.md` 심링크 확인 (git-tracked)
3. `./scripts/ai/verify-ai-compat.sh` 실행
4. `codex exec`로 런타임에서 스킬 이름이 보이는지 확인
5. 권한 프롬프트 이슈는 `approval_policy`, `sandbox_mode` 설정으로 분리 진단

## 핵심 파일

- `libraries/packages/codex-cli.nix` — Nix 패키지 (pre-built 바이너리)
- `modules/shared/programs/codex/default.nix` — 설정 및 스킬 투영
- `modules/shared/programs/codex/files/config.toml` — 실행 정책/모델 설정
- `scripts/update-codex-cli.sh` — 버전 자동 업데이트
- `scripts/ai/verify-ai-compat.sh` — 구조 검증
- `.claude/skills/*` (원본)
- `.agents/skills/*` (Codex 발견용 투영)

## 패키지 설치 및 업데이트

Codex CLI는 Nix derivation으로 관리된다 (`libraries/packages/codex-cli.nix`).
GitHub releases에서 플랫폼별 pre-built 바이너리를 가져온다.

- macOS: `aarch64-darwin`
- NixOS: `x86_64-linux` (musl 정적 링크)

### 자동 업데이트 (nrs 통합)

`nrs` 실행 시 빌드 전에 `scripts/update-codex-cli.sh`가 자동으로 실행된다.

```
nrs 흐름:
  update_external_packages   ← GitHub latest 확인 → codex-cli.nix 갱신
    ↓
  (launchd 정리, macOS만)
    ↓
  preview_changes            ← 갱신된 버전으로 빌드
    ↓
  rebuild switch
```

동작 방식:
- 버전 동일: curl HEAD 1회로 종료 (~1초 이내, 빌드 시간 영향 거의 없음)
- 새 버전: `nix-prefetch-url`로 tarball 2개 다운로드 후 해시 계산 → nix 파일 갱신 (30-90초 소요)
- `nrs --offline`: 업데이트 단계 건너뜀
- 네트워크 오류: 경고 출력 후 기존 버전으로 빌드 계속 (non-fatal)
- 태그 형식 변경(`rust-v*` 외): semver 검증 실패로 중단, 기존 버전으로 빌드 계속

안전장치:
- curl `--connect-timeout 5 --max-time 10` (무한 대기 방지)
- 파일 수정 전 `.bak` 백업, EXIT trap으로 실패/중단 시 자동 복원

### 수동 업데이트

```bash
./scripts/update-codex-cli.sh
```

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

- 상세 장애 기록 및 회귀 체크: `references/runbook-codex-compat-2026-02-08.md`
