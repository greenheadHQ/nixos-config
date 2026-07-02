# Plan 018: 에이전트 하네스(스킬·훅·감사 워크플로)의 추출 가능성을 판정한다 (spike)

> **Executor instructions**: 이것은 **조사(spike) plan이다 — 소스 코드를 일절
> 수정하지 않는다**. 산출물은 결합도 조사 보고서 하나이며, **"추출 안 함"
> 결론도 유효한 산출물이다**. Follow this plan step by step. If anything in
> the "STOP conditions" section occurs, stop and report. When done, update
> the status row in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat fb2a8aa6..HEAD -- .claude/skills/ scripts/ai/ modules/shared/programs/claude/ modules/shared/programs/codex/`
> 대규모 변경이 있으면 조사 대상 스냅샷이 달라진 것 — 그대로 진행하되
> 보고서에 조사 기준 커밋을 명기한다.

## Status

- **Priority**: P3
- **Effort**: M (조사만 — build 아님)
- **Risk**: LOW (읽기 전용)
- **Depends on**: none
- **Category**: direction
- **Planned at**: commit `fb2a8aa6`, 2026-07-02
- **Issue**: https://github.com/greenheadHQ/nixos-config/issues/955

## Why this matters

이 저장소의 스킬(30+개)·LLM 훅(pinning/fragile-hardcoding 등)·감사 워크플로
(run-da/parallel-audit)·검증 인프라(verify-ai-compat, lefthook 배선)는 사실상
**에이전트 개발 프레임워크**로 성장했지만, nixos-config 도메인과 강결합되어
다른 리포/사용자가 재사용할 수 없다. epic #912가 이를 "향후 고려 — 하네스
추출 spike"로 명시하되 "도메인 결합도가 높아 일반화 비용이 크므로 build가
아닌 design/spike로 다룬다"고 한정했다 (gh issue #912 본문). 이 plan은 그
한정을 존중한다: 결합도를 실측으로 맵핑하고, 가장 도메인-중립적인 후보 1곳의
추출 경계를 시제(paper prototype — 코드 아님)하고, **추출할 가치가 있는지
판정**한다. 부정적 결론이면 이 주제를 근거와 함께 종결하는 것이 산출물이다.

## Current state

조사 대상 (전부 **읽기 전용**):

- `.claude/skills/` — 스킬 30+개 (`.agents/skills/`는 여기로의 심링크).
- `modules/shared/programs/claude/files/hooks/` + `files/lib/`
  (hook-runtime.sh, pinning-patterns.sh) — claude 훅 런타임.
- `modules/shared/programs/codex/` — codex 하네스 (config sync, 훅 투영).
- `scripts/ai/` — lefthook 게이트들 (verify-ai-compat 1620줄,
  run-staged-snapshot, install-lefthook-hooks 등).
- `tests/` — shell/pytest/bats 하네스 + `tests/lib/test-common.sh`.
- epic #912 본문 원문 (gh 실측): "스킬·훅·감사 워크플로가 사실상 에이전트
  개발 프레임워크로 성장했으나 재사용 가능한 형태로 분리돼 있지 않다. 도메인
  결합도가 높아 일반화 비용이 크므로 build가 아닌 design/spike로 다룬다."
- 참고 결합 신호 (감사에서 관찰): 훅이 저장소 고유 경로/컨벤션(SKILL.md 패턴,
  worktree 구조)을 하드 참조; 스킬 문서가 constants.nix·homeserver 옵션을
  인용; verify-ai-compat이 이 리포의 배치 규약(oracle 공유, 심링크 suffix)을
  검증.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| 도메인 참조 밀도 | `grep -rln "nixos-config\|greenhead\|minipc\|homeserver" <후보 디렉토리>` | 결합 지점 목록 |
| 역참조 | `grep -rn "<후보 파일명>" lefthook.yml modules/ scripts/ tests/` | 배선 지점 |
| epic 원문 | `gh issue view 912 --json body` | "향후 고려" 절 |

## Scope

**In scope** (생성 가능한 파일 — 이 하나뿐):
- `plans/018-findings-harness-extraction.md` (신규 — 조사 보고서)

**Out of scope** (do NOT touch):
- 소스/스킬/훅 수정 일체. 별도 리포 생성, 코드 추출 시제 구현도 금지 —
  경계 설계는 **문서로만**.
- 추출 "실행" 계획 상세화 — 판정이 긍정일 때 후속 plan의 몫.

## Git workflow

- Branch: `advisor/018-harness-extraction-spike`
- Commit 예: `docs(plans): 하네스 추출 가능성 조사 보고서`
- Push/PR은 운영자 지시가 있을 때만.

## Steps

### Step 1: 하네스 구성요소 인벤토리와 결합도 맵

구성요소를 4계층으로 나눠 표를 만든다 — ① 훅 런타임(hook-runtime,
pinning-patterns) ② 게이트 스크립트(scripts/ai/*) ③ 스킬 본문
(.claude/skills/*) ④ 테스트 하네스(tests/lib 등). 각 항목에: 도메인 참조
개수(grep 실측), 참조의 성격(경로 하드코딩 / 컨벤션 의존 / 순수 범용),
추출 시 필요한 매개변수화 규모(S/M/L 직감 표기).

**Verify**: 표의 도메인 참조 수가 grep 명령과 함께 기록됨 (재현 가능).

### Step 2: 최우수 후보 1곳의 추출 경계 시제 (문서로)

Step 1에서 가장 도메인-중립적인 후보(예상: 훅 런타임 계층 또는
tests/lib/test-common.sh — 실측으로 확정)를 골라, 문서로만: 공개 인터페이스
초안 / 남는 도메인 결합 지점과 매개변수화 방법 / 이 리포가 소비자가 되는
구조(서브모듈? flake input? 복사-동기화?)의 후보별 유지보수 비용.

**Verify**: 경계 시제 절에 인터페이스 초안과 소비 구조 후보 ≥2개 존재.

### Step 3: 판정

세 결론 중 하나를 근거와 함께: ① 추출 가치 있음(후보·경계·다음 단계 명시)
② 가치 없음 — 종결(근거: 소비자 부재/결합 비용/유지보수 표면 확대. 이 경우
plans/README.md의 rejected 절에 옮겨 재감사를 방지) ③ 조건부(어떤 외부
수요가 생기면 재검토 — 트리거 명시). 판정 기준에 "단일 사용자 리포에 즉효
이득이 없다(YAGNI)"는 epic의 신중론을 반영할 것.

**Verify**: 보고서에 판정 1개 + 근거 + (해당 시) 재검토 트리거 존재.

## Test plan

코드 변경 없음. 품질 게이트: 모든 결합도 주장이 grep 실측(명령 병기)으로
뒷받침됨.

## Done criteria

- [ ] `test -f plans/018-findings-harness-extraction.md` → exit 0
- [ ] 보고서에 4계층 결합도 표 / 후보 1곳 경계 시제 / 판정 절 존재
- [ ] `git diff --stat` → 변경이 `plans/` 아래에만
- [ ] `plans/README.md` 상태 행 갱신 (판정이 "종결"이면 rejected 절에도 반영)

## STOP conditions

- 조사 중 하네스에 이미 진행 중인 추출/분리 작업의 흔적(브랜치, PRD, 이슈)을
  발견한다 — 중복 조사를 멈추고 그 작업과의 관계를 보고.
- epic #912 본문을 확인할 수 없다 (gh 실패).

## Maintenance notes

- 판정이 ①이어도 build 착수는 운영자 결정 사항이다 — 이 spike의 산출물은
  옵션이지 약속이 아니다.
- 판정이 ②(종결)면 이 주제가 다음 감사에서 재발굴되지 않도록
  plans/README.md rejected 절 기록까지가 완결이다.
