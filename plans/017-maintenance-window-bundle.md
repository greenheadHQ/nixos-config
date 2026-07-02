# Plan 017: 다음 유지보수 창을 "복원 드릴 + #917 실경로 + DB 마이그레이션" 묶음으로 정의한다

> **Executor instructions**: 이것은 **운영 절차 정의 plan이다 — 소스 코드를
> 일절 수정하지 않는다**. 산출물은 유지보수 창 실행 계획서(체크리스트) 파일
> 하나다. Follow this plan step by step. If anything in the "STOP conditions"
> section occurs, stop and report. When done, update the status row in
> `plans/README.md`.
>
> **Drift check (run first)**:
> `gh issue view 917 --json state -q .state` → `OPEN`이 아니면 STOP (전제 변화).

## Status

- **Priority**: P3
- **Effort**: S (계획서 작성만 — 실행은 운영자가 창에서)
- **Risk**: LOW (문서만; **실행 자체는 MED-HIGH** — 계획서가 그 리스크를 관리)
- **Depends on**: plans/005-pgvecto-rs-migration-spike.md,
  plans/016-backup-posture-spike.md (두 spike 보고서의 산출물을 입력으로
  사용 — 둘 다 DONE 후 착수)
- **Category**: direction
- **Planned at**: commit `fb2a8aa6`, 2026-07-02
- **Issue**: https://github.com/greenheadHQ/nixos-config/issues/954

## Why this matters

서로 다른 세 blocked/대기 작업이 **같은 전제 — 실서비스를 만지는 유지보수
창 — 를 공유**한다: ① 백업 복원 드릴(한 번도 안 해봄 — plan 016이 정의),
② 이슈 #917 update-script 통합의 실경로 검증(자율 주행이 "실제 서비스
업데이트 = 데이터 정합성 위험"으로 BLOCKED 처리, 정밀 plan은 #917 코멘트에
인계됨 — gh 실측: OPEN, 코멘트 3건), ③ Immich DB(pgvecto-rs→VectorChord)
마이그레이션(plan 005 spike가 절차를 설계). 창을 따로 세 번 잡으면 각각
서비스 중단·리스크 관리·검증을 반복한다. 한 창에 묶되 **순서를 고정**(드릴
먼저 → 백업 신뢰 확보 후 위험 작업)하면 창 하나로 세 작업이 끝나고, 실패 시
원인 분리도 순서가 보장한다. 이 plan은 그 창의 실행 계획서를 만든다.

## Current state

- `EPIC-912-LIVING-PRD.md` §8 (로컬 문서, git 미추적):
  #917 BLOCKED — "실경로 검증(실제 서비스 업데이트=데이터 정합성 위험)이
  유지보수 창 필요로 자율 불가. 정밀 plan+베이스라인+절차를 이슈 #917 코멘트에
  인계."
- gh 실측: 이슈 #917 OPEN
  (`refactor(nixos): update-script.sh 4개 서비스 골격 중복 통합`), 코멘트 3건.
- 입력 산출물 (착수 시점에 존재해야 함):
  - `plans/005-findings-pgvecto-rs.md` — DB 마이그레이션 절차/롤백/창 요구
  - `plans/016-findings-backup-posture.md` — 복원 드릴 절차/성공 기준
  - 이슈 #917 코멘트의 인계 plan — 실경로 검증 절차/베이스라인
- 실행 환경 사실: 대상 호스트는 `greenhead-minipc`(NixOS), 서비스는
  Immich/Karakeep/Copyparty/Uptime Kuma (podman), 알림은 Pushover.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| #917 인계 plan 읽기 | `gh issue view 917 --comments` | 인계 절차 확보 |
| 입력 보고서 확인 | `test -f plans/005-findings-pgvecto-rs.md -a -f plans/016-findings-backup-posture.md` | exit 0 |

## Scope

**In scope** (생성 가능한 파일 — 이 하나뿐):
- `plans/017-maintenance-window-runbook.md` (신규 — 창 실행 계획서)

