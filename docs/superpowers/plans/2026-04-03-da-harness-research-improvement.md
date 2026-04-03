# DA Harness Research, Improvement, And Handoff Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `run-da`, `parallel-audit`, `plan-with-questions` 하네스를 전수조사해 토큰 낭비 원인을 정리하고, 개선안과 즉시 실행 가능한 LLM handoff를 단일 문서로 완성한다.

**Architecture:** 결과물은 단일 연구 문서 하나로 수렴시킨다. 먼저 로컬 로그와 세션 JSONL로 호출량/중복률/토큰 사용량을 계량하고, 이어서 git/PR/spec 히스토리로 현재 구조의 형성 이유를 복원한 뒤, 외부 논문/공식 문서를 대조해 개선안을 도출한다. 마지막으로 같은 문서 안에 `Research Dossier`, `Improvement Proposal`, `All-in-One LLM Handoff` 3개 파트를 완성한다.

**Tech Stack:** zsh, `rg`, `jq`, `python3`, `sqlite3`, `gh`, Markdown

**Spec:** `docs/superpowers/specs/2026-04-03-da-harness-research-design.md`

**User Preference Override:** 커밋은 사용자가 직접 수행한다. 이 계획에는 `git commit` 단계가 없다.

**Local Routing Note:** 이 repo에서는 `superpowers:subagent-driven-development`를 실제 구현 스킬로 사용하지 않는다. 실행 시 fresh worker 세션 또는 현재 세션 inline 실행 중 하나를 택하되, 본 계획의 작업 순서와 검증 절차를 그대로 따른다.

---

## File Structure

| Action | Path | 역할 |
|--------|------|------|
| Create | `docs/superpowers/research/2026-04-03-da-harness-research.md` | 최종 단일 결과물. `Research Dossier + Improvement Proposal + All-in-One LLM Handoff`를 모두 포함 |

---

### Task 1: 최종 연구 문서 뼈대 생성

**Files:**
- Create: `docs/superpowers/research/2026-04-03-da-harness-research.md`

- [ ] **Step 1: 출력 디렉토리 생성**

Run:

```bash
mkdir -p docs/superpowers/research
```

Expected: `docs/superpowers/research` 디렉토리가 생성된다.

- [ ] **Step 2: 최종 문서 skeleton 작성**

`docs/superpowers/research/2026-04-03-da-harness-research.md`:

```markdown
# DA Harness Research, Improvement, And Handoff

## Part A. Research Dossier

### 1. Executive Summary

### 2. Scope And Method

### 3. Local Runtime Evidence

#### 3.1 Session Inventory

#### 3.2 Sufficiency Gate Result

#### 3.3 Duplicate And Cost Metrics

#### 3.4 Cross-Tool Evidence

### 4. Architecture Archaeology

#### 4.1 Commit Timeline

#### 4.2 PR / Issue / CIR / ADR Findings

#### 4.3 Why The Current Structure Exists

### 5. External Evidence

#### 5.1 Source Table

#### 5.2 Patterns That Support Cost Reduction

#### 5.3 Conflicting Claims And Limits

### 6. Research Conclusions

## Part B. Improvement Proposal

### 7. Decision Framework

### 8. P0 Changes

### 9. P1 Changes

### 10. P2 Ideas

## Part C. All-in-One LLM Handoff

### 11. Objective

### 12. Files To Modify

### 13. Implementation Order

### 14. Verification Plan

### 15. Re-Measurement Plan

### 16. Risks, Guardrails, And Done Definition
```

- [ ] **Step 3: skeleton 파일 존재 확인**

Run:

```bash
test -f docs/superpowers/research/2026-04-03-da-harness-research.md && echo OK
```

Expected: `OK`

---

### Task 2: 로컬 세션 인벤토리와 Sufficiency Gate 결과 작성

**Files:**
- Modify: `docs/superpowers/research/2026-04-03-da-harness-research.md`

- [ ] **Step 1: Claude top-level session 카운트 계산**

Run:

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

Expected: `sessions`, `run-da`, `parallel-audit`, `plan-with-questions`, `combo_run_pa`, `combo_all3` 6개 라인이 출력된다.

