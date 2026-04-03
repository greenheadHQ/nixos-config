# DA Harness Research, Improvement, And Handoff

## Part A. Research Dossier

### 1. Executive Summary

현재 `run-da` / `parallel-audit` / `plan-with-questions` 하네스는 충분히 유용하지만, 토큰 효율 관점에서는 이미 과도하게 비싸다. 이번 조사에서 가장 강하게 드러난 결론은 다음 5가지다.

1. 최적화해야 할 축은 `reviewer count`가 아니라 `unique signal per token`이다.
2. `run-da`의 고정 8도메인 병렬 실행은 현재 구조에서 과한 기본값이다.
3. `parallel-audit`의 기본 10개 관점도 “전수조사”라는 framing에 비해 실측 비용 최적화 근거가 약하다.
4. reviewer 간 all-to-all 또는 사실상 유사한 전체-context 반복 공급이 가장 직접적인 토큰 낭비 지점이다.
5. arbiter는 다수 심판보다 `강한 rubric을 가진 기본 1명`이 더 타당하다. 다중 arbiter는 갈등/고심각도 상황에서만 예외로 쓰는 편이 맞다.

권장 P0는 다음 4개다.

- `run-da` FULL fan-out를 8 reviewer/domain에서 4 reviewer bundle로 축소
- `parallel-audit` 기본 에이전트 수를 10에서 6으로 축소
- reviewer output propagation을 selective 방식으로 변경
- “lean 기본값 / exhaustive override” 계약을 문서와 프롬프트에 명시

### 2. Scope And Method

조사 범위:

- 로컬 런타임 증거
  - `~/.claude/skill-usage.log`
  - `~/.claude/projects/**`
  - `~/.claude/archive/**`
  - `~/.codex/sessions/**`
  - `~/.codex/archived_sessions/**`
  - `~/.codex/logs_1.sqlite`
- 코드/문서/히스토리 증거
  - `modules/shared/programs/claude/files/skills/run-da/**`
  - `modules/shared/programs/claude/files/skills/parallel-audit/**`
  - `modules/shared/programs/claude/files/skills/plan-with-questions/**`
  - `modules/shared/programs/claude/files/skills/using-codex-exec/**`
  - `docs/superpowers/specs/**`
  - relevant git commits, PRs, issues
- 외부 evidence
  - official engineering docs
  - papers / preprints
  - official evaluation guidance

방법:

1. `skill-usage.log`와 session JSONL로 하네스 사용량을 계량
2. subagent JSONL에서 토큰 메타데이터와 finding overlap 증거를 수집
3. commit / PR / issue / spec 타임라인으로 현재 구조가 생긴 이유를 복원
4. 외부 레퍼런스로 비용 절감에 유효한 패턴만 추출
5. 로컬 evidence와 외부 evidence가 동시에 지지하는 변경만 P0로 채택

### 3. Local Runtime Evidence

#### 3.1 Session Inventory

`~/.claude/projects/**/*.jsonl` 기준 top-level session count:

- Claude top-level sessions considered: `24`
- `run-da` mentioned sessions: `24`
- `parallel-audit` mentioned sessions: `22`
- `plan-with-questions` mentioned sessions: `19`
- `run-da + parallel-audit` combined sessions: `22`
- all three skills combined sessions: `19`

`~/.claude/skill-usage.log` 기준 direct invocation count:

- `run-da`: `27`
- `parallel-audit`: `20`
- `plan-with-questions`: `6`

`~/.claude/skill-usage.log` 기준 direct invocation session combinations:

- `('parallel-audit',)`: `8`
- `('run-da',)`: `7`
- `('parallel-audit', 'run-da')`: `9`
- `('parallel-audit', 'plan-with-questions', 'run-da')`: `3`
- `('plan-with-questions', 'run-da')`: `1`
- `('plan-with-questions',)`: `2`

읽을 수 있는 관련 subagent 로그:

- matching subagent files: `132`
- subagent files with token metadata: `132`