**Out of scope** (do NOT touch):
- 소스 코드/서비스 조작 일체 — 실행은 운영자가 창에서 한다.
- #917 구현 자체 — 기존 인계 plan을 **재작성하지 않는다** (참조만).
- 창 일정 결정 — 운영자 몫.

## Git workflow

- Branch: `advisor/017-maintenance-window-bundle`
- Commit 예: `docs(plans): 유지보수 창 3작업 묶음 실행 계획서`
- Push/PR은 운영자 지시가 있을 때만.

## Steps

### Step 1: 세 입력의 창 요구사항 취합

#917 코멘트 인계 plan, plans/005·016 보고서에서 각 작업의 ① 사전 조건
② 예상 소요 ③ 서비스 중단 범위 ④ 롤백 조건을 추출해 표로 만든다.

**Verify**: 표에 세 작업 각각 4개 항목이 채워짐 (출처 명시).

### Step 2: 실행 계획서 작성

`plans/017-maintenance-window-runbook.md`에:

1. **고정 순서와 근거**: ① 복원 드릴(백업 신뢰 확보 — 실패 시 이후 작업
   전면 중단) → ② DB 마이그레이션(가장 위험 — 방금 검증한 백업이 롤백 재료)
   → ③ #917 실경로 검증(마이그레이션 후의 새 DB 이미지 기준으로 검증해야
   이중 작업이 없음). 이 순서가 다르게 나와야 할 근거를 입력 보고서에서
   발견하면 그 근거와 함께 조정.
2. 작업별 체크리스트: 시작 조건 → 절차(입력 문서의 해당 절 링크 + 요약) →
   성공 기준 → 실패 시 행동(중단/롤백/다음 작업 진행 여부 매트릭스).
3. 전체 창 요구: 예상 총 소요, 시작 전 스냅샷/백업 목록, 종료 후 확인 목록
   (각 서비스 헬스체크 + Pushover 왕복).
4. 중단 결정 규칙: 어느 단계 실패가 창 전체 중단인지 명시 (예: 드릴 실패 →
   전면 중단, #917 검증 실패 → 해당 작업만 롤백하고 창 종료).

**Verify**: `grep -c '^## \|^### ' plans/017-maintenance-window-runbook.md` ≥ 6

### Step 3: 재개 트리거 기록

계획서 상단에 "이 창의 실행이 이슈 #917의 재개 트리거"임을 명시하고, 운영자가
창을 잡으면 이 계획서를 따라 실행함을 기록한다.

**Verify**: 계획서에 #917 참조와 트리거 문구 존재.

## Test plan

코드 변경 없음. 품질 게이트: 계획서의 모든 절차 항목이 세 입력 문서 중
하나를 출처로 가짐 (창작 절차 금지).

## Done criteria

- [ ] `test -f plans/017-maintenance-window-runbook.md` → exit 0
- [ ] 계획서에 고정 순서+근거 / 작업별 체크리스트 / 중단 결정 규칙 존재
- [ ] 모든 절차 항목에 출처(#917 코멘트 / plans/005 / plans/016) 표기
- [ ] `git diff --stat` → 변경이 `plans/` 아래에만
- [ ] `plans/README.md` 상태 행 갱신

## STOP conditions

- 입력 보고서(005·016) 중 하나라도 없다 — 의존성 미충족, 창작으로 채우지
  말 것.
- #917이 CLOSED이거나 코멘트의 인계 plan을 찾을 수 없다.
- 세 작업의 창 요구가 상호 모순된다 (예: 마이그레이션이 요구하는 중단 시간이
  드릴 전제와 충돌) — 조정안을 만들지 말고 모순을 보고.

## Maintenance notes

- 창 실행 후 결과(성공/부분 실패)를 이 계획서에 추기하고, #917과 관련 plan
  들의 상태를 갱신하는 것까지가 창의 마무리다.
- 창에서 얻는 실측(복원 소요 시간, 마이그레이션 다운타임)은 plan 016 후속
  구현의 입력이 된다 — 기록을 남길 것.
