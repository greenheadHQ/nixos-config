# Plan 006: gitleaks의 `.local.md` 경로 전면 예외를 제거하고 gitignore로 대체한다

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. When done, update the status row in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat fb2a8aa6..HEAD -- .gitleaks.toml .gitignore`
> 변경이 있으면 "Current state"와 대조하고, 불일치 시 STOP.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `fb2a8aa6`, 2026-07-02
- **Issue**: https://github.com/greenheadHQ/nixos-config/issues/943

## Why this matters

`.gitleaks.toml`의 allowlist가 `.local.md`에 매칭되는 **모든 파일을 시크릿
스캔에서 통째로 제외**한다. 그런데 `.gitignore`에는 `*.local.md` 패턴이 없어서
(글로벌 gitignore 여부는 Step 1에서 실측), 로컬 메모를 `something.local.md`로
실수 커밋하면 그 안의 실토큰/비밀번호를 gitleaks pre-commit·CI가 전혀 잡지
못한다. 경로 단위 전면 예외는 개별 오탐 억제(라인/규칙 단위)보다 은폐 표면이
훨씬 넓다. 현재 추적 중인 `*.local.md` 파일은 없으므로(예방적 예외) 지금
제거해도 아무것도 깨지지 않는다 — "추적 금지(gitignore) + 스캔 유지(gitleaks)"
조합으로 바꾼다.

## Current state

- `.gitleaks.toml` (전문이 짧다):

```toml
title = "nixos-config gitleaks configuration"

[extend]
useDefault = true

[allowlist]
paths = [
  '''flake\.lock''',
  '''\.local\.md''',
]
```

- `.gitignore` — `*.local.md` 항목 없음 (nix/direnv/codex 관련 항목 위주).
- `.gitleaksignore` — 문서 예시 키 3건만 (understanding-nix 스킬 문서) — 건드리지 않는다.
- gitleaks는 pre-commit에서 `scripts/ai/run-gitleaks-staged-policy.sh` 경유로
  staged snapshot에 대해 실행된다 (README "검증 / 훅" 절).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| 추적 파일 확인 | `git ls-files \| grep -c '\.local\.md$'` | `0` (exit 1) |
| 글로벌 ignore 확인 | `git check-ignore -v test.local.md` (저장소 루트에서) | Step 1에서 해석 |
| gitleaks 정책 실행 | `git add -A` 후 커밋 시 pre-commit 훅 자동 실행 | 통과 |
| 통합 테스트 | `bash tests/run-all-tests.sh` | 전부 통과/SKIP |

## Scope

**In scope**:
- `.gitleaks.toml` (allowlist paths에서 `'''\.local\.md'''` 한 줄 제거)
- `.gitignore` (`*.local.md` 항목 추가 — Step 1 결과에 따라)

**Out of scope** (do NOT touch):
- `'''flake\.lock'''` 예외 — lock 파일 해시 오탐 방지용으로 정당하다.
- `.gitleaksignore` — 문서 예시 키 예외는 라인 단위라 올바른 패턴이다.
- `scripts/ai/run-gitleaks-staged-policy.sh` — 정책 러너 로직 변경 불필요.

## Git workflow

- Branch: `advisor/006-gitleaks-local-md`
- Commit 예: `fix(security): gitleaks .local.md 전면 예외 제거 — gitignore로 대체`
- Push/PR은 운영자 지시가 있을 때만.

## Steps

### Step 1: 글로벌 gitignore가 이미 `*.local.md`를 차단하는지 실측

저장소 루트에서 `touch test.local.md && git check-ignore -v test.local.md; rm test.local.md`
를 실행한다.

- 이미 무시된다면(글로벌 ignore 매칭 출력): `.gitignore` 수정은 불필요 —
  Step 2에서 `.gitleaks.toml`만 고치고, 그 사실을 최종 보고에 기록한다.
- 무시되지 않는다면: `.gitignore` 끝에 주석과 함께 추가한다:

```gitignore
# 로컬 전용 메모 (시크릿 포함 가능 — 추적 금지. gitleaks 스캔 예외는 두지 않는다)
*.local.md
```

**Verify**: `touch t.local.md && git check-ignore t.local.md && rm t.local.md` → exit 0 (무시됨)

### Step 2: .gitleaks.toml에서 `.local.md` 경로 예외 제거

`paths` 배열에서 `'''\.local\.md''',` 한 줄을 삭제한다. `flake\.lock`은 유지.

**Verify**: `grep -c "local" .gitleaks.toml` → `0` (exit 1)

### Step 3: 게이트 통과 확인

**Verify**: `bash tests/run-all-tests.sh` → 전부 통과/SKIP.
커밋 시 pre-commit gitleaks 훅 통과.

## Test plan

설정 파일 변경이라 신규 테스트 없음. 검증은 Done criteria의 grep +
pre-commit gitleaks 실행으로 갈음.

## Done criteria

- [ ] `grep -n "local.md" .gitleaks.toml` → 0건 (exit 1)
- [ ] `touch t.local.md && git check-ignore t.local.md; rm t.local.md` → exit 0
- [ ] `git ls-files | grep '\.local\.md$'` → 0건
- [ ] `bash tests/run-all-tests.sh` → exit 0
- [ ] 커밋이 pre-commit(gitleaks 포함)을 우회 없이 통과
- [ ] `plans/README.md` 상태 행 갱신

## STOP conditions

- `git ls-files`에 `.local.md` 추적 파일이 존재한다 (전제 붕괴 — 그 파일 내용
  검토가 먼저다. **파일 내용을 이슈/plan에 인용하지 말 것** — 시크릿일 수 있다).
- 예외 제거 후 pre-commit gitleaks가 기존 추적 파일에서 새 오탐/정탐을 낸다 —
  무엇이 걸렸는지 파일 경로와 규칙 ID만 보고 (매칭된 값 자체는 절대 인용 금지).

## Maintenance notes

- 향후 gitleaks 오탐이 생기면 경로 전면 예외가 아니라 `.gitleaksignore`의
  라인 단위 예외(기존 3건과 같은 형식)로 좁혀 추가하는 것이 이 저장소의 패턴.
- 리뷰어는 diff가 정확히 두 파일(또는 글로벌 ignore가 있으면 한 파일)인지 확인.
