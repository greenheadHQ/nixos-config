# LLM-Friendly Issue/Handoff Checklist

> `create-issue`/`write-handoff`/`plan-with-questions` 스킬이 공유하는 품질 체크리스트.
> **Normative**는 스킬이 실제로 강제한다. **Informational**은 작성 시 참고용 권장.

배경: 세션 로그 전수조사 결과 스킬 산출물에 대한 피드백이 "근거/레퍼런스 부족"과 "맥락 부족"에 집중된다. 본 체크리스트는 이 두 축을 구조적으로 방어한다. 상세 배경은 #461 참조.

---

## Normative Checklist (스킬 강제)

실제 스킬 절차가 강제하는 항목이다. 이 원칙들은 `create-issue`/`write-handoff`의 Step/참조 자료에서 직접 연결된다.

### A. 자립성 (Self-contained)

- [ ] **A1.** 첫 5줄 이내에 `무슨 문제 / 누가 겪는지 / 현재 증상 / 기대 결과`를 기술한다. 출처: [Anthropic: Be clear and direct](https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/be-clear-and-direct) (minimal-context colleague test), [GitHub Copilot: Prompt engineering](https://docs.github.com/en/copilot/concepts/prompting/prompt-engineering).
- [ ] **A2.** "왜" 이 작업이 필요한지, 안 하면 어떤 리스크가 있는지 2-4문장으로 명시한다. 출처: [Anthropic: Be clear and direct](https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/be-clear-and-direct) — end goal을 주면 성능이 향상된다.

(A3 `범위/비범위/제약/금지사항 별도 섹션`은 아래 Informational로 이동 — create-issue/write-handoff 기본 템플릿이 해당 섹션을 별도로 강제하지 않으므로 Normative에서 제외.)

### B. 근거 / 레퍼런스 (Evidence-first)

- [ ] **B1.** 비자명한 주장에 인라인 citation을 붙인다 (`[링크 텍스트](URL)`). `write-handoff`는 가이드 본문 인라인에 붙이고, `create-issue`는 필수 `References` 섹션에서 출처 링크 목록으로 제공한다. 출처: [Anthropic: Reduce hallucinations](https://docs.anthropic.com/en/docs/test-and-evaluate/strengthen-guardrails/reduce-hallucinations), [Learning Fine-Grained Grounded Citations (ACL Findings 2024)](https://aclanthology.org/2024.findings-acl.838/).
- [ ] **B4.** 파일/함수/PR/doc URL은 본문에 직접 적는다 (예: `path/to/file.nix:42`, `#123`, `abc1234`). 출처: [Anthropic: Best Practices for Claude Code (2025)](https://code.claude.com/docs/en/best-practices).

### C. PoC / 재현 (Reproducibility-first)

- [ ] **C1.** 재현이 중요한 주장에는 최소 재현 절차 6필드를 포함한다: `환경 / 입력 / 절차 / 기대 결과 / 실제 결과 / 성공 기준`. 출처: [OpenAI Evals: Structured Outputs Evaluation (2025)](https://cookbook.openai.com/examples/evaluation/use-cases/structured-outputs-evaluation), [PROMPTEVALS (NAACL 2025)](https://aclanthology.org/2025.naacl-long.213/).
- [ ] **C3.** BEFORE/AFTER 쌍을 제공한다 (`write-handoff` 전용. 기존 `references/guide-template.md` 패턴 유지).

### D. 구조 (Structuring)

- [ ] **D1.** `write-handoff` 가이드 상단 10줄 이내에 **TL;DR** (상황/현재 상태/다음 액션/Blockers 4슬롯)을 둔다. 출처: [Lost in the Middle (TACL 2024)](https://direct.mit.edu/tacl/article/doi/10.1162/tacl_a_00638/119630/Lost-in-the-Middle-How-Language-Models-Use-Long) — 중간 정보는 활용률이 낮고 앞/뒤 정보에 강함.
- [ ] **D2.** `write-handoff` 가이드의 **마지막 섹션**으로 **Next Session Starter**를 둔다 (이 가이드 읽고 바로 실행할 명령어/재개 지점). 필수 슬롯만 포함하고 간결하게 유지. 출처: recency bias, 위 D1과 동일 논문.

  ❌ **BAD**: `cd /Users/alice/projects/myrepo && git fetch origin feat/foo` _(why: 작성자의 로컬 사용자 경로가 공개 이슈 코멘트에 노출 — 다른 세션/머신에서 재사용 불가, NSS 재개 지점 목적 저해)_

  ✅ **GOOD**: `REPO='acme/project'; ISSUE_NUM='123'` — Step 8 Self-verification으로 `<REPO_SLUG>`/`<ISSUE_NUM>` placeholder 치환 완료를 검증한 뒤 `guide-template.md`의 NSS 패턴(서브쉘 + 명시적 `|| exit 1` + `issue/{N}` non-destructive restore) 사용. 규약 상세는 `write-handoff/SKILL.md`의 "Handoff branch convention" 섹션 참조.

### E. Anti-hallucination (Evidence-gated)

- [ ] **E1.** 근거가 없거나 확신 없는 주장은 `[UNVERIFIED]` 라벨을 붙이거나 삭제한다. 출처: [Anthropic: Reduce hallucinations](https://docs.anthropic.com/en/docs/test-and-evaluate/strengthen-guardrails/reduce-hallucinations), [MetaFaith (EMNLP 2025)](https://aclanthology.org/2025.emnlp-main.1505/) — faithful uncertainty 표현이 개선됨.

  ❌ **BAD**: `"이 옵션은 Claude Code 2.0+에서 동작한다."` _(why: 버전별 동작은 공식 docs 또는 로컬 재현 없이 단정 불가 — hallucination 위험)_

  ✅ **GOOD**: `"Claude Code 2.1.104에서 동작 확인. [UNVERIFIED] 이전 버전 호환성은 미확인."`
- [ ] **E2.** 초안 후 **Self-verification 패스** (CoVe 경량)를 수행한다: 주요 claim을 검증 질문으로 바꾸고 독립적으로 답한 뒤 불일치 시 수정. `create-issue`/`write-handoff` 모두 적용한다. 출처: [Chain-of-Verification (arXiv 2309.11495)](https://arxiv.org/abs/2309.11495), [Self-Alignment for Factuality (ACL 2024)](https://aclanthology.org/2024.acl-long.107/).

  ❌ **BAD**: `"1차 초안 작성 후 즉시 gh issue create 실행."` _(why: CoVe 검증 단계 생략 → 오류가 게시된 이슈로 그대로 확산)_

  ✅ **GOOD**: `"1차 초안의 비자명 주장을 Read/Grep/gh로 재검증 후 [UNVERIFIED] 라벨 추가 또는 삭제, 그 다음 게시(create-issue: gh issue create / write-handoff: gh issue comment --body-file)."`

---

## Informational Principles (권장, 강제 아님)

스킬이 직접 강제하지는 않지만 산출물 품질에 기여하는 원칙. 필요 시 참고.

| ID | 원칙 | 출처 |
|----|------|------|
| A3 | 범위/비범위/제약/금지사항 별도 섹션 분리 (기본 템플릿은 Context/Notes 내 서술로 충분) | [OpenAI: GPT-5 prompting guide (2025)](https://developers.openai.com/cookbook/examples/gpt-5/gpt-5_prompting_guide) |
| A4 | Assumptions/Glossary 명시 | [GitHub Copilot: Prompt engineering](https://docs.github.com/en/copilot/concepts/prompting/prompt-engineering) |
| A5 | unrelated 배경 배제 | [Anthropic: Best Practices for Claude Code (2025)](https://code.claude.com/docs/en/best-practices) — context hygiene |
| B2 | 레퍼런스 앞에 한 문장으로 "왜 읽어야 하는지" 설명 | [Anthropic Contextual Retrieval (2024)](https://www.anthropic.com/engineering/contextual-retrieval) |
| B3 | Source reliability 등급: official docs > repo code > issue > blog > LLM 기억 | [RAG with Source Reliability (EMNLP 2025)](https://aclanthology.org/2025.emnlp-main.1738/) |
| B5 | Quote-first: 원문 short quote → 해석 | [Verifiable by Design (NAACL 2025)](https://aclanthology.org/2025.naacl-long.191/) |
| C2 | 코드블록 + 언어 태그 (`bash`, `nix` 등) | — |
| C4 | 환경 분기 명시 (macOS/NixOS, `ssh minipc` 등) | 프로젝트 `CLAUDE.md` Platform 규칙 |
| D3 | heading depth 3단계 이하 | [Document Structure in Long Document Transformers (EACL 2024)](https://aclanthology.org/2024.eacl-long.64/) |
| D4 | 표는 비교 행렬에만 사용 | [Table Meets LLM (Microsoft 2024)](https://www.microsoft.com/en-us/research/publication/table-meets-llm-can-large-language-models-understand-structured-table-data-a-benchmark-and-empirical-study/) |
| D5 | Markdown 기본 + 명시적 경계 필요 시 XML | [Anthropic: Use XML Tags](https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/use-xml-tags) |
| E3 | 상충 시 `[CONFLICTING]` + 양측 인용 | [FaithfulRAG (ACL 2025)](https://aclanthology.org/2025.acl-long.1062/) |

---

## 라벨 체계 (Anti-hallucination)

> **단일 진실 원천**. `create-issue`/`write-handoff`/`plan-with-questions` 및 해당 reference 파일(특히 `plan-with-questions/references/review-impl/*`)은 이 섹션을 참조한다. 규칙 변경 시 이 섹션을 먼저 수정하고, 소비자 문서의 요약 문구/포인터도 함께 점검한다.

이슈/이행가이드/계획/리뷰 finding 작성 중 다음 라벨을 사용한다:

| 라벨 | 의미 | 사용 예시 |
|------|------|----------|
| (없음) | 직접 확인된 사실 | 파일을 직접 Read로 확인 후 기술한 내용 |
| `[UNVERIFIED]` | 근거 링크 또는 직접 확인 없이 쓴 주장 | `[UNVERIFIED]` Claude Code skill discovery가 `_shared/` 디렉토리를 스킬로 오인할 수 있음 |
| `[INFERRED]` | 근접한 근거로부터의 추론 (직접 근거 아님) | `[INFERRED]` PoC 첨부가 hallucination을 줄인다는 정량 연구는 없으나, reproducibility-first의 인접 근거에서 강하게 추론됨 |
| `[CONFLICTING]` | 두 개 이상 출처가 상충 | `[CONFLICTING]` FRONT(2024)는 pipeline 분리 우위를 보고, Evaluating Design Choices(2025)는 direct generation 우위를 보고 |

**DEPRECATED**: `<!-- 미검증: ... -->` HTML 주석은 더 이상 권장되지 않는다. 신규 산출물은 `[UNVERIFIED]` 라벨을 사용한다. 기존 산출물은 점진적으로 마이그레이션한다.

---

## Self-verification 절차 (CoVe 경량판, E2)

`create-issue`/`write-handoff` 초안 완료 후 다음 패스를 1회 수행:

1. **Claim 추출**: 본문에서 비자명한 주장을 추출. 단순/자명 사실 제외.
2. **검증 질문 재작성**: 각 claim을 질문 형태로 전환. 예: `"Step 1에 Glob/Grep이 없다"` → `"실제 Step 1 본문에 Glob/Grep이 포함되어 있는가?"`
3. **독립 답변**: 초안을 보지 않은 상태로 `Read`/`Grep`/`gh` 재실행으로 질문에 답.
4. **비교 및 수정**: 답변과 초안이 불일치하면 초안 수정. 증거 없으면 `[UNVERIFIED]` 라벨 또는 삭제.

출처: [Chain-of-Verification (arXiv 2309.11495)](https://arxiv.org/abs/2309.11495), [Self-Alignment for Factuality (ACL 2024)](https://aclanthology.org/2024.acl-long.107/).

---

## Sources (주요 출처)

핵심 출처:

- [Anthropic: Reduce hallucinations](https://docs.anthropic.com/en/docs/test-and-evaluate/strengthen-guardrails/reduce-hallucinations) — abstention, citations, iterative verification.
- [Anthropic: Best Practices for Claude Code (2025)](https://code.claude.com/docs/en/best-practices) — verify-first, explore-plan-implement, context hygiene.
- [Anthropic: Be clear and direct](https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/be-clear-and-direct) — minimal-context colleague test.
- [Anthropic: Use XML Tags](https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/use-xml-tags).
- [Anthropic Contextual Retrieval (2024)](https://www.anthropic.com/engineering/contextual-retrieval).
- [OpenAI: GPT-5 prompting guide (2025)](https://developers.openai.com/cookbook/examples/gpt-5/gpt-5_prompting_guide).
- [OpenAI Evals: Structured Outputs Evaluation (2025)](https://cookbook.openai.com/examples/evaluation/use-cases/structured-outputs-evaluation) — Structured Outputs 평가 기준 (C1).
- [GitHub Copilot: Prompt engineering](https://docs.github.com/en/copilot/concepts/prompting/prompt-engineering).

학술 (2023-2025):

- [Chain-of-Verification (arXiv 2309.11495)](https://arxiv.org/abs/2309.11495) — 초안 → 검증 질문 → 독립 답변 → 재작성 (E2).
- [Lost in the Middle (TACL 2024)](https://direct.mit.edu/tacl/article/doi/10.1162/tacl_a_00638/119630/Lost-in-the-Middle-How-Language-Models-Use-Long) — primacy/recency bias (D1, D2).
- [Learning Fine-Grained Grounded Citations (ACL Findings 2024)](https://aclanthology.org/2024.findings-acl.838/) — fine-grained quote grounding (B1).
- [Self-Alignment for Factuality (ACL 2024)](https://aclanthology.org/2024.acl-long.107/) — self-evaluation 기반 factuality alignment (E2).
- [Document Structure in Long Document Transformers (EACL 2024)](https://aclanthology.org/2024.eacl-long.64/) — heading depth / section 경계 (D3).
- [Table Meets LLM (Microsoft 2024)](https://www.microsoft.com/en-us/research/publication/table-meets-llm-can-large-language-models-understand-structured-table-data-a-benchmark-and-empirical-study/) — structured table 이해 (D4).
- [MetaFaith (EMNLP 2025)](https://aclanthology.org/2025.emnlp-main.1505/) — faithful uncertainty expression (E1).
- [FaithfulRAG (ACL 2025)](https://aclanthology.org/2025.acl-long.1062/) — parametric vs retrieved fact-level conflict (E3).
- [Verifiable by Design (NAACL 2025)](https://aclanthology.org/2025.naacl-long.191/) — quote-first citation design (B5).
- [RAG with Source Reliability (EMNLP 2025)](https://aclanthology.org/2025.emnlp-main.1738/) — source reliability grading (B3).
- [PROMPTEVALS (NAACL 2025)](https://aclanthology.org/2025.naacl-long.213/) — production prompts + assertion criteria (C1).

전체 출처 목록은 #461 References 섹션 참조.

---

## 관련 이슈

- #461 — 본 체크리스트 도입 이슈 (세션 로그 전수조사 + 공통 원칙 정리).
