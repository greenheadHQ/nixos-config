# DA Harness Re-Measurement Method

이 문서는 2026-04-03 P0 구현 검증 때 실제 사용한 before/after 토큰 재계측 절차를 기록한다.
목적은 다음 번에 비슷한 fan-out / propagation / arbiter 변경을 검증할 때,
이번 시행착오를 반복하지 않고 바로 재사용 가능한 측정 playbook을 남기는 것이다.

## 1. Goal

측정 목표는 "새 default topology가 실제로 token usage를 줄이는가"를 검증하는 것이다.
여기서 중요한 것은 절대적인 전체 토큰 수보다 **동일 조건에서 old topology와 new topology를 공정하게 비교하는 것**이다.

이번 변경 기준:

- `run-da`: `8 fixed reviewers -> 4 reviewer bundles`
- `parallel-audit`: `10 auditors -> 6 auditor bundles`
- propagation: `all-to-all default -> selective default`
- arbiter: `single strong default 유지`

## 2. Two-Tier Strategy

이번 측정은 두 층으로 나눠야 한다.

### Tier A: Log Re-Scan

목적:

- 현재 로컬 로그 기준 사용량 baseline을 다시 확인
- 표본 수가 여전히 충분한지 재확인
- heavy session / heavy subagent를 다시 찾기

실행 명령:

```bash
python3 - <<'PY'
import os, glob
hits=[]
for p in glob.glob(os.path.expanduser('~/.claude/projects/**/*.jsonl'), recursive=True):
    if '/subagents/' in p:
        continue
    try:
        txt=open(p, encoding='utf-8').read()
    except Exception:
        continue
    has_run='run-da' in txt
    has_pa='parallel-audit' in txt
    has_pwq='plan-with-questions' in txt
    if has_run or has_pa or has_pwq:
        hits.append((p, has_run, has_pa, has_pwq))
print('sessions', len(hits))
print('run-da', sum(1 for h in hits if h[1]))
print('parallel-audit', sum(1 for h in hits if h[2]))
print('plan-with-questions', sum(1 for h in hits if h[3]))
print('combo_run_pa', sum(1 for h in hits if h[1] and h[2]))
print('combo_all3', sum(1 for h in hits if h[1] and h[2] and h[3]))
PY
```

```bash
python3 - <<'PY'
import glob, os, re, statistics
file_totals=[]
for p in glob.glob(os.path.expanduser('~/.claude/projects/**/subagents/*.jsonl'), recursive=True):
    try:
        txt=open(p,encoding='utf-8').read()
    except Exception:
        continue
    if not ('run-da' in txt or 'parallel-audit' in txt or 'Arbiter' in txt or 'Review Intensity' in txt):
        continue
    ins=sum(int(x) for x in re.findall(r'\"input_tokens\":(\\d+)', txt))
    outs=sum(int(x) for x in re.findall(r'\"output_tokens\":(\\d+)', txt))
    if ins or outs:
        file_totals.append((p, ins+outs, ins, outs))
print('subagent_files', len(file_totals))
print('total_all', sum(x[1] for x in file_totals))
vals=sorted(x[1] for x in file_totals)
if vals:
    print('median_total_per_file', int(statistics.median(vals)))
    print('p90_total_per_file', vals[int(len(vals)*0.9)-1])
print('\\nTOP20')
for p,t,ins,outs in sorted(file_totals, key=lambda x:x[1], reverse=True)[:20]:
    print(t, ins, outs, p)
PY
```

이 단계는 "로그 기준 baseline 재확인"용이다.
이 결과만으로 P0 효과를 증명하려고 하면 안 된다. old/new code가 섞인 historical aggregate이기 때문이다.

### Tier B: Representative Sample Benchmark

목적:

- 동일 입력에서 old topology와 new topology를 직접 비교
- fan-out 차이로 인한 토큰 차이를 정량화
- unique findings 변화도 함께 본다

이번에 최종적으로 채택한 방식은:

- 동일 모델 사용
- 동일 JSON schema 사용
- 동일 sample summary 사용
- old topology fan-out과 new topology fan-out만 바꿔 비교