- [ ] **Step 2: subagent/토큰 메타데이터 가용성 계산**

Run:

```bash
python3 - <<'PY'
import os, glob
count=0
usage=0
for p in glob.glob(os.path.expanduser('~/.claude/projects/**/subagents/*.jsonl'), recursive=True):
    try:
        txt=open(p, encoding='utf-8').read()
    except Exception:
        continue
    if 'run-da' in txt or 'parallel-audit' in txt or 'Arbiter' in txt or 'Review Intensity' in txt:
        count += 1
        if 'input_tokens' in txt or 'output_tokens' in txt:
            usage += 1
print('matching_subagent_files', count)
print('with_usage_tokens', usage)
PY
```

Expected: `matching_subagent_files`, `with_usage_tokens` 2개 라인이 출력된다.

- [ ] **Step 3: skill-usage.log 기반 호출량 교차검증**

Run:

```bash
python3 - <<'PY'
import os
import re
from collections import Counter
counts=Counter()
with open(os.path.expanduser('~/.claude/skill-usage.log'), encoding='utf-8') as f:
    for line in f:
        m=re.search(r'(run-da|parallel-audit|plan-with-questions)', line)
        if m:
            counts[m.group(1)] += 1
for key in ('run-da', 'parallel-audit', 'plan-with-questions'):
    print(key, counts[key])
PY
```

Expected: 세 스킬 각각의 호출 횟수가 출력된다.

- [ ] **Step 4: `Part A > 3. Local Runtime Evidence` 섹션 채우기**

문서에 아래 내용을 추가한다. 이 값들은 현재 baseline 측정치이며, 재실행 결과가 다르면 괄호로 차이를 덧붙인다.

```markdown
### 3. Local Runtime Evidence

#### 3.1 Session Inventory

- Claude top-level sessions considered: 24
- `run-da` sessions: 24
- `parallel-audit` sessions: 22
- `plan-with-questions` sessions: 19
- `run-da + parallel-audit` combined sessions: 22
- all three skills combined sessions: 19
- matching subagent files: 132
- subagent files with token metadata: 132

#### 3.2 Sufficiency Gate Result

- Gate requirement: `run-da >= 10`, `parallel-audit >= 8`, reviewer outputs `>= 50`, comparable same-round sessions `>= 5`
- Result: `PASS`
- Interpretation: 로컬 로그를 정량 근거로 채택한다. 단, duplicate extraction이 위치 누락 때문에 흔들리는 항목은 `추정`으로 표시한다.
```

주의: Step 1-3 재실행 결과가 달라지면 현재 baseline 뒤에 `현재 재측정: <값>` 형태로 차이를 덧붙인다.

- [ ] **Step 5: 문서 반영 확인**

Run:

```bash
rg -n "Session Inventory|Sufficiency Gate Result|run-da sessions|parallel-audit sessions" docs/superpowers/research/2026-04-03-da-harness-research.md
```

Expected: 4개 이상의 매칭 라인이 출력된다.

---

### Task 3: 중복 finding / 토큰 낭비 분석 작성

**Files:**
- Modify: `docs/superpowers/research/2026-04-03-da-harness-research.md`

- [ ] **Step 1: 관련 세션 후보 경로 목록 추출**

Run:

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
    if 'run-da' in txt or 'parallel-audit' in txt or 'plan-with-questions' in txt:
        hits.append(p)
for p in hits[:40]:
    print(p)
