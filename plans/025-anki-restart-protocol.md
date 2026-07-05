# Plan 025: 601장 백로그를 압도당하지 않고 소화하는 재시작 프로토콜을 설정한다

> **Executor instructions**: 운영자(사용자) GUI 절차 + 에이전트 검증 혼합 runbook.
> 에이전트는 AnkiConnect(localhost:8765, Anki 실행 중일 때)로 상태를 조회해
> 검증한다 — **조회(read) 액션만 사용하고 노트/카드를 변경하는 액션은 호출
> 금지**. STOP conditions 발생 시 중단·보고. 완료 시 `plans/README.md` 갱신.
>
> **Drift check (run first)**: 아래 "백로그 재확인" 명령으로 연체 규모를
> 재실측한다. 601±40장 범위를 크게 벗어나면 (운영자가 이미 소화 시작/대량
> 정리) Current state와 대조 후 수치만 갱신해 진행하되, 마지막 리뷰가
> 2026-06-01 이후라면 이미 재시작된 것이므로 STOP 후 상황 보고.

## Status

- **Priority**: P1
- **Effort**: S~M (설정은 S, 첫 2주 운영 관찰까지 M)
- **Risk**: LOW (스케줄 설정 변경만 — 카드 데이터 무변경. FSRS가 연체를 자동 반영하므로 파괴적 재스케줄 불필요)
- **Depends on**: plans/024-anki-ankiweb-cutover.md (soft — 데이터 안전망 확보 후 재시작 권장)
- **Category**: direction (학습 운영 설계)
- **Planned at**: commit `a19daba3`, 2026-07-05
- **Issue**: https://github.com/greenheadHQ/nixos-config/issues/975 (epic #973)

## Why this matters

마지막 리뷰가 2026-02-07 — 5개월 공백 후 활성 덱에 601장이 연체됐다(중앙값
205일). 과거 이력상 **무계획 재개→첫날 압도→재붕괴**가 이미 2회 반복된 패턴이다
(2024-06 월 890→33건 붕괴, 2025-12 재붕괴 — `plans/anki-audit-evidence/2026-07-05-audit.md`
월별 revlog). 반면 좋은 조건도 갖춰져 있다: FSRS-5 파라미터가 2026-07-05에
최적화됐고, Again률 12.3%로 기억 저변이 살아 있다. 필요한 것은 새 도구가 아니라
**하루 상한과 소화 순서를 스케줄러에 못 박는 것**이다. 이 plan이 끝나면 "Anki를
열었을 때 오늘 할 양"이 감당 가능한 고정값이 되고, 백로그는 수개월에 걸쳐
자동 소진된다.

## Current state

- 활성 덱 연체 601장: JS Deep Dive 291(중앙 292일) / 컴퓨터과학 221(중앙 167일)
  / 리눅스 30 / Type Challenge 36 / CSS 6 / SQL 1.
- new 카드 대기 64장 (JS Deep Dive 56, 컴퓨터과학 7, Type Challenge 1).
- deck preset은 "기본" 1개를 **전 덱이 공유**한다 (deck_config 테이블 실측).
  따라서 preset 수정 한 번이 전 덱에 적용된다.
- FSRS 활성 (`fsrs=true`), learning steps 1m/10m, load balancer 활성.
- `🚧 일시중단::*` 하위 5덱은 의도적 보류 — 이 plan에서 건드리지 않는다
  (suspend 누락 16장의 일관화는 plan 026).
- Anki 26.5의 관련 내장 기능 (애드온 불필요): 덱 옵션의 일일 상한(Daily limits),
  복습 정렬 순서(Display Order > Review sort order), Easy Days, FSRS의
  "데스크톱과 모바일 간 프리셋 공유".

**백로그 재확인** (에이전트 — Anki 실행 중일 때, 사본 기반 대안은 evidence 문서 참조):

```bash
for q in '"deck:*" is:due -is:suspended' '"deck:*" is:new -is:suspended -"deck:🚧 일시중단::*"'; do
  curl -s localhost:8765 -X POST -d "{\"action\":\"findCards\",\"version\":6,\"params\":{\"query\":\"$q\"}}" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d['result']) if d['error'] is None else f'ERROR: {d[\"error\"]}')"
done
```