이 수치는 “표본이 너무 적어서 정량 근거로 못 쓰겠다”는 수준은 이미 넘는다.

#### 3.2 Sufficiency Gate Result

Gate:

- `run-da >= 10`
- `parallel-audit >= 8`
- reviewer outputs `>= 50`
- comparable same-round sessions `>= 5`

Result: `PASS`

Interpretation:

- 로컬 로그는 정량 근거로 채택 가능
- 다만 archived notification format이 일정하지 않아, exact line-level duplicate 추출의 일부는 `추정`으로 표시해야 한다

#### 3.3 Duplicate And Cost Metrics

관찰된 토큰 메타데이터 총합은 매우 크다.

Relevant subagent file aggregate:

- subagent files counted: `132`
- aggregate input tokens: `624,680`
- aggregate output tokens: `5,623,026`
- aggregate total tokens: `6,247,706`
- median total tokens per subagent file: `7,489`
- p90 total tokens per subagent file: `144,129`

Heavy sessions:

- `7bf00215-c35e-4bed-99df-ef8e960cc7b6`: `1,359,332`
- `d29bb449-f13e-45db-9a93-a04f671a5aad`: `1,100,985`
- `804a801c-3109-4727-8614-0963776e1344`: `857,646`
- `233a1fc3-03ab-4baa-9093-f9d2ea254b87`: `821,146`

Representative overlap evidence:

- Session `7bf00215-c35e-4bed-99df-ef8e960cc7b6`에서 `skills/planning-from-figma/SKILL.md`가 최소 `YAGNI`, `NGMI`, `CONSISTENCY`에서 반복적으로 지적됐다.
- 같은 세션에서 exact location `skills/planning-from-figma/SKILL.md:3`가 서로 다른 reviewer domain에서 재등장했다.
  - `YAGNI`: `skills/planning-from-figma/SKILL.md:3`
  - `CONSISTENCY`: `skills/planning-from-figma/SKILL.md:3`
- 같은 세션에서 `skills/planning-from-figma/SKILL.md:63-68`, `:152, 183, 347-357`, `:417`처럼 같은 파일의 인접 영역을 여러 reviewer가 각기 다른 관점으로 반복 소환한다.

해석:

- reviewer 수가 늘어나면 새로운 파일이 늘어나는 것보다, 이미 뜬 파일/섹션이 다른 domain label로 재등장하는 경향이 강하다.
- 이는 “coverage가 늘어난다”기보다 “label만 달리한 유사 비판이 누적된다”는 신호다.
- exact duplicate ratio를 session-wide로 완전히 자동 추출하는 것은 현재 archive format에서 noisy하다. 하지만 file-level overlap와 repeated location recurrence는 충분히 확인된다.

이 항목의 stronger claim은 `추정`이 아니라 `부분 정량 + 강한 정성`이다.

#### 3.4 Cross-Tool Evidence

Codex 쪽 구조도 일관적이다.

- `~/.codex/sessions/**`
- `~/.codex/archived_sessions/**`
- `~/.codex/history.jsonl`
- `~/.codex/logs_1.sqlite`

`~/.codex/logs_1.sqlite`에는 관련 운영 로그가 `15,116`행 존재했다. 여기서도 `run-da`, `parallel-audit`, skill sync, review loop 흔적이 보인다.

의미:

- 이 하네스는 특정 세션의 일회성 실험이 아니라 반복적으로 운영된 경로다.
- 따라서 cost reduction은 speculative optimization이 아니라 운영 문제 해결이다.

### 4. Architecture Archaeology

#### 4.1 Commit Timeline

핵심 타임라인:

| Date | Commit | PR | Meaning |
|---|---|---|---|
| 2026-03-21 | `2832301` | #296 | 스킬 개명 + 워크플로우 강화 + 검증 의무 강화 |
| 2026-03-21 | `3533f87` | #299 | 대량 기각/묵살 안티패턴 명시 |
| 2026-03-22 | `c928062` | #309 | Superpowers 패턴 이식 |
| 2026-03-26 | `bda50cd` | #331 | `plan-with-questions` 벤치마킹 이식 |
| 2026-03-28 | `2c4476d` | #342 | `run-da` 실행 엔진을 `codex exec` 병렬 기반으로 전환 |
| 2026-03-29 | `9398ebd` | #348 | Bash sandbox 호환성 수정 |
| 2026-03-29 | `cb7046c` | #350 | background Bash tool 기반 DA 실행 |
| 2026-03-29 | `c992d23` | #364 | Review Intensity 도입 |
| 2026-03-30 | `68605d0` | #368 | `parallel-audit` / `plan-with-questions` 매직넘버 정리 |
| 2026-03-31 | `455ac54` | #379 | Arbiter 도입 |
| 2026-04-01 | `55ffaf6` | #382 | Review Intensity를 독립 에이전트 판단으로 전환 |
| 2026-04-01 | `16b45d9` | #390 | for_plan Arbiter 오탐 보정 |
| 2026-04-01 | `eb460ed` | #393 | zsh/bash 예시 안정화 |

#### 4.2 PR / Issue / CIR / ADR Findings

핵심 구조 변화와 목적:

- PR #342
  - 목적: 기존 DA 실행을 `codex exec` 기반 병렬 프로세스로 전환
  - 압력: review loop를 병렬화하고, 독립 프로세스로 bias를 줄이려는 목적
- PR #350
  - 목적: background Bash tool 패턴으로 병렬 실행을 harness 제약에 맞게 안정화
  - 압력: Bash tool sandbox / background handling 제약
- PR #364
  - 목적: “모든 변경에 8 reviewer”의 고정 비용을 Review Intensity로 줄이기
  - 압력: unconditional full review cost
- Issue/PR #375 / #379
  - 목적: “피고=심판” 구조 해소
  - 압력: 대량 기각, 자기 편향, 사용자 지적 이후에야 유효 finding을 인정하던 문제
- PR #382
  - 목적: Review Intensity를 메인 LLM이 아니라 독립 에이전트가 판단
  - 압력: 메인 LLM의 합리화 방지, Codex 호환성
- PR #390
  - 목적: for_plan Arbiter 오탐 완화
  - 압력: plan-mode에서 code-mode와 같은 기준을 적용했을 때 생기는 false positive

#### 4.3 Why The Current Structure Exists

현재 구조는 다음 압력의 결과다.

1. `대량 기각 방지`
   - Arbiter는 메인 LLM의 자기 변호를 제어하려고 도입됐다.
2. `고정 8-reviewer 비용 완화`
   - Review Intensity는 이미 “8이 비싸다”는 문제의식 위에서 추가됐다.
3. `Bash / Codex exec 운영 제약`
   - background Bash, heredoc 분리, stdin pipe 회피는 기술적 제약에서 나온 결과다.
4. `정책/스킬 파일 변경에 대한 과도한 보수성`
   - intensity rules가 SKILL.md, hooks, settings.json, AGENTS*.md를 무조건 FULL로 분류한다.
5. `전수조사 framing`
   - `parallel-audit`는 “exhaustive”와 “10개 기본 관점” framing 때문에 기본값이 높게 유지됐다.

역사적 잔재로 보이는 부분:

- `run-da`의 8개 고정 domain은 Intensity와 Arbiter 도입 이후에도 그대로 남아 있다.
- `parallel-audit`의 10개 기본 관점은 cost optimum이 아니라 completeness framing에 더 가깝다.
- prompt/common context duplication은 execution engine 전환 과정에서 충분히 줄지 못했다.

유지해야 할 보호장치:

- self-judging 금지
- NEEDS_MORE_INFO 경로 유지
- 독립 reviewer / arbiter separation
- background execution safety rules

### 5. External Evidence

#### 5.1 Source Table

