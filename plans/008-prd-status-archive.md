# Plan 008: 완료된 PRD의 상태를 정정하고 아카이브 관례를 적용한다

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. When done, update the status row in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat fb2a8aa6..HEAD -- .claude/prds/`
> 변경이 있으면 "Current state"와 대조하고, 불일치 시 STOP.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: docs
- **Planned at**: commit `fb2a8aa6`, 2026-07-02
- **Issue**: https://github.com/greenheadHQ/nixos-config/issues/945

## Why this matters

`.claude/prds/`는 살아있는 작업 문서(SSOT)를 두는 곳인데, 완료된 PRD가
정리되지 않아 신호가 희석되어 있다. 특히 최대 PRD(1Password 마이그레이션)는
마스터 상태가 "In Progress / Phase 4 PR 대기"로 남아 있지만 **실제로는 그 PR
(#856)이 2026-05-26에 머지됐고 epic #780도 CLOSED다** (gh 실측). 단일
메인테이너의 에이전트가 이 SSOT를 읽으면 "미완의 마이그레이션이 남았다"고
오판한다. 나머지 5건은 자체 Status가 Complete인데 활성 디렉토리에 남아 있다.
상태를 사실에 맞게 정정하고, 완료분을 아카이브로 옮겨 "활성 = 진행 중"이라는
디렉토리 의미를 복원한다.

## Current state

- Status 마커 실측 (`grep -Hn "^- Status:" .claude/prds/*.md`):

```
.claude/prds/prd-pinning-ssot-compatibility.md:4:- Status: Complete
.claude/prds/prd-codex-user-legacy-hooks.md:4:- Status: Complete
.claude/prds/prd-pinning-pretooluse-guard.md:4:- Status: Complete
.claude/prds/prd-1password-migration.md:5:- Status: In Progress
.claude/prds/prd-skill-router-consolidation.md:4:- Status: Complete
.claude/prds/prd-pwq-question-ux.md:5:- Status: In Progress   ← 실측 시 재확인 (아래 STOP 참조)
```

  주의: `prd-pwq-question-ux.md`는 감사 시점 grep에서 `Status: Complete`로
  확인됐다 — 실행 시점에 위 명령으로 **직접 재실측**하고 Complete인 것만
  아카이브 대상으로 삼는다.

- `prd-1password-migration.md:5-8` (stale 상태):

```
- Status: In Progress
- File Mode: Split
- Current Phase: Phase 1·2a·2b·3 merged (...) — Phase 4 GUI/박제 완료(PR 대기)만 잔여
- Last Updated: 2026-06-01
```

  교차 사실 (gh 실측 필요 — 아래 명령): PR #856
  `docs(prd): Phase 4 Apple Passwords import 완료...` → MERGED
  2026-05-26. epic #780 → CLOSED.

- 각 PRD는 같은 이름의 phase 파일 디렉토리를 동반할 수 있다
  (예: `prd-1password-migration/`).
- 아카이브 관례 위치: `docs/archive/` (기존 파일 2건 존재).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| 상태 재실측 | `grep -Hn "^- Status:" .claude/prds/*.md` | 실행 시점 사실 확보 |
| PR/epic 교차확인 | `gh pr view 856 --json state,mergedAt` / `gh issue view 780 --json state` | MERGED / CLOSED |
| 잔존 참조 확인 | `rg -l "prd-<이름>" --glob '!.claude/prds/**' --glob '!plans/**' .` | 이동 전 참조 파악 |
| 통합 | `bash tests/run-all-tests.sh` | 전부 통과/SKIP |

## Scope

**In scope**:
- `.claude/prds/prd-1password-migration.md` (Status/Current Phase/Last Updated 정정)
- Status: Complete인 PRD 파일 + 동반 디렉토리의 `docs/archive/prds/`(신규 디렉토리)로의 `git mv`

**Out of scope** (do NOT touch):
- PRD **본문 내용** 수정 — 상태 메타데이터만 고친다 (작업 history 보존).
- `prd-1password-migration.md`의 아카이브 이동 — 상태 정정으로 Complete가 되면
  이동 대상이 되지만, 이 plan에서는 **정정까지만** 하고 이동 여부는 최종 보고에
  운영자 판단 사항으로 남긴다 (직전까지 In Progress였던 문서라 참조가 살아있을
  수 있음).
  - **후속 이행**: 이후 이 관례에 맞춰 `docs/archive/prds/prd-1password-migration{.md,/}`로
    `git mv`했다. 아래 Step 1의 Verify 명령 경로도 그만큼 옮겨졌다.
- `docs/archive/`의 기존 파일 2건.

## Git workflow

- Branch: `advisor/008-prd-status-archive`
- Commit 예: `docs(prds): 완료 PRD 상태 정정 + 아카이브 이동`
- Push/PR은 운영자 지시가 있을 때만.

## Steps

### Step 1: 1Password PRD 상태 정정

gh로 교차 사실을 재확인한 뒤 `prd-1password-migration.md` 상단 메타데이터를
정정한다: `Status: Complete`, Current Phase 줄을 "전 Phase 종결 (Phase 4 PR
#856 merged 2026-05-26, epic #780 CLOSED)" 취지로, `Last Updated`를 작업일로.
Phase Index 표(176행 부근)의 Phase 4 행도 "Done (PR 대기)" → "Done (#856
merged)"로.

**Verify**: `grep -n "Status: Complete" .claude/prds/prd-1password-migration.md` → 1건

### Step 2: Complete PRD를 아카이브로 이동

1. `grep -Hn "^- Status:" .claude/prds/*.md`로 Complete 목록을 재실측한다.
2. `mkdir -p docs/archive/prds` 후, Complete인 각 `prd-X.md`와 동반 디렉토리
   `prd-X/`(존재 시)를 `git mv`로 `docs/archive/prds/`에 옮긴다.
3. 이동 전 `rg -l "prd-X" --glob '!.claude/prds/**' --glob '!plans/**' .`로 외부
   참조를 확인하고, 참조가 있으면 그 파일의 경로 문자열을 새 위치로 갱신한다
   (스킬 문서 등). 참조 갱신이 스킬/Codex 관련 경로를 건드리면 pre-commit
   `ai-skills-consistency`가 검사한다 — 통과해야 정상.

**Verify**: `grep -RHn "^- Status: Complete" .claude/prds/*.md 2>/dev/null` →
0건 (1Password PRD는 Step 1에서 Complete가 되므로, 운영자 판단 보류 대상으로
남긴 경우 그 1건만 남는 것이 정상 — 최종 보고에 명시)

### Step 3: 게이트 통과

**Verify**: `bash tests/run-all-tests.sh` → 전부 통과/SKIP. 커밋이 pre-commit
통과.

## Test plan

문서 이동/정정이라 신규 테스트 없음. 외부 참조 무결성은 Step 2-3의 rg 확인이
담당.

## Done criteria

- [ ] `grep -n "Status: In Progress" .claude/prds/*.md` → 0건
- [ ] `ls docs/archive/prds/` → 이동된 PRD 파일들 존재
- [ ] `rg -n "docs/archive/prds" --glob '!plans/**' .`로 갱신된 참조가 유효 경로를 가리킴 (이동 대상 참조가 있었던 경우)
- [ ] `bash tests/run-all-tests.sh` → exit 0
- [ ] `plans/README.md` 상태 행 갱신

## STOP conditions

- gh 교차확인 결과가 "Current state"와 다르다 (PR #856이 MERGED가 아니거나
  epic #780이 OPEN — 전제 붕괴).
- 어떤 PRD의 Status 마커가 Complete/In Progress 외의 값이거나 마커가 없다 —
  임의 해석하지 말고 보고.
- 이동 대상 PRD를 참조하는 외부 파일이 스킬 문서 이상으로 광범위하다
  (evals, 훅 스크립트 등 동작 코드가 경로를 읽는 경우) — 목록을 보고.

## Maintenance notes

- 앞으로 PRD가 Complete로 전환될 때 아카이브 이동까지가 종결 절차라는 관례가
  이 plan으로 생긴다 — 새 PRD 종결 시 같은 절차를 따를 것.
- 리뷰어는 `git log --follow`로 이동 파일의 히스토리 연속성이 유지되는지
  (git mv 사용 여부) 확인.
