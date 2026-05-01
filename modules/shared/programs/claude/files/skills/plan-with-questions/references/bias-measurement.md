# Bias Measurement

plan-with-questions에 도입된 anti-anchoring 메커니즘(Step 3.5 외부 자문 + 4규칙)이 실제로 anchoring-bias 사례를 줄이는지 측정하기 위한 baseline + 재측정 절차. codex:rescue 메타 자문(2026-05-01)이 권고한 4축 grep + 4 metric을 기반으로 한다.

## 측정 방법: 스크립트가 SSOT

**baseline 수치는 본 reference에 하드코딩하지 않는다.** 스크립트 실행이 단일 진실 원천이다.

```bash
# Mac local + MiniPC 양쪽
./scripts/ai/measure-anchoring-bias.sh --days 60

# Mac만
./scripts/ai/measure-anchoring-bias.sh --skip-ssh

# JSON 출력 (자동화 통합용)
./scripts/ai/measure-anchoring-bias.sh --json
```

스크립트는 stdout(plain 또는 JSON)으로만 출력한다 — 파일 자동 저장은 하지 않는다. baseline을 보존하려면 사용자가 redirect로 명시 저장한다 (`.claude/metrics/`는 `.gitignore`에 등재됨):

```bash
mkdir -p .claude/metrics
./scripts/ai/measure-anchoring-bias.sh > .claude/metrics/anchoring-baseline-$(date +%Y-%m-%d).txt
```

plan 파일에는 절대 수치 대신 측정 명령과 결과 파일 경로를 적는다.

## 4축 grep 패턴

스크립트 [`scripts/ai/measure-anchoring-bias.sh`](../../../../../../../../scripts/ai/measure-anchoring-bias.sh)의 `PAT_*` 변수가 정본 (아래 표는 illustrative — 키워드 갱신 시 script가 우선):

| 축 | 의미 | 예시 키워드 |
|----|------|------------|
| 1. choice | 사용자가 옵션을 선택한 흔적 | `사용자 결정`, `선호`, `A 방식`, `AskUserQuestion` |
| 2. framing | 메인 LLM이 추천 프레이밍을 제시한 흔적 | `추천`, `권장`, `Recommended`, `기본값` |
| 3. defect | 사후에 결함이 발견된 흔적 | `CONFIRMED_ISSUE`, `YAGNI`, `overbuilt`, `parallel-audit` |
| 4. resistance | 결함을 보고도 저항한 흔적 | `사용자 결정에 따라`, `현상 유지`, `기각`, `재설계.*거부` |

키워드 갱신은 **script `PAT_*` 변수가 단일 진실 원천**이다. 위 표는 사람 읽기용 illustrative 사본 — script 변경 후 표를 손으로 동기화하면 된다 (반대 방향 금지: 표만 바꾸면 측정 결과는 바뀌지 않는다).

## 4 metric

| Metric | 의미 | 계산 |
|--------|------|------|
| `choice_then_defect_rate` | 같은 transcript에서 choice + defect 신호 동반 비율 | `(choice ∩ defect) / total` |
| `leading_question_ratio` | 선택 부근 추천 표현 빈도 (line-window 분석 필요) | follow-up — 스크립트 v2에서 awk/jq |
| `defect_after_user_choice_severity` | choice 이후 등장한 결함의 심각도 분포 | follow-up — `CONFIRMED_ISSUE`/`YAGNI`/`overbuilt` 카운트 |
| `redesign_resistance_rate` | 결함 + 저항 동반 비율 | `(defect ∩ resistance) / defect` |

현재 v1 스크립트는 file-level intersection만 측정한다 (line-ordering은 follow-up).

**해석 주의**: file-level intersection은 lower-bound 추정이다 — 같은 transcript에 4축 신호가 모두 있어도 실제 anchoring case가 아닐 수 있고(legitimate plan workflow), 반대로 line-ordering 없이는 인과 단정 불가. metric 변화 추이를 candidate 식별 위주로 본다 (codex 권고).

## 측정 schedule

| 시점 | 동작 |
|------|------|
| Phase 5 commit 후 (T+0) | baseline 측정 → `.claude/metrics/anchoring-baseline-<date>.txt` |
| Step 3.5 도입 후 1주 (T+1w) | 재측정 → `.claude/metrics/anchoring-T1w-<date>.txt` |
| Step 3.5 도입 후 1개월 (T+1m) | 재측정 → `.claude/metrics/anchoring-T1m-<date>.txt` |

각 측정 후 metric 변화를 `Decision Log` DL 항목으로 추가:

```markdown
### DL-N: Anchoring metric T+1w retest

- Status: accepted
- Context: Step 3.5 도입 후 1주 경과. baseline vs 재측정 비교.
- Decision: <변화 추이 + 후속 조치>
- Consequences: <metric이 줄었는지/늘었는지/변화 없음 + 가설 검증 결과>
```

## 인과 추정 한계

본 measurement는 **bias candidate 식별** 도구이지 **인과 증명** 도구가 아니다.

- file-level intersection은 같은 transcript 내 동반 등장만 보여준다. line-ordering(choice가 defect보다 앞에 있는지)은 v2에서 추가.
- 외부 변수(이슈 복잡도 변화, 사용자 학습, 다른 스킬 개선)가 metric에 동시 영향. Step 3.5의 단독 효과 분리 불가.
- 절대 수치 변화를 효과 증명으로 쓰지 않는다 — 추세 + 정성 사례(`#490` 같은 transcript 발췌) 병행.

## v2 follow-up

스크립트 v1 한계를 보완할 v2 작업 (별도 follow-up issue):

- **line-ordering 분석**: choice 라인이 defect 라인보다 앞서는 file만 집계 (정밀 anchoring case 식별).
- **leading_question_ratio**: 선택 라인 부근 N줄 윈도우에서 framing 키워드 비율 계산.
- **severity 분포**: `defect` 신호를 P0/P1/P2로 분류 (현재는 단순 count).
- **CSV/JSON 시계열**: `.claude/metrics/`에 시계열 누적 → spreadsheet/노트북 분석 가능.

v2는 `scripts/ai/measure-anchoring-bias.sh` 자체를 수정하거나 `measure-anchoring-bias-v2.sh`로 분리. 결정은 측정 결과 + 사용자 follow-up 우선순위에 따른다.