기대(2026-07-05 기준): 첫 줄 ~601, 둘째 줄 ~64. AnkiConnect 연결 실패 시
Anki 실행 여부를 먼저 확인 (`pgrep -x Anki`).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| 연체/new 수 조회 | 위 "백로그 재확인" | 숫자 2줄, ERROR 없음 |
| 덱 preset 설정 조회 | `curl -s localhost:8765 -X POST -d '{"action":"getDeckConfig","version":6,"params":{"deck":"[책] 이것이 취업을 위한 컴퓨터 과학이다"}}'` | JSON에 `"rev": {"perDay": <값>…}` 포함 |
| 오늘 리뷰 수 | `curl -s localhost:8765 -X POST -d '{"action":"getNumCardsReviewedToday","version":6}'` | `{"result": <숫자>, "error": null}` |

## Scope

**In scope**:

- "기본" preset의 일일 상한/정렬 설정 변경 (운영자 GUI)
- 재시작 운영 규칙의 합의와 이 plan 파일에의 기록
- 첫 2주 지속 여부 확인 게이트

**Out of scope** (건드리지 말 것):

- **Set Due Date / Forget / 수동 재스케줄 일체** — FSRS는 연체 간격을 다음
  스케줄에 자동 반영한다. 파괴적 재스케줄은 revlog 기반 최적화를 오염시킨다.
- `🚧 일시중단::*` 덱의 unsuspend — 백로그 소진 전 학습량 추가 금지.
- 노트 내용 수정/분할 (plan 027), 애드온/문서 정리 (plan 026).
- 새 덱/노트 추가 운영 규칙 — 재시작 안정화(2주) 후 별도 논의.

## Steps

### Step 1 (운영자): "기본" preset에 재시작 상한 설정

Anki 데스크톱 → 아무 활성 덱의 톱니바퀴 → 옵션("기본" preset):

1. **Daily limits**: New cards/day = **0** (백로그 소진까지 신규 유입 차단),
   Maximum reviews/day = **40** (601장 ÷ 40 ≈ 15일 + 신규 due 합류분을
   고려하면 약 3~4주에 백로그 소진. 하루 40장 × 카드당 평균 ~30초면 20분 내외
   — 비대 노트가 많아 실제는 더 걸릴 수 있음을 감안한 보수값).
2. **Display Order > Review sort order** = **Descending retrievability**
   (기억이 아직 살아 있는 카드부터 구제 — FSRS 백로그 소화의 권장 정렬.
   완전히 잊은 카드는 어차피 relearn이므로 뒤로 미뤄도 손실이 없다).
3. 나머지 설정(learning steps 1m/10m, FSRS 파라미터)은 그대로 둔다 —
   2026-07-05 최적화본이다.

**Verify** (에이전트): `getDeckConfig` 조회 → `new.perDay: 0`, `rev.perDay: 40`
확인. (Review sort order는 AnkiConnect 응답에 노출되지 않을 수 있다 — 그 경우
운영자 화면 확인으로 갈음.)

### Step 2 (운영자+에이전트): 재시작 규칙 합의 — 이 섹션이 규칙 원문이다

아래 규칙을 운영자가 읽고 동의 여부를 답한다. 수정 요청이 있으면 이 plan
파일의 본 섹션을 갱신한다 (규칙의 SSOT는 이 파일).

1. **세션 단위**: 하루 1세션, 상한 도달 또는 25분 중 먼저 오는 쪽에서 끝.
   더 하고 싶어도 안 한다 (초반 과열→이탈이 기존 붕괴 패턴).
2. **덱 우선순위**: Anki 기본 동작(덱 목록 위에서부터)을 그대로 쓰되, 시간이
   부족한 날은 "[책] 이것이 취업을 위한 컴퓨터 과학이다"(연체 중앙 167일 —
   가장 최근까지 학습, 구제 가치 최고)만이라도 소화한다.