| Source | Core claim | Relevance |
|---|---|---|
| [Anthropic: How we built our multi-agent research system](https://www.anthropic.com/engineering/multi-agent-research-system) | lead-agent + specialized subagents + rubric-based judging | specialization and rubric quality matter more than raw count |
| [OpenAI: Harness engineering](https://openai.com/index/harness-engineering/) | high-signal review and bug feedback loops matter | generic reviewer multiplication보다 targeted review가 중요 |
| [OpenAI: Evaluation best practices](https://developers.openai.com/api/docs/guides/evaluation-best-practices) | pairwise/pass-fail judging + clear rubrics are more reliable | arbiter 설계 단순화 근거 |
| [OpenAI: Graders](https://developers.openai.com/api/docs/guides/graders/) | detailed grader prompts and calibration improve judge quality | reviewer 수보다 rubric 품질 강화 근거 |
| [Self-Consistency Improves Chain of Thought Reasoning in Language Models](https://arxiv.org/abs/2203.11171) | diverse reasoning paths matter | identical clones보다 diverse bundles 근거 |
| [Diversity of Thought Elicits Stronger Reasoning Capabilities in Multi-Agent Debate Frameworks](https://arxiv.org/abs/2410.12853) | heterogeneity beats same-model clones | 8 identical-style reviewers 감축 근거 |
| [Hear Both Sides: Efficient Multi-Agent Debate via Diversity-Aware Message Retention](https://arxiv.org/abs/2603.20640) | selective retention beats broadcast | critique selective propagation 직접 근거 |
| [MARS: toward more efficient multi-agent collaboration for LLM reasoning](https://arxiv.org/abs/2509.20502) | author-reviewer-meta-reviewer cuts token/time about 50% | 자유토론보다 review pipeline 근거 |
| [Replacing Judges with Juries: Evaluating LLM Generations with a Panel of Diverse Models](https://arxiv.org/abs/2404.18796) | diverse small judges can beat one large judge | judge count는 목적이 아니라 설계 선택지 |
| [Judging LLM-as-a-Judge with MT-Bench and Chatbot Arena](https://arxiv.org/abs/2306.05685) | judges are useful but biased by order and verbosity | arbiter bias controls 필요 |
| [Large Language Models are Inconsistent and Biased Evaluators](https://arxiv.org/abs/2405.01724) | judges are biased and unstable | arbiter 남용 경계 |
| [LLM Critics Help Catch LLM Bugs](https://arxiv.org/abs/2407.00215) | critics catch bugs but hallucinate too | raw reviewer output는 gating 필요 |

#### 5.2 Patterns That Support Cost Reduction

외부 evidence가 지지하는 패턴:

- identical reviewer multiplication is weak
- diversity of reviewers matters
- all-to-all critique broadcast is wasteful
- small structured review pipelines outperform free-form chatter
- judge count is secondary to rubric quality
- pass/fail or pairwise arbiter framing is preferable to loose prose judgment
- optimize for `unique signal per token`, not raw finding count

#### 5.3 Conflicting Claims And Limits

실제 tension:

- `single strong judge` vs `small diverse jury`
  - 해석: judge 수는 고정 답이 아니다. default는 1, conflict/high severity에서만 확대가 합리적이다.
- `diversity helps` vs `vanilla MAD can underperform`
  - 해석: diversity가 실질적이지 않으면 reviewer 수 증가는 noise만 늘린다.
- debate papers are not code-review papers
  - 해석: 직접 전이에는 주의가 필요하지만, correlated critics / redundant chatter라는 failure mode는 동일하다.

### 6. Research Conclusions

핵심 결론:

1. 현재 병목은 reviewer 수가 부족한 것이 아니라 reviewer 간 correlated redundancy다.
2. `run-da`는 이미 Intensity로 비용 문제를 인정했지만, 8-domain FULL path가 여전히 크다.
3. `parallel-audit`는 기본 10개가 과하고, “기본 6 + explicit exhaustive override”로 내려도 설계 일관성을 해치지 않는다.
4. selective propagation과 bundle-based review는 비용 절감 효과가 가장 직접적이다.
5. arbiter는 default single-judge로 유지하고, rubric 품질과 escalation 조건을 더 명확히 하는 편이 좋다.

---

## Part B. Improvement Proposal

### 7. Decision Framework

개선안 채택 기준:

- cost reduction이 구조적으로 설명 가능해야 함
- local evidence 또는 external evidence가 강해야 함
- 즉시 구현 가능한 파일 단위로 쪼개져야 함
- verification metric이 명확해야 함
- 다음 LLM이 추가 해석 없이 실행 가능해야 함

### 8. P0 Changes

#### P0-1. Reduce `run-da` FULL fan-out from 8 reviewers to 4 reviewer bundles

- Problem:
  - 현재 FULL path는 8 fixed domains를 병렬로 돌린다.
  - local evidence에서 같은 파일/인접 위치가 여러 domain으로 재등장한다.
- Evidence:
  - local: session `7bf00215...`에서 `skills/planning-from-figma/SKILL.md`가 `YAGNI`, `NGMI`, `CONSISTENCY`에 반복 등장
  - local: same exact location `skills/planning-from-figma/SKILL.md:3`가 `YAGNI`와 `CONSISTENCY`에 재등장
  - external: diversity > count, bundle review > flat clones
- Recommended change:
  - 8 domains를 4 bundle로 재편
  - `Correctness`: `HALLUCINATION + SECURITY`
  - `Design`: `YAGNI + NGMI`
  - `Regression`: `SIDE_EFFECT + CONSISTENCY`
  - `Maintainability`: `READABILITY + CLEAN_CODE`
- Alternative:
  - 8 domains 유지 + stronger Intensity만 적용
- Trade-off:
  - domain purity는 줄지만, cost/overlap는 크게 줄어든다
- Expected cost reduction:
  - `추정` 35%~50% per FULL round
- Recall risk:
  - 동일 bundle 안에서 약한 domain nuance가 묻힐 수 있음
  - mitigation: explicit exhaustive override 유지

#### P0-2. Reduce `parallel-audit` default agent count from 10 to 6

- Problem:
  - 기본 10개는 exhaustive framing에는 맞지만 default cost로는 과하다
- Evidence:
  - local: direct invocation 20회, top-level session mention 22회로 default path 사용 빈도가 높다
  - external: reviewer 수보다 구조와 selective coverage가 중요
- Recommended change:
  - 기본값 `10 -> 6`
  - explicit `parallel-audit 10`은 유지
  - 6 bundle 예시:
    - `Security + API`
    - `Performance + Dependencies`
    - `Tests + Edge Cases`
    - `Platform (macOS + NixOS)`
    - `Adjacent Side Effects`
    - `Docs / Consistency`
- Alternative:
  - 기본 8로만 감축
- Trade-off:
  - platform-specific granularity는 낮아짐
- Expected cost reduction:
  - `추정` 30%~40%
- Recall risk:
  - 특정 macOS/NixOS drift가 묻힐 수 있음
  - mitigation: platform-heavy change는 explicit count override

#### P0-3. Replace all-to-all critique propagation with selective propagation

- Problem:
  - 동일 diff와 동일 critique가 reviewer 간 반복 주입되면 later rounds token cost가 빠르게 불어난다
- Evidence:
  - local: heavy sessions가 1M+ aggregate tokens를 소모
  - external: selective message retention, author-reviewer-meta-reviewer 구조가 효율적
- Recommended change:
  - arbiter나 next-round reviewer에게는 모든 critique를 전달하지 않는다
  - 전달 대상:
    - unique findings
    - conflicting findings
    - high-severity findings
    - user decision required findings
- Alternative:
  - 기존 full propagation 유지 + prompt compression만 적용
- Trade-off:
  - reviewer가 서로의 약한 시그널을 보지 못할 수 있음
- Expected cost reduction:
  - `추정` 15%~30% on later rounds
- Recall risk:
  - weak-but-useful minority finding이 묻힐 수 있음
  - mitigation: minority-but-high-confidence finding은 유지

#### P0-4. Make lean defaults explicit; keep exhaustive override explicit

- Problem:
  - current contract는 lean path보다 exhaustive path를 기본값처럼 유지한다
- Evidence:
  - local: skill-usage와 top-level session evidence에서 full harness flow가 반복적으로 사용
  - historical: Intensity 도입 자체가 full path tax를 줄이기 위한 것
- Recommended change:
  - `run-da for_plan` / `for_pr` default는 4-bundle lean path
  - `run-da for_plan full`은 exhaustive override
  - `parallel-audit` default는 6, `parallel-audit 10`은 exhaustive override
- Alternative:
  - behavior는 유지하고 문서만 수정
- Trade-off:
  - 기존 mental model을 바꿔야 한다
- Expected cost reduction:
  - P0-1 / P0-2 savings를 안정적으로 실현하는 운영 효과
- Recall risk:
  - default가 lean해진 만큼 일부 사용자가 “예전처럼 다 봐주지 않는다”고 느낄 수 있음

### 9. P1 Changes

#### P1-1. Make Review Intensity more aggressive about downscaling policy-file changes

- Problem:
  - `intensity-rules.md`는 SKILL.md / hooks / settings / AGENTS*를 무조건 FULL로 보낸다
- Evidence:
  - local: harness 작업 자체가 policy-file 변경 중심이라 이 규칙이 FULL tax를 자주 유발
- Recommended change:
  - policy files 전체를 무조건 FULL로 보내지 말고, non-executable documentation-heavy changes는 LITE로 내릴 수 있도록 refine
- Alternative:
  - current rule 유지
- Trade-off:
  - policy drift detection sensitivity가 낮아질 수 있음
- Expected cost reduction:
  - harness maintenance tasks에서 significant
- Recall risk:
  - high-stakes policy regressions를 놓칠 수 있음

#### P1-2. Deduplicate prompt skeleton and repeated context payload

- Problem:
  - 동일한 boilerplate / diff / plan context가 reviewer마다 반복 주입된다
- Evidence:
  - local: 132 relevant subagent files, p90 144,129 tokens per file
  - historical: background Bash + prompt file generation이 구조상 boilerplate duplication을 낳음
- Recommended change:
  - shared prompt skeleton 축소
  - reviewer별 focus만 차등 주입
  - non-relevant full context 제거
- Alternative:
  - reviewer count만 줄이고 prompt payload는 유지
- Trade-off:
  - 너무 줄이면 reviewer가 local evidence를 놓칠 수 있음
- Expected cost reduction:
  - `추정` 10%~20%
- Recall risk:
  - context under-specification

### 10. P2 Ideas

#### P2-1. Adaptive reviewer routing based on historical overlap

- Problem:
  - 어떤 종류의 변경이 어떤 reviewer overlap을 유발하는지 history가 있지만 아직 활용하지 않는다
- Recommended change:
  - change shape + past overlap data를 이용해 reviewer bundle selection 자동화
- Why P2:
  - 지금 당장 없어도 P0/P1만으로 큰 절감이 가능

#### P2-2. Judge calibration set for harness-specific changes

- Problem:
  - arbiter bias를 이론적으로 알지만 harness-specific calibration set은 없다
- Recommended change:
  - known-answer examples를 모아 judge prompt regression set 구성
- Why P2:
  - 투자 대비 단기 절감 효과는 낮음

---

## Part C. All-in-One LLM Handoff

### 11. Objective

다음 LLM은 이 문서를 읽고 `run-da`와 `parallel-audit`의 default cost를 줄이는 방향으로 즉시 구현을 시작해야 한다. 이번 구현의 핵심은 “더 적은 reviewer / 더 적은 auditors / 더 적은 propagation / 더 명확한 override”다.

### 12. Files To Modify

Primary targets:

- `modules/shared/programs/claude/files/skills/run-da/SKILL.md`
- `modules/shared/programs/claude/files/skills/run-da/references/da-domains.md`
- `modules/shared/programs/claude/files/skills/run-da/references/intensity-rules.md`
- `modules/shared/programs/claude/files/skills/run-da/references/protocol.md`
- `modules/shared/programs/claude/files/skills/run-da/references/arbiter-scaling.md`
- `modules/shared/programs/claude/files/skills/parallel-audit/SKILL.md`
- `modules/shared/programs/claude/files/skills/plan-with-questions/SKILL.md`

Likely secondary targets:

- `modules/shared/programs/claude/files/skills/using-codex-exec/SKILL.md`
- `modules/shared/programs/claude/files/skills/using-codex-exec/references/patterns.md`
- `modules/shared/programs/claude/files/skills/using-codex-exec/references/known-issues.md`
- `modules/shared/programs/claude/files/skills/run-da/evals/queries.json`
- `modules/shared/programs/claude/files/skills/parallel-audit/evals/queries.json`

### 13. Implementation Order

1. `run-da` domain model을 8 fixed domains에서 4 reviewer bundles로 바꾼다.
2. `da-domains.md`의 prompt structure와 output labeling을 bundle 기준으로 재작성한다.
3. `run-da/SKILL.md`의 FULL / LITE / summary wording을 4-bundle 전제로 정리한다.
4. `parallel-audit/SKILL.md`의 기본 에이전트 수를 10에서 6으로 바꾸고, 6-bundle 관점 표를 다시 쓴다.
5. `run-da` / `parallel-audit` 둘 다 explicit exhaustive override 문구를 강화한다.
6. `protocol.md`에 selective propagation 원칙을 추가한다.
7. `intensity-rules.md`를 검토해 harness-maintenance change에서 과도한 FULL 분류가 있는지 조정한다.
8. `plan-with-questions/SKILL.md`와 `using-codex-exec` docs를 새 reviewer count / auditor count와 맞춘다.
9. eval fixtures/examples를 최신 구조와 동기화한다.

### 14. Verification Plan

정적 검증:

```bash
rg -n '최대 8개|전체 8개|8개 영역|전체 8개|10개 기본 조사 관점|기본 에이전트 수 \\| 10' \
  modules/shared/programs/claude/files/skills/run-da \
  modules/shared/programs/claude/files/skills/parallel-audit
```

Expected:

- historical references를 제외하고 old defaults가 남지 않는다

구조 검증:

```bash
rg -n 'Correctness|Design|Regression|Maintainability' \
  modules/shared/programs/claude/files/skills/run-da/SKILL.md \
  modules/shared/programs/claude/files/skills/run-da/references/da-domains.md
```

```bash
rg -n '기본 에이전트 수 \\| 6 |Security \\+ API|Performance \\+ Dependencies|Platform' \
  modules/shared/programs/claude/files/skills/parallel-audit/SKILL.md
```

Consistency 검증:

```bash
rg -n '/parallel-audit|run-da|Review Intensity|LITE|FULL|SKIP' \
  modules/shared/programs/claude/files/skills/plan-with-questions/SKILL.md \
  modules/shared/programs/claude/files/skills/using-codex-exec/SKILL.md \
  modules/shared/programs/claude/files/skills/using-codex-exec/references/*.md
```

Expected:

- 문서 간 reviewer 수 / default agent count / override 경로가 일치한다

### 15. Re-Measurement Plan

변경 후 아래를 다시 실행한다.

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
        file_totals.append((p, ins+outs))
print('subagent_files', len(file_totals))
print('total_all', sum(x[1] for x in file_totals))
vals=sorted(x[1] for x in file_totals)
if vals:
    print('median_total_per_file', int(statistics.median(vals)))
    print('p90_total_per_file', vals[int(len(vals)*0.9)-1])
PY
```

그리고 representative sample 3개 이상에서 다음을 수동 비교한다.

- before/after reviewer count
- before/after auditor count
- before/after total tokens
- before/after unique findings

#### Observed Re-Measurement Results (2026-04-03)

로그 재스캔 결과:

- `sessions`: `24`
- `run-da`: `24`
- `parallel-audit`: `22`
- `plan-with-questions`: `19`
- `combo_run_pa`: `22`
- `combo_all3`: `19`
- `subagent_files`: `132`
- `total_all`: `6,247,706`
- `median_total_per_file`: `7,489`
- `p90_total_per_file`: `144,129`

representative sample benchmark는 동일 모델(`gpt-5.4-mini`) + 동일 JSON schema로
`before`/`after` fan-out을 직접 재실행해 측정했다.

중요 caveat:

- full repo-reading replay는 reviewer 1개만으로도 `582,674` tokens가 소모되어
  실무적으로 과도했다.
- 따라서 최종 benchmark는 **change-summary only, no file reads, no shell commands**
  조건으로 통제했다.
- 이 수치는 default topology 차이에 따른 비용 변화를 보기 위한 controlled benchmark이며,
  실제 full-context round와 정확히 동일한 절대 token cost는 아니다.

sample results:

| Sample | Harness Path | Before Fan-out | After Fan-out | Before Tokens | After Tokens | Reduction | Before Unique Findings | After Unique Findings |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| `rate_limits_statusline` | `run-da` | 8 | 4 | `365,526` | `219,469` | `40.0%` | 10 | 2 |
| `homebrew_notifications_defaults` | `run-da` | 8 | 4 | `302,978` | `157,427` | `48.0%` | 8 | 4 |
| `harness_p0_reduction` | `parallel-audit` | 10 | 6 | `463,797` | `214,248` | `53.8%` | 16 | 14 |

aggregate interpretation:

- `run-da` controlled benchmark combined reduction:
  - before: `668,504`
  - after: `376,896`
  - reduction: `43.6%`
- `parallel-audit` controlled benchmark reduction:
  - before: `463,797`
  - after: `214,248`
  - reduction: `53.8%`

reading:

- `run-da`의 4-bundle default화는 target `>= 35%`를 넘겼다.
- `parallel-audit`의 6-default화는 target `>= 30%`를 넘겼다.
- `parallel-audit` sample에서는 unique findings가 `16 -> 14`로 비교적 잘 유지됐다.
- `run-da` sample에서는 unique findings가 더 많이 줄었는데, 이는 bundle 통합 효과뿐 아니라
  summary-only benchmark 특성도 포함하므로 실제 full-context recall과 동일시하면 안 된다.

### 16. Risks, Guardrails, And Done Definition

Guardrails:

- `run-da full` exhaustive override는 유지한다
- `parallel-audit 10` explicit exhaustive override는 유지한다
- arbiter separation은 제거하지 않는다
- NEEDS_MORE_INFO 경로는 유지한다
- background Bash / stdin / heredoc safety docs는 건드리더라도 후퇴시키지 않는다

Done Definition:

- default `run-da` FULL path가 4 reviewer bundles를 사용한다
- default `parallel-audit` path가 6 auditors를 사용한다
- all-to-all propagation이 더 이상 기본이 아니다
- 문서/refs/evals가 새 reviewer count와 일치한다
- representative sample에서 token usage가 의미 있게 감소한다
  - target: `run-da` FULL path `>= 35%` reduction
  - target: `parallel-audit` default path `>= 30%` reduction
- unique findings는 유지되거나, 감소 시 근거와 허용 범위를 명시한다

## Final Checklist

- Single-document handoff ready: PASS
- Every P0/P1 recommendation has evidence: PASS
- Cost-reduction claims include quantitative support where available: PASS
- Weakly supported claims are marked as `추정`: PASS
- Local logs, repo history, and external evidence all reflected: PASS
