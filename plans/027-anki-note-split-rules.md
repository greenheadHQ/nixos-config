# Plan 027: 비대 노트를 "복습에서 걸린 것부터" 점진 분할하는 운영 절차를 수립한다

> **Executor instructions**: 이 plan의 산출물은 (1) 운영 절차 문서
> `anki-study/CARD_MAINTENANCE.md` 신설(에이전트, repo 커밋)과 (2) 첫 1회
> 분할 배치의 시범 실행(운영자 승인 게이트 포함)이다. **에이전트는 승인 없이
> Anki 노트를 생성·수정·삭제하지 않는다.** STOP conditions 발생 시 중단·보고.
> 완료 시 `plans/README.md` 갱신.
>
> **Drift check (run first)**:
> `git diff --stat a19daba3..HEAD -- anki-study/` — anki-study 구조가 바뀌었으면
> Current state와 대조. `ls anki-study/CARD_MAINTENANCE.md 2>/dev/null` — 이미
> 존재하면 STOP (이 plan이 이미 실행됨).

## Status

- **Priority**: P2
- **Effort**: M (절차 문서 S + 시범 배치 1회 M)
- **Risk**: MED (노트 분할은 원본 카드의 스케줄 이력과 새 카드의 관계를 끊는다 — 원본 보존 원칙으로 방어)
- **Depends on**: plans/025-anki-restart-protocol.md (hard — 규칙 3의 깃발 큐가 이 절차의 입력이다. 복습이 돌기 전에는 처리할 대상 자체가 없다)
- **Category**: direction (학습 품질)
- **Planned at**: commit `a19daba3`, 2026-07-05
- **Issue**: https://github.com/greenheadHQ/nixos-config/issues/977 (epic #973)

## Why this matters