PY
```

Expected: 관련 session JSONL 경로 목록이 출력된다.

- [ ] **Step 2: 대표 세션 5개 이상에서 reviewer output 구조 확인**

Run:

```bash
rg -n "## \\[|\\*\\*위치\\*\\*|CLEAR|SAFE|BUG|REGRESSION|EDGECASE|CONFIRMED_ISSUE|NOT_AN_ISSUE" \
  ~/.claude/projects/**/subagents/*.jsonl 2>/dev/null | head -n 200
```

Expected: finding 형식, 위치 필드, 상태 코드가 포함된 line sample이 출력된다.

- [ ] **Step 3: duplicate key 설계와 metric 계산 스크립트 작성 및 실행**

Run:

```bash
python3 - <<'PY'
import os, glob, re
from collections import Counter

loc_re = re.compile(r'(?:파일|위치|Location)[^\n]*?([A-Za-z0-9_./-]+:\d+|plan step \d+)', re.I)
domain_re = re.compile(r'\b(YAGNI|NGMI|HALLUCINATION|SECURITY|SIDE_EFFECT|CONSISTENCY|READABILITY|CLEAN_CODE)\b')

keys=[]
token_hits=0
for p in glob.glob(os.path.expanduser('~/.claude/projects/**/subagents/*.jsonl'), recursive=True):
    try:
        txt=open(p, encoding='utf-8').read()
    except Exception:
        continue
    if not ('run-da' in txt or 'parallel-audit' in txt or 'Arbiter' in txt):
        continue
    if 'input_tokens' in txt or 'output_tokens' in txt:
        token_hits += 1
    domains = domain_re.findall(txt)
    locs = loc_re.findall(txt)
    for d in domains:
        for loc in locs[:5]:
            keys.append((d, loc.lower()))

counts=Counter(keys)
dupes=sum(v-1 for v in counts.values() if v > 1)
print('candidate_keys', len(counts))
print('duplicate_key_excess', dupes)
print('tokenized_subagent_files', token_hits)
for (d, loc), n in counts.most_common(20):
    print(f'{n}\t{d}\t{loc}')
PY
```

Expected: `candidate_keys`, `duplicate_key_excess`, `tokenized_subagent_files`와 상위 중복 key 목록이 출력된다.

- [ ] **Step 4: duplicate/cost 결과를 문서에 정리**

문서에 아래 구조를 채운다. 숫자는 Step 3의 실측값을 그대로 넣고, 중복 상위 key는 출력된 상위 5개를 그대로 적는다.

```markdown
#### 3.3 Duplicate And Cost Metrics

- Duplicate key normalization: `domain + normalized location`
- Candidate unique keys observed: `Step 3 출력값 그대로 기록`
- Duplicate key excess observed: `Step 3 출력값 그대로 기록`
- Tokenized reviewer outputs available: `Step 3 출력값 그대로 기록`

관찰:

- 중복 상위 key 5개를 bullet로 정리
- 같은 위치를 여러 reviewer가 반복 지적한 사례를 2개 이상 적시
- `run-da`와 `parallel-audit` 중 어디서 더 중복이 심한지 정성 판단
- 계산 한계가 있으면 `추정`으로 표시
```

- [ ] **Step 5: 토큰 낭비 해석 작성**

문서에 아래 bullet 4개를 반드시 포함한다.

```markdown
- reviewer 수 증가가 unique signal 증가로 곧바로 이어지지 않았는지
- 동일 diff / 동일 맥락 broadcast가 redundancy를 키웠는지
- arbiter가 제거한 중복 critique 비중이 있는지
- `token per unique finding` 관점에서 구조적 비효율이 있는지
```

---

### Task 4: commit / PR / CIR / ADR 고고학 작성

**Files:**
- Modify: `docs/superpowers/research/2026-04-03-da-harness-research.md`

- [ ] **Step 1: 핵심 commit 타임라인 수집**

Run:

```bash
git log --reverse --oneline -- \
  modules/shared/programs/claude/files/skills/run-da \
  modules/shared/programs/claude/files/skills/parallel-audit \
  modules/shared/programs/claude/files/skills/plan-with-questions \
  docs/superpowers/specs | tail -n 80
```

Expected: `run-da`/`parallel-audit`/`plan-with-questions` 관련 핵심 commit 목록이 시간순으로 출력된다.

- [ ] **Step 2: 관련 PR 메타데이터 수집**

Run:

```bash
gh pr list --repo greenheadHQ/nixos-config --limit 50 --state all \
  --search 'run-da OR parallel-audit OR "Review Intensity" OR Arbiter OR "codex exec"' \
  --json number,title,createdAt,mergedAt,state,url
```

Expected: JSON 배열이 출력되고, PR #342, #350, #364, #379, #382, #390, #393이 포함된다.

- [ ] **Step 3: 관련 spec/issue/PR rationale를 읽고 타임라인 서술 작성**

문서 `Part A > 4. Architecture Archaeology`에 아래 순서로 정리한다.

```markdown
#### 4.1 Commit Timeline

- `2c4476d` — `run-da` execution engine moved to `codex exec`
- `cb7046c` — background Bash tool dispatch
- `c992d23` — Review Intensity introduction
- `455ac54` — Arbiter introduction
- `55ffaf6` — independent Intensity agent
- `16b45d9` — for_plan arbiter false-positive mitigation
- `eb460ed` — zsh/bash prompt assembly hardening

#### 4.2 PR / Issue / CIR / ADR Findings

- PR body, linked issue, and spec 문서를 읽고 각 변화가 어떤 pain point를 해결하려고 했는지 bullet로 서술
- 문서화된 decision과 실제 구현 drift가 있으면 구분

#### 4.3 Why The Current Structure Exists

- 현재 구조를 낳은 압력 3~5개를 bullet로 적는다
- 예: 대량 기각 방지, codex exec 병렬화, sandbox 제약, false-positive 완화, bias 분리
```

- [ ] **Step 4: archaeology 섹션 검증**

Run:

```bash
rg -n "2c4476d|cb7046c|c992d23|455ac54|55ffaf6|16b45d9|eb460ed" docs/superpowers/research/2026-04-03-da-harness-research.md
```

Expected: 7개 해시가 모두 매칭된다.

---

### Task 5: 외부 레퍼런스와 개선안 작성

**Files:**
- Modify: `docs/superpowers/research/2026-04-03-da-harness-research.md`

- [ ] **Step 1: 외부 레퍼런스 표 작성**

문서 `Part A > 5. External Evidence`에 아래 10개 소스를 최소 포함한다.

```markdown
| Source | Claim | Relevance |
|---|---|---|
| Self-Consistency Improves Chain of Thought Reasoning in Language Models | diversity of reasoning paths matters more than repeated greedy sampling | reviewer 수보다 reviewer 다양성 논거 |
| Mixture-of-Agents Enhances Large Language Model Capabilities | layered aggregation beats flat duplication | reviewer output aggregation 구조 논거 |
| Diversity of Thought Elicits Stronger Reasoning Capabilities in Multi-Agent Debate Frameworks | heterogeneity beats same-model clones | 8개 유사 reviewer 감축 논거 |
| Demystifying Multi-Agent Debate: The Role of Confidence and Diversity | vanilla multi-agent debate may underperform without diversity and confidence control | debate-style reviewer 증식 경계 |
| Hear Both Sides: Efficient Multi-Agent Debate via Diversity-Aware Message Retention | selective message retention reduces redundancy | critique selective propagation 논거 |
| MARS: toward more efficient multi-agent collaboration for LLM reasoning | author-reviewer-meta-reviewer can reduce token/time cost | review pipeline 구조 논거 |
| Auditing Multi-Agent LLM Reasoning Trees Outperforms Majority Vote and LLM-as-Judge | localized verification beats raw majority vote | arbiter / verification 구조 논거 |
| Anthropic: How we built our multi-agent research system | single strong judge can outperform many judges | 단일 강한 arbiter 논거 |
| OpenAI: Harness engineering | targeted extra reviews beat generic reviewer multiplication | run-da reviewer 역할 차별화 논거 |
| OpenAI Evaluation best practices | clear rubric and pass/fail framing matter more than judge count | arbiter rubric 강화 논거 |
```

- [ ] **Step 2: 외부 패턴을 현재 하네스에 매핑**

문서에 아래 5개 bullet를 반드시 포함한다.

```markdown
- same-context reviewer multiplication is likely wasteful
- selective propagation is preferable to all-to-all broadcast
- arbiter count should not grow by default
- unique signal is a better optimization target than raw finding count
- diversity and rubric quality matter more than reviewer count alone
```

- [ ] **Step 3: Improvement Proposal 작성**

문서 `Part B`는 아래 7개 subsection을 정확히 이 이름으로 작성한다. 각 subsection에는 `Problem`, `Evidence`, `Recommended change`, `Alternative`, `Trade-off`, `Expected cost reduction`, `Recall risk` 7개 bullet를 모두 채운다.

```markdown
### 8. P0 Changes

#### P0-1. Reduce `run-da` FULL fan-out from 8 reviewers to 4 reviewer bundles
- Use four bundles: `Correctness` (`HALLUCINATION + SECURITY`), `Design` (`YAGNI + NGMI`), `Regression` (`SIDE_EFFECT + CONSISTENCY`), `Maintainability` (`READABILITY + CLEAN_CODE`)

#### P0-2. Reduce `parallel-audit` default agent count from 10 to 6
- Keep explicit override path for `parallel-audit 10`

#### P0-3. Replace all-to-all critique propagation with selective propagation
- Escalate only unique findings, conflicting findings, or high-severity findings

#### P0-4. Keep a single strong arbiter as the default
- Expand to multiple arbiters only when severity or disagreement justifies it

### 9. P1 Changes

#### P1-1. Make Review Intensity more aggressive about downscaling
- Push more small or doc-heavy changes into reduced-review paths

#### P1-2. Deduplicate prompt skeleton and repeated context payload
- Shrink repeated boilerplate before changing reviewer logic further

### 10. P2 Ideas

#### P2-1. Adaptive reviewer routing based on change shape and prior overlap data
- Treat this as a future optimization, not a P0 blocker
```

각 항목은 최소 1개 로컬 근거 또는 1개 외부 근거를 명시해야 한다.

- [ ] **Step 4: All-in-One LLM Handoff 작성**

문서 `Part C`에 아래 6개 섹션을 채운다.

```markdown
### 11. Objective
### 12. Files To Modify
### 13. Implementation Order
### 14. Verification Plan
### 15. Re-Measurement Plan
### 16. Risks, Guardrails, And Done Definition
```

필수 조건:

- `Files To Modify`에는 실제 파일 경로를 적는다.
- `Implementation Order`는 P0 먼저, 그 다음 P1 순으로 쓴다.
- `Verification Plan`에는 실행 명령을 적는다.
- `Re-Measurement Plan`에는 같은 로그 계측 명령을 다시 적는다.
- `Done Definition`에는 `token 감소`, `duplicate ratio 감소`, `unique findings 유지 또는 허용 범위 명시`를 포함한다.

---

### Task 6: 최종 자체 검증

**Files:**
- Modify: `docs/superpowers/research/2026-04-03-da-harness-research.md`

- [ ] **Step 1: placeholder 금지 패턴 검사**

Run:

```bash
rg -n 'TBD|TODO|implement later|fill in details|적절히 처리|필요에 따라|추후 결정|별도 검토 필요' \
  docs/superpowers/research/2026-04-03-da-harness-research.md
```

Expected: no output, exit code 1

- [ ] **Step 2: 필수 파트 존재 확인**

Run:

```bash
rg -n '^## Part A|^## Part B|^## Part C|^### 8\\. P0 Changes|^### 12\\. Files To Modify|^### 14\\. Verification Plan' \
  docs/superpowers/research/2026-04-03-da-harness-research.md
```

Expected: 각 파트/핵심 섹션이 모두 매칭된다.

- [ ] **Step 3: acceptance criteria 교차 점검**

문서 끝에 아래 checklist를 추가하고 전부 `PASS` 또는 `FAIL`로 채운다. 미완 항목을 남기지 않는다.

```markdown
## Final Checklist

- Single-document handoff ready: PASS/FAIL
- Every P0/P1 recommendation has evidence: PASS/FAIL
- Cost-reduction claims include quantitative support where available: PASS/FAIL
- Weakly supported claims are marked as `추정`: PASS/FAIL
- Local logs, repo history, and external evidence all reflected: PASS/FAIL
```

- [ ] **Step 4: 최종 파일 읽기**

Run:

```bash
sed -n '1,260p' docs/superpowers/research/2026-04-03-da-harness-research.md
```

Expected: 문서의 Part A/B/C가 순서대로 읽히고, 핵심 주장에 근거가 붙어 있다.
