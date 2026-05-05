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

축 2 framing의 `Recommended` 키워드는 transcript 안에서 LLM이 추천 프레이밍을 사용한 흔적을 식별하는 catalog 용도다 — D4 합의 알고리즘이 정상 작동해도(합의 PASS 옵션에 라벨 부착) transcript에 "Recommended" 토큰은 등장한다. 따라서 본 transcript metric은 D1/D2/D4 도입 후에도 그대로 유지된다 (axis-2의 의미는 "framing 흔적 식별"이지 "라벨 부착 위반 검출"이 아니다). PWQ source 본문에서 라벨 부착이 D4 합의 PASS 컨텍스트로만 한정되었는지 별개로 검증하려면 아래 "Source label sanitization baseline (D4 정책 일관성)" 절차를 사용한다.

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

## Source label sanitization baseline (D4 정책 일관성)

**목적**: PWQ source 본문에서 `(Recommended)` 라벨이 D4 합의 알고리즘 PASS 컨텍스트로만 등장하는지(허용 조건 컨텍스트 외 매칭 없음) 정적 검증한다. 이는 transcript anchoring metric(위 4축)과는 별개의 source sanitization metric이다.

D4 정책 도입 (`consulting-step.md` Anti-anchoring 1번 재작성, SKILL.md Invariant 8) 이후 source 본문에서 `Recommended`는 다음 **파일/섹션 화이트리스트** 안에서만 등장이 허용된다 (이전 버전의 긴 키워드 catalog는 self-reference 메타 매칭이 늘면서 catalog 유지 비용이 정책 검증 비용을 압도해 — 파일/섹션 기반 화이트리스트로 단순화).

| 파일 | 허용 섹션 |
|---|---|
| `consulting-step.md` | "Anti-anchoring 4 규칙" 1번 D4 합의 알고리즘 단락 / "출력 JSON schema" 금지 단어 단락 / "Validation" Phase 2 보조 단락 |
| `output-templates.md` | "Step 4 / Step I-4 질문 패턴" 라벨 부착 조건 단락 / "라운드별 룰 매트릭스" 표 / "D2 텍스트 복구 (D4와 별개 축)" 단락 |
| `runtime-boundaries.md` | "request_user_input 페이로드 가이드" 운영 정책 1번/2번 단락 |
| `SKILL.md` | "Invariants" 섹션 6번/8번 |
| `modes/for_action.md` | "Step 4: 사용자에게 질문" 본문 (라벨 부착 + hard rule + judgment-first + fallback 단락) |
| `modes/for_prd.md` | "Step 1-4 + Step 5-6 (for_action 차용)" Step 4 차용 단락 |
| `bias-measurement.md` | 본 "Source label sanitization baseline" 단락 자체 (메타) + axis-2 framing catalog 표 (transcript 측정용) |

### 검증 명령 (inline rg)

```bash
# Default: PR 작업/머지 전 source 검증 (repo-tracked, git-state 일관)
SKILLDIR=modules/shared/programs/claude/files/skills/plan-with-questions

# Optional: 머지 + nrs 후 deployed 재검증
# SKILLDIR=~/.claude/skills/plan-with-questions

# 모든 Recommended 매칭 파일 확인
rg -l "Recommended" "$SKILLDIR/"

# 위 화이트리스트에 없는 파일에서 매칭이 나오면 정책 위반 후보 (manual triage 필수)
rg -l "Recommended" "$SKILLDIR/" \
  | rg -v "consulting-step\.md$|output-templates\.md$|runtime-boundaries\.md$|SKILL\.md$|modes/for_action\.md$|modes/for_prd\.md$|bias-measurement\.md$"
```

### Baseline PASS 조건 (두 단계)

**Stage 1 (자동 — 파일 단위 negative check)**: 두 번째 명령이 매칭을 출력하지 않으면 화이트리스트 외 파일에 라벨 누출이 없다는 1차 조건 통과. 매칭이 출력되면 manual triage:

1. 새 허용 컨텍스트인 새 파일이면 화이트리스트에 추가 (본 단락 갱신).
2. D4 정책 위반이면 source 본문에서 라벨 표현 제거 (정상 컨텍스트로 재작성).

**Stage 2 (manual — 섹션 단위 review, baseline PASS 확정 조건)**: 화이트리스트 파일 내부 매칭이 위 표의 허용 섹션 안에 있는지 사람이 line별 확인. 자동 검증 한계는 다음과 같다 — Stage 1만으로는 같은 파일 내 새 섹션에 라벨이 추가되어도 PASS로 잘못 판정될 수 있다 (SC-2 "허용 조건 명시 컨텍스트만" 계약 약화 위험). Stage 2는 reviewer가 다음을 수행한다:

```bash
# Default: PR 작업/머지 전 source 검증 (repo-tracked)
SKILLDIR=modules/shared/programs/claude/files/skills/plan-with-questions
# Optional: 머지 + nrs 후 deployed 재검증
# SKILLDIR=~/.claude/skills/plan-with-questions

# 화이트리스트 각 파일의 매칭 line별 위치 확인
for f in consulting-step.md output-templates.md runtime-boundaries.md; do
  echo "=== $f ==="
  rg -n "Recommended" "$SKILLDIR/references/$f"
done
rg -n "Recommended" "$SKILLDIR/SKILL.md" "$SKILLDIR/modes/for_action.md" "$SKILLDIR/modes/for_prd.md" "$SKILLDIR/references/bias-measurement.md"
```

각 매칭이 위 표의 허용 섹션 헤더 아래에 있는지, 새 섹션이 도입되었으면 그 섹션이 D4 컨텍스트인지 사람이 판단한다. 모든 매칭이 허용 섹션 안이면 baseline PASS 확정.

본 두 단계 분리는 line-level 정규식 allowlist의 self-reference 메타 매칭 폭증 문제(이전 버전의 키워드 catalog가 풀려는 시도)를 회피하면서, "화이트리스트 외 파일은 절대 라벨 추가 금지" + "화이트리스트 내 새 섹션은 manual review로 정합 검증"이라는 두 보장을 분리해 정합성을 확보한다.

### baseline 갱신 시점

- D4 정책 변경 시 (consulting-step.md / SKILL.md Invariant / output-templates.md 수정 commit).
- 신규 허용 파일 도입 시 (예: 새 mode 파일에 fallback 단락 추가).
- Phase 5 dogfooding 5건 후 actual transcript와 비교하여 화이트리스트 정합성 점검.

### 스크립트와의 분리 이유

`measure-anchoring-bias.sh`는 transcript anchoring metric (4축 file-level intersection)이 본업이며, source sanitization은 D4 정책 변경 cadence에 종속된 별개 측정이다. 두 metric을 한 스크립트에 묶으면 cadence가 충돌하므로 본 reference의 inline rg 명령을 SSOT로 둔다.

## v2 follow-up

스크립트 v1 한계를 보완할 v2 작업 (별도 follow-up issue):

- **line-ordering 분석**: choice 라인이 defect 라인보다 앞서는 file만 집계 (정밀 anchoring case 식별).
- **leading_question_ratio**: 선택 라인 부근 N줄 윈도우에서 framing 키워드 비율 계산.
- **severity 분포**: `defect` 신호를 P0/P1/P2로 분류 (현재는 단순 count).
- **CSV/JSON 시계열**: `.claude/metrics/`에 시계열 누적 → spreadsheet/노트북 분석 가능.

v2는 `scripts/ai/measure-anchoring-bias.sh` 자체를 수정하거나 `measure-anchoring-bias-v2.sh`로 분리. 결정은 측정 결과 + 사용자 follow-up 우선순위에 따른다.