3. **비대 노트를 만나면**: 그 자리에서 고치지 않는다. Again/Hard로 평가만
   하고 **파란 깃발(Flag 1)** 을 붙인 뒤 넘어간다 — 주말 정비에서 plan 027의
   절차로 처리. (복습 중 편집은 세션을 무한정 늘리는 함정.)
4. **놓친 날**: 이틀 연속까지는 그냥 이어서 한다. 사흘 이상 비면 "실패"가
   아니라 상한을 40→25로 낮춰 재개한다 — 목표는 속도가 아니라 생존.
5. **백로그 소진 후** (due가 상한 밑으로 내려온 날): New cards/day를 0→5로
   올리고, Maximum reviews/day 상한을 100 이상으로 완화한다.
6. **2주 게이트**: 14일 중 10일 이상 세션이 성립하면 — 그때 anki-study v2
   재개와 `🚧 일시중단` 덱 해제를 재검토한다 (그 전에는 논의 자체를 금지 —
   awesome-anki 1.0의 "도구/확장 먼저" 함정 회피).

**Verify**: 운영자의 명시적 동의 답변 (수정 시 파일 갱신 후 동의).

### Step 3 (에이전트): 2주 후 지속성 점검 (후속 세션에서)

2주 뒤 아무 세션에서나 이 plan을 다시 열어:

```bash
curl -s localhost:8765 -X POST -d '{"action":"getNumCardsReviewedByDay","version":6}' \
  | python3 -c "import json,sys; d=json.load(sys.stdin)['result']; recent=d[:14]; print(f'{sum(1 for _,n in recent if n>0)}/14일 학습, 총 {sum(n for _,n in recent)}장')"
```

- 10/14일 이상 → Step 2 규칙 6의 재검토를 운영자에게 제안. 이 plan DONE.
- 미만 → 규칙 4(상한 하향) 적용을 제안하고 status는 IN PROGRESS 유지.

**Verify**: 위 명령의 출력을 보고서에 포함.

## Test plan

운영 절차라 자동 테스트 없음. 게이트: Step 1의 getDeckConfig 수치 확인,
Step 3의 14일 학습일 수 실측.

## Done criteria

- [ ] `getDeckConfig` 응답: `new.perDay == 0`, `rev.perDay == 40`
- [ ] Review sort order = Descending retrievability (운영자 화면 확인)
- [ ] Step 2 규칙에 운영자 동의 기록 (이 파일 또는 세션 로그)
- [ ] 카드/노트 데이터 무변경 (에이전트가 AnkiConnect 변경 액션을 호출하지 않음)
- [ ] (2주 후) Step 3 점검 실행 및 결과 보고
- [ ] `plans/README.md` 025 행 갱신

## STOP conditions

- 마지막 리뷰 일자가 2026-06-01 이후로 실측됨 (이미 재시작됨 — 현황 보고 먼저).
- deck preset이 "기본" 1개가 아님 (preset 분화됨 — 어느 preset이 어느 덱인지
  매핑 확인 먼저).
- 운영자가 Step 2 규칙에 동의하지 않고 대안도 정하지 못함 — 상한 없이 재개하는
  것은 이 plan의 목적 자체를 무효화하므로 진행 불가.
- AnkiConnect가 계속 연결 불가이고 운영자 GUI 확인도 불가한 상황.

## Maintenance notes

- FSRS 파라미터 재최적화는 리뷰 1,000건 누적마다 또는 분기 1회면 충분
  (Anki가 최적화 시점을 자체 안내한다). 백로그 소화 중의 대량 Again은
  정상 데이터다 — 최적화를 미루지 않는다.
- 상한 40은 시작값이지 정답이 아니다. 세션이 25분을 계속 초과하면 30으로,
  10분 안에 끝나면 60으로 — 조정은 preset 한 곳만 만지면 된다.
- plan 027(비대 노트 분할)은 이 plan의 규칙 3(깃발)이 만드는 큐를 소비한다 —
  복습이 돌기 시작한 뒤에야 의미가 있다.
