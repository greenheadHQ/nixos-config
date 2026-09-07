# LLM-Friendly Issue/Handoff Checklist

> `create-issue`/`write-handoff` 스킬이 공유하는 품질 체크리스트.
> Normative는 스킬이 실제로 강제한다. Informational은 작성 시 참고용 권장.

배경: 세션 로그 전수조사 결과 스킬 산출물에 대한 피드백이 "근거/레퍼런스 부족"과 "맥락 부족"에 집중된다. 본 체크리스트는 이 두 축을 구조적으로 방어한다. 상세 배경은 #461 참조.

---

## Normative Checklist (스킬 강제)

실제 스킬 절차가 강제하는 항목이다. 이 원칙들은 `create-issue`/`write-handoff`의 Step/참조 자료에서 직접 연결된다.

### A. 자립성 (Self-contained)

- [ ] A1. 첫 5줄 이내에 `무슨 문제 / 누가 겪는지 / 현재 증상 / 기대 결과`를 기술한다. 출처: [Anthropic: Be clear and direct](https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/be-clear-and-direct) (minimal-context colleague test), [GitHub Copilot: Prompt engineering](https://docs.github.com/en/copilot/concepts/prompting/prompt-engineering).
- [ ] A2. "왜" 이 작업이 필요한지, 안 하면 어떤 리스크가 있는지 2-4문장으로 명시한다. 출처: [Anthropic: Be clear and direct](https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/be-clear-and-direct) — end goal을 주면 성능이 향상된다.

(A3 `범위/비범위/제약/금지사항 별도 섹션`은 아래 Informational로 이동 — create-issue/write-handoff 기본 템플릿이 해당 섹션을 별도로 강제하지 않으므로 Normative에서 제외.)

### B. 근거 / 레퍼런스 (Evidence-first)

- [ ] B1. 비자명한 주장에 인라인 citation을 붙인다 (`[링크 텍스트](URL)`). `write-handoff`는 가이드 본문 인라인에 붙이고, `create-issue`는 필수 `References` 섹션에서 출처 링크 목록으로 제공한다. 출처: [Anthropic: Reduce hallucinations](https://docs.anthropic.com/en/docs/test-and-evaluate/strengthen-guardrails/reduce-hallucinations), [Learning Fine-Grained Grounded Citations (ACL Findings 2024)](https://aclanthology.org/2024.findings-acl.838/).
- [ ] B4. 파일/함수/PR/doc URL은 본문에 직접 적는다 (예: `path/to/file.nix:42`, `#123`). commit hash 약식 인용은 PR 번호나 머지된 long SHA 같은 안정적 식별자로 대체한다. 관련 감지 패턴의 실존 SSOT는 [`../../../lib/pinning-patterns.sh`](../../../lib/pinning-patterns.sh)이며, checklist 본문은 prose 가이드로 직접 점검한다. 출처: [Anthropic: Best Practices for Claude Code (2025)](https://code.claude.com/docs/en/best-practices).

### C. PoC / 재현 (Reproducibility-first)

- [ ] C1. 재현이 중요한 주장에는 최소 재현 절차 6필드를 포함한다: `환경 / 입력 / 절차 / 기대 결과 / 실제 결과 / 성공 기준`. 출처: [OpenAI Evals: Structured Outputs Evaluation (2025)](https://cookbook.openai.com/examples/evaluation/use-cases/structured-outputs-evaluation), [PROMPTEVALS (NAACL 2025)](https://aclanthology.org/2025.naacl-long.213/).
- [ ] C3. 구체적 치환이 확정된 `write-handoff`에는 BEFORE/AFTER를 사용한다. 구현이 미결정이면 목표·제약·수용 기준을 제시한다.

### D. 구조 (Structuring)

- [ ] D1. `write-handoff` 가이드 상단 10줄 이내에 TL;DR (상황/현재 상태/다음 액션/Blockers 4슬롯)을 둔다. 출처: [Lost in the Middle (TACL 2024)](https://direct.mit.edu/tacl/article/doi/10.1162/tacl_a_00638/119630/Lost-in-the-Middle-How-Language-Models-Use-Long) — 중간 정보는 활용률이 낮고 앞/뒤 정보에 강함.

### E. Anti-hallucination (Evidence-gated)

- [ ] E1. 근거가 없거나 확신 없는 주장은 `[UNVERIFIED]` 라벨을 붙이거나 삭제한다. 출처: [Anthropic: Reduce hallucinations](https://docs.anthropic.com/en/docs/test-and-evaluate/strengthen-guardrails/reduce-hallucinations), [MetaFaith (EMNLP 2025)](https://aclanthology.org/2025.emnlp-main.1505/) — faithful uncertainty 표현이 개선됨.

  ❌ BAD: `"이 옵션은 Claude Code 2.0+에서 동작한다."` _(why: 버전별 동작은 공식 docs 또는 로컬 재현 없이 단정 불가 — hallucination 위험)_

  ✅ GOOD: `"Claude Code 2.1.104에서 동작 확인. [UNVERIFIED] 이전 버전 호환성은 미확인."`
- [ ] E2. 이번 작업에서 확보한 직접 근거를 재사용한다. 출처가 없거나 서로 충돌하거나 이후 상태가 달라질 수 있는 주장만 추가 확인한다. 확인할 수 없으면 불확실성을 표시하거나 삭제한다. 두 스킬 모두 적용하며, 공개 sanitization 검사는 별도로 유지한다.

  ❌ BAD: `"확인하지 않은 API 동작을 단정하여 게시."`

  ✅ GOOD: `"직접 확인한 코드 근거는 재사용하고, 이후 바뀐 원격 상태만 조회해 본문을 갱신한 뒤 최종 sanitization 후 게시."`

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

> 단일 진실 원천. `create-issue`/`write-handoff`는 이 섹션을 참조한다. 규칙 변경 시 이 섹션을 먼저 수정하고, 소비자 문서의 요약 문구/포인터도 함께 점검한다.

이슈/이행가이드/계획/리뷰 finding 작성 중 다음 라벨을 사용한다:

| 라벨 | 의미 | 사용 예시 |
|------|------|----------|
| (없음) | 직접 확인된 사실 | 파일을 직접 Read로 확인 후 기술한 내용 |
| `[UNVERIFIED]` | 근거 링크 또는 직접 확인 없이 쓴 주장 | `[UNVERIFIED]` Claude Code skill discovery가 `_shared/` 디렉토리를 스킬로 오인할 수 있음 |
| `[INFERRED]` | 근접한 근거로부터의 추론 (직접 근거 아님) | `[INFERRED]` PoC 첨부가 hallucination을 줄인다는 정량 연구는 없으나, reproducibility-first의 인접 근거에서 강하게 추론됨 |
| `[CONFLICTING]` | 두 개 이상 출처가 상충 | `[CONFLICTING]` FRONT(2024)는 pipeline 분리 우위를 보고, Evaluating Design Choices(2025)는 direct generation 우위를 보고 |

DEPRECATED: `<!-- 미검증: ... -->` HTML 주석은 더 이상 권장되지 않는다. 신규 산출물은 `[UNVERIFIED]` 라벨을 사용한다. 기존 산출물은 점진적으로 마이그레이션한다.

---

## 근거 확인 기준 (E2)

초안의 비자명 주장에 이번 작업에서 확보한 출처를 연결한다. 근거가 충분하고 현재 상태와 맞으면 그대로 사용한다. 출처 부재·상충·관측 이후 상태 변경 가능성이 있는 부분만 파일/검색/원격 조회로 보완하고, 불일치는 수정하며 확인 불가는 라벨 또는 삭제로 처리한다. 같은 근거를 형식적인 독립 질문으로 바꿔 재조회하지 않는다.

과거 E2는 [Chain-of-Verification](https://arxiv.org/abs/2309.11495)과 [Self-Alignment for Factuality](https://aclanthology.org/2024.acl-long.107/)를 배경으로 모든 주장을 독립 질문으로 재검증했다. 현재 E2는 근거 보존과 불확실성 처리를 유지하면서 추가 확인이 필요한 주장에만 조회를 적용한다. 이 변경은 게시 직전 최종 본문의 민감정보 검사를 생략하는 근거가 아니다.

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

- [Chain-of-Verification (arXiv 2309.11495)](https://arxiv.org/abs/2309.11495) — 과거 E2의 독립 재검증 절차 배경.
- [Lost in the Middle (TACL 2024)](https://direct.mit.edu/tacl/article/doi/10.1162/tacl_a_00638/119630/Lost-in-the-Middle-How-Language-Models-Use-Long) — primacy bias (D1).
- [Learning Fine-Grained Grounded Citations (ACL Findings 2024)](https://aclanthology.org/2024.findings-acl.838/) — fine-grained quote grounding (B1).
- [Self-Alignment for Factuality (ACL 2024)](https://aclanthology.org/2024.acl-long.107/) — 과거 E2의 factuality 검증 배경.
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