## 3. What Failed

이번 작업에서 먼저 시도했지만 버린 방법은 **full repo-reading replay**였다.

방법:

- old reviewer / auditor prompt를 거의 그대로 복원
- `codex exec`로 각 reviewer를 실제 repo에서 다시 실행
- diff 읽기 + 관련 파일 탐색까지 허용

문제:

- reviewer 1개만으로도 토큰이 과도하게 커졌다
- 예: old `run-da` replay에서 reviewer 1개(`YAGNI`)가
  - `input_tokens = 555,647`
  - `output_tokens = 27,027`
  - total `582,674`
- 8 reviewers + 4 bundles + 10 auditors까지 확장하면 이번 검증 턴에서 비용/시간이 비현실적이다
- repo 탐색량 차이가 topology 차이보다 더 큰 variance를 만들기 시작한다

결론:

- full repo-reading replay는 "실제 하네스 round 재연"에는 가깝지만,
  P0 fan-out 비교 benchmark로는 너무 비싸고 noisy하다
- reviewer topology 차이를 측정하려면 input variance를 더 강하게 통제해야 한다

## 4. Final Benchmark Design

최종 채택 방식은 **change-summary only benchmark**다.

규칙:

- 입력은 사람이 작성한 change summary로 제한
- shell command 실행 금지
- repo 파일 읽기 금지
- reviewer 간 동일 summary 공유
- 모델 고정
- output schema 고정

이렇게 하면 측정값이 "repo exploration + incidental context cost"가 아니라
"fan-out topology + reviewer prompt shape cost"에 더 가깝게 된다.

### Fixed Benchmark Contract

- model: `gpt-5.4-mini`
- invocation: `codex exec --json --full-auto --output-schema ... -o ...`
- response shape:
  - `clear: boolean`
  - `findings[]`
    - `title`
    - `location`
    - `severity`
    - `summary`
    - `lens`

### Why JSON Schema Was Mandatory

schema 없이 자유서술형 출력을 받으면:

- reviewer마다 finding 표현 형식이 달라짐
- unique finding dedupe가 어려워짐
- old/new 비교가 reviewer style 차이에 오염됨

따라서 `--output-schema`는 필수다.

## 5. Codex Exec Pattern

실제 사용 패턴:

```bash
tmpdir=$(mktemp -d)
codex exec \
  --json \
  -m gpt-5.4-mini \
  --full-auto \
  --output-schema "$tmpdir/schema.json" \
  -o "$tmpdir/out.json" \
  "$PROMPT" \
  > "$tmpdir/events.jsonl" \
  2> "$tmpdir/stderr.log"
```

usage 파싱은 `events.jsonl`의 `turn.completed` 레코드에서 가져온다:

```python
usage = {"input_tokens": 0, "output_tokens": 0, "cached_input_tokens": 0}
for line in proc.stdout.splitlines():
    obj = json.loads(line)
    if obj.get("type") == "turn.completed":
        u = obj.get("usage", {})
        usage["input_tokens"] += u.get("input_tokens", 0)
        usage["output_tokens"] += u.get("output_tokens", 0)
        usage["cached_input_tokens"] += u.get("cached_input_tokens", 0)
```

### Practical Note

`codex exec` stderr에는 Slack/OAuth MCP 인증 오류가 섞여 나올 수 있다.
이번 측정에서는 exit code가 `0`이고 `out.json`이 유효하면,
이 stderr는 benchmark failure로 취급하지 않았다.

## 6. Sample Selection Rules

이번에 사용한 샘플은 3개였다.

1. `run-da` sample 1:
   - shell/shared script 성격의 변경
   - example: `rate_limits_statusline`
2. `run-da` sample 2:
   - 설정/host split + default seeding 성격의 변경
   - example: `homebrew_notifications_defaults`
3. `parallel-audit` sample:
   - 하네스 자기 자신을 바꾸는 변경
   - example: `harness_p0_reduction`

선정 원칙:

- `run-da` 2개 + `parallel-audit` 1개는 최소 확보
- trivial one-file typo change는 제외
- explicit exhaustive override path는 기본 benchmark에서 제외
- historical heavy session이나 default-path 사용 빈도가 높은 케이스를 우선

## 7. Old vs New Topology Mapping

### run-da

before:

- `YAGNI`
- `NGMI`
- `HALLUCINATION`
- `SECURITY`
- `SIDE_EFFECT`
- `CONSISTENCY`
- `READABILITY`
- `CLEAN_CODE`

after:

- `Correctness` = `HALLUCINATION + SECURITY`
- `Design` = `YAGNI + NGMI`
- `Regression` = `SIDE_EFFECT + CONSISTENCY`
- `Maintainability` = `READABILITY + CLEAN_CODE`

### parallel-audit

before:

- `Security`
- `Performance`
- `Tests`
- `Edge Cases`
- `Dependencies`
- `macOS`
- `NixOS`
- `Adjacent Side Effects`
- `API`
- `Docs Consistency`

after:

- `Security + API`
- `Performance + Dependencies`
- `Tests + Edge Cases`
- `Platform (macOS + NixOS)`
- `Adjacent Side Effects`
- `Docs / Consistency`

## 8. Prompt Rules That Matter

이번에 benchmark variance를 낮추는 데 실제로 중요했던 규칙:

1. "다른 reviewer 언급 금지"
2. "prompt 밖의 파일 읽기 금지"
3. "shell command 실행 금지"
4. "provided text only"
5. "finding 최대 개수 제한"
6. `run-da` bundle prompt에서는 `lens`를 subdomain으로 명시

이 규칙이 없으면 old/new가 서로 다른 탐색 경로를 타면서 비교가 흐려진다.

## 9. Unique Finding Counting

이번에는 다음 키로 dedupe했다:

- `location.lower().strip()`
- `title.lower().strip()`

즉, `location + title` 조합 기준이다.

이 방식의 장점:

- reviewer wording 차이보다 실제 issue identity를 더 잘 보존
- old/new topology 간 finding count 비교가 단순해짐

한계:

- 같은 issue인데 title이 조금 다르면 중복이 남을 수 있음
- 같은 파일:줄에서 다른 risk를 말하면 하나로 합쳐질 수 없음

그래도 controlled benchmark 수준에서는 가장 실용적이었다.

## 10. Stopping Rules

다음 조건이 보이면 full replay를 중단하고 change-summary benchmark로 전환한다.

1. reviewer 1개 total tokens가 `250k+`를 넘기기 시작함
2. reviewer가 repo 전체 탐색으로 새 variance를 만들기 시작함
3. old/new topology 차이보다 "탐색 비용"이 더 커짐
4. 전체 benchmark wall time이 검증 목적을 넘어섬

이번에는 1번이 바로 발생했다.

## 11. Reporting Rules

최종 보고에는 아래를 함께 남긴다.

- `before/after fan-out`
- `before/after tokens_total`
- `reduction %`
- `before/after unique_finding_count`
- benchmark caveat

그리고 반드시 구분한다:

- historical log re-scan
- controlled benchmark

이 둘을 섞어서 한 숫자로 주장하면 안 된다.

## 12. Recommended Reuse Procedure

다음에 비슷한 변경을 측정할 때는 아래 순서를 그대로 따른다.

1. log re-scan으로 표본 수와 heavy session을 다시 확인한다.
2. representative sample 3개 이상을 고른다.
3. old/new topology fan-out mapping을 먼저 명시한다.
4. full repo-reading replay를 1 reviewer만 smoke test한다.
5. reviewer 1개가 과도하게 비싸면 즉시 summary-only benchmark로 전환한다.
6. `codex exec --json --output-schema`로 old/new를 모두 측정한다.
7. `location + title` 기준 dedupe로 unique findings를 계산한다.
8. reduction 수치와 caveat를 함께 문서화한다.

## 13. One-Line Rule

**토큰 절감 검증에서 가장 중요한 것은 "같은 change summary, 같은 model, 같은 schema, 다른 topology"다.**
