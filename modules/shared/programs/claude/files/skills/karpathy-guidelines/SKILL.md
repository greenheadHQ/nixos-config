---
name: karpathy-guidelines
description: >-
  This skill should be used when writing, reviewing, or refactoring code
  to reduce common LLM coding mistakes. It provides behavioral guidelines
  to avoid overcomplication, make surgical changes, surface assumptions,
  and define verifiable success criteria.
  Triggers: "karpathy", "coding guidelines", "코딩 가이드라인", "과잉 엔지니어링",
  "overcomplicated", "simplify code", "surgical changes", "write code",
  "implement feature", "fix bug", "refactor", "review code",
  "코드 작성", "코드 리뷰", "버그 수정", "리팩터링".
license: MIT
---

<!-- ============================================================
  출처: https://github.com/forrestchang/andrej-karpathy-skills
  원본: Andrej Karpathy의 LLM 코딩 실수 관찰 (https://x.com/karpathy/status/2015883857489522876)
  라이선스: MIT
  Vendor 시점: 2026-02-18
  주의: 이 파일은 원본 저장소의 CLAUDE.md + SKILL.md 내용을 통합한 것입니다.
        업스트림 변경 사항은 자동 반영되지 않으므로, 필요 시 원본 저장소를 수동 확인하세요.
============================================================ -->

# Karpathy Guidelines

Behavioral guidelines to reduce common LLM coding mistakes, derived from
[Andrej Karpathy's observations](https://x.com/karpathy/status/2015883857489522876)
on LLM coding pitfalls.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.

**상세 예제:** `references/EXAMPLES.md` 참조 — 각 원칙에 대한 실제 코드 예제 (잘못된 접근 vs 올바른 접근)
