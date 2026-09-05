---
name: syncing-codex-harness
disable-model-invocation: true
description: >-
  Retired skill kept only as a redirect stub. It performs no action of its own.
  Harness projection (AGENTS.md, .agents/skills, MCP config) is owned by configuring-codex.
  Do not invoke this skill; route the request to configuring-codex instead.
---

# syncing-codex-harness (retired)

This skill is retired and has no procedure of its own.

- Replacement: `configuring-codex` — harness projection, AGENTS.md, `.agents/skills` symlinks, MCP config.
- Any request that lands here should be handled by the replacement.
- The stub exists so that tooling still referencing the old name resolves to a current pointer.