컬렉션 노트의 48%(386개)가 2,000자를 넘고(최대 18,011자), "거대 컨텍스트 +
cloze 1개" 노트가 654개다 — 카드 1장을 복습하려면 책 반 페이지를 다시 읽어야
하는 구조로, 리뷰당 시간을 폭증시켜 이탈 사이클(2회 붕괴)의 구조적 원인이
됐다. 선행 프로젝트 awesome-anki 1.0이 정확히 이 문제("비대한 노트 쪼개기")를
풀려다 **도구 개발에 빠져 학습 0회로 망했다** (issue #711 회고). 따라서 이
plan은 의도적으로 도구를 만들지 않는다 — 전면 리팩토링 대신 "복습에서 실제로
걸린 카드만, 주 1회, 사람이 승인하며" 처리하는 **절차**만 수립한다. 386개를
다 고치는 게 목표가 아니라, 매주 복습이 조금씩 덜 아파지는 것이 목표다.

## Current state

- 노트 flds 길이: median 1,922자 / p90 4,403 / max 18,011 (HTML 포함, 2026-07-05
  실측 — `plans/anki-audit-evidence/2026-07-05-audit.md`).
- 지배적 notetype: `KaTeX and Markdown Cloze` (749/811 노트). 필드: `Text`,
  `Back Extra`. cloze 1개짜리가 654노트.
- 노트 상호 링크: Anki Note Linker 애드온 사용 중 (`[표시명|nidXXXX]` 문법이
  기존 노트에 실재 — 분할 시 이 링크 문법으로 원본↔파생 연결 가능).
- plan 025 Step 2 규칙 3이 확립하는 입력: 복습 중 걸린 비대 카드에 **파란
  깃발(Flag 1)** — 검색 문법 `flag:1`.
- AnkiConnect(localhost:8765) 활성 — `findNotes`/`notesInfo`(조회),
  `addNotes`/`suspend`(변경, **운영자 승인 후에만**) 사용 가능.
- 학습 원칙 SSOT: `anki-study/GUIDE.md` §3 (팩트체크 의무, YAGNI 필터링 등) —
  분할 시 새 노트에도 같은 원칙 적용.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| 깃발 큐 조회 | `curl -s localhost:8765 -X POST -d '{"action":"findNotes","version":6,"params":{"query":"flag:1"}}'` | `{"result":[nid…],"error":null}` |
| 노트 내용 조회 | `curl -s localhost:8765 -X POST -d '{"action":"notesInfo","version":6,"params":{"notes":[<nid>]}}'` | fields.Text 등 반환 |
| repo 게이트 | `bash tests/run-all-tests.sh` | FAILED 0 |

## Scope

**In scope**:

- `anki-study/CARD_MAINTENANCE.md` 신설 (아래 Step 1의 내용이 곧 파일 본문)
- 깃발 큐 기반 시범 분할 배치 1회 (노트 1~3개, 운영자 승인 게이트)

**Out of scope** (건드리지 말 것):

- 386개 비대 노트의 일괄/자동 분할 — **명시적 금지** (awesome-anki 1.0 함정)
- 분할 도구/스크립트/애드온 개발 — 절차는 기존 AnkiConnect API 호출과 채팅
  승인으로만 구성
- 원본 노트 **삭제** — 분할 후 원본은 suspend만 (스케줄 이력·미디어 참조 보존)
- notetype/템플릿 변경, `🚧 일시중단::*` 덱

## Git workflow

- Branch: `docs/anki-card-maintenance-procedure`
- Conventional commits (예: `docs(anki-study): 비대 노트 점진 분할 절차 신설`)
- push/PR 생성은 운영자 지시 없이는 하지 않는다.

## Steps

### Step 1 (에이전트): CARD_MAINTENANCE.md 작성

`anki-study/CARD_MAINTENANCE.md`를 신설하고 아래 절차를 기록한다 (이 목록이
파일의 요구 내용이다 — 문구는 다듬되 규칙의 실질을 바꾸지 말 것):

1. **트리거**: 주 1회(주말 권장), `flag:1` 큐가 1개 이상일 때만. 큐가 비면
   그 주는 건너뛴다. 한 번에 최대 3노트 — 그 이상은 다음 주로.
2. **분할 원칙** (노트당):
   - 원 노트에서 **시험 가능한 최소 사실 단위**를 추출해 각각 새 노트로.
     기준: 새 노트의 Text가 질문 맥락 포함 600자 이내, cloze는 노트당
     1~2개, "왜/어떻게" 통찰은 Back Extra로.
   - `anki-study/GUIDE.md` §3의 팩트체크·YAGNI 원칙을 새 노트에 적용 —
     원 노트의 모든 문장을 카드화하지 않는다 (YAGNI 제외분은 버린다).
   - 새 노트에 원본 링크: Note Linker 문법 `[원본|nid<원본nid>]`를 Back Extra
     끝에 추가. 태그 `split-from-original` 부여 (추적용).
   - notetype은 기존 `KaTeX and Markdown Cloze` 유지. 새 notetype 금지.
3. **실행 흐름**: LLM이 `findNotes flag:1` → `notesInfo`로 원문 확보 →
   분할안(새 노트 N개의 전체 필드 내용)을 채팅으로 제시 → **운영자 승인** →
   `addNotes`로 추가 + 원본 노트의 카드 suspend + 원본 깃발 해제 →
   운영자가 다음 복습에서 새 카드 품질 확인.
4. **금지**: 원본 삭제, 승인 없는 add/suspend, 주당 3노트 초과, 새 도구 제작.
5. **종료 조건**: 4주 연속 깃발 큐가 비면 이 절차는 휴면 — 비대 노트가 더
   이상 복습을 막지 않는다는 뜻이다 (386개를 다 쪼개는 것이 목표가 아님).

**Verify**: 파일 존재 + `bash tests/run-all-tests.sh` FAILED 0 +
`git diff --stat` → `anki-study/CARD_MAINTENANCE.md`만 추가.

### Step 2 (에이전트+운영자): 시범 배치 1회

plan 025 재시작 후 첫 깃발이 쌓인 시점에 (보통 1~2주 뒤):

1. `findNotes flag:1` 로 큐 확인. 0개면 이 Step은 다음 주로 연기 (plan status
   IN PROGRESS 유지).
2. 큐에서 1~3개를 CARD_MAINTENANCE.md 절차대로 처리 — 분할안 제시 →
   운영자 승인 → 반영.
3. 처리 결과(원본 nid, 새 노트 수, 승인/반려 내역)를 보고.

**Verify**: `findNotes "tag:split-from-original"` → 새 노트 nid ≥ 1개.
원본 노트의 카드가 suspended 상태 (`findCards "nid:<원본nid>"` 후
`cardsInfo`에서 queue=-1).

### Step 3 (운영자): 절차 확정

시범 배치의 새 카드를 실제 복습에서 1회 이상 만난 뒤, 절차 유지/수정을 결정.
수정 사항이 있으면 CARD_MAINTENANCE.md에 반영(에이전트) 후 이 plan을 DONE 처리.

**Verify**: 운영자의 명시적 확정 답변.

## Test plan

운영 절차 수립이라 자동 테스트 없음. Step 2의 시범 배치가 절차의 통합
테스트다: 큐 조회 → 분할안 → 승인 → 반영 → 검색 검증 전 과정이 1회 왕복.

## Done criteria

- [ ] `anki-study/CARD_MAINTENANCE.md` 존재, Step 1의 규칙 1~5 전부 포함
- [ ] `bash tests/run-all-tests.sh` FAILED 0
- [ ] 시범 배치 1회 완료: `tag:split-from-original` 노트 ≥ 1, 해당 원본 suspended·깃발 해제
- [ ] 원본 노트 삭제 0건 (절차 전체에서)
- [ ] 운영자의 절차 확정 답변 기록
- [ ] `plans/README.md` 027 행 갱신

## STOP conditions

- plan 025가 착수 전이거나 깃발 규칙(Step 2 규칙 3)이 합의되지 않음 — 입력
  큐가 정의되지 않은 상태로 진행 불가 (hard dependency).
- 운영자가 시범 분할안을 2회 연속 전면 반려 — 분할 기준 자체가 어긋난 것이므로
  기준 재논의 먼저.
- AnkiConnect `addNotes`가 KaTeX and Markdown Cloze notetype에서 오류 반환 —
  notetype 필드 계약 확인 먼저, 우회 시도 금지.
- "이왕 하는 김에" 큐 밖의 비대 노트를 처리하고 싶어지는 상황 — 하지 않는다.
  그것이 awesome-anki 1.0이 죽은 방식이다.

## Maintenance notes

- 이 절차가 자리잡은 뒤 자동화 욕구가 생기면 (예: 분할안 사전 생성), plan 025
  규칙 6과 같은 게이트를 적용할 것: 4주 이상 절차가 수동으로 지속된 후에만 논의.
- Note Linker 애드온이 제거되면 `[…|nid…]` 링크 문법이 렌더링되지 않는다 —
  plan 026에서 이 애드온은 "건드리지 않음" 목록에 있음을 유지할 것.
- FSRS 관점: 분할된 새 노트는 new 카드로 들어간다 — plan 025의 New cards/day
  상한(백로그 소진 전 0)에 걸리므로, 시범 배치 시기에 상한이 0이면 새 카드
  소화를 위해 일시적으로 5로 올리는 것을 운영자에게 안내.
