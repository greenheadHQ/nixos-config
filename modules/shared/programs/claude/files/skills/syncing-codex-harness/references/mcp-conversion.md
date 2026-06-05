# MCP Conversion: Claude MCP JSON -> Codex config.toml

## Overview

Claude Code uses `.mcp.json` or `~/.claude/mcp.json` (JSON) for MCP server configuration.
Codex CLI uses `.codex/config.toml` with `[mcp_servers.*]` sections (TOML).

Reference: https://developers.openai.com/codex/mcp/

## Two Sources

### 1. Project root `.mcp.json`

No `${CLAUDE_PLUGIN_ROOT}` substitution needed. Paths are already absolute or relative to project.

### 2. Plugin `.mcp.json` (`{installPath}/.mcp.json`)

`${CLAUDE_PLUGIN_ROOT}` must be replaced with the plugin's `installPath` absolute path.

### 3. User-scope `~/.claude/mcp.json`

No `${CLAUDE_PLUGIN_ROOT}` substitution needed. Convert all servers inside the `mcpServers` wrapper object.

## Conversion Rules

### stdio type (command + args)

```json
{
  "mcpServers": {
    "server-name": {
      "command": "node",
      "args": ["path/to/index.js", "--flag"]
    }
  }
}
```

->

```toml
[mcp_servers.server-name]
command = "node"
args = ["path/to/index.js", "--flag"]
```

### http type (url)

```json
{
  "server-name": {
    "type": "http",
    "url": "http://127.0.0.1:3845/mcp"
  }
}
```

->

```toml
[mcp_servers.server-name]
url = "http://127.0.0.1:3845/mcp"
```

### Environment variables (env)

```json
{
  "server-name": {
    "command": "npx",
    "args": ["-y", "some-mcp-server"],
    "env": {
      "API_KEY": "sk-xxx"
    }
  }
}
```

->

```toml
[mcp_servers.server-name]
command = "npx"
args = ["-y", "some-mcp-server"]

[mcp_servers.server-name.env]
API_KEY = "sk-xxx"
```

## ${CLAUDE_PLUGIN_ROOT} Substitution

For plugin MCP configs, replace all occurrences of `${CLAUDE_PLUGIN_ROOT}` with the plugin's absolute `installPath`.

Example:
- installPath: `/Users/glen/.claude/plugins/cache/example-plugins/example-front/1.5.2`
- Before: `"${CLAUDE_PLUGIN_ROOT}/mcp-server/dist/index.js"`
- After: `"/Users/glen/.claude/plugins/cache/example-plugins/example-front/1.5.2/mcp-server/dist/index.js"`

## Output File

Write target:
- project-scope: `.codex/config.toml`
- user-scope: `~/.codex/config.toml` (or the path specified via `--user-codex-config`)

Project/plugin source and user source are target-specific and must not be mixed
in one `mcp-config` call.

- project-scope: update the codex-sync managed MCP block from project/plugin sources,
  and replace existing entries with the same server names. Preserve unmanaged
  project-local MCP entries outside the marker block. Root inline
  `mcp_servers = { ... }` tables fail fast because they cannot be safely merged
  with the line-oriented writer.
- user-scope: replace only the server names present in `--user-mcp`, preserving other
  `[mcp_servers.*]` sections and non-MCP settings. Root inline
  `mcp_servers = { ... }` tables fail fast because they cannot be safely merged
  with the line-oriented writer. Names declared by the active platform Codex
  config template are activation-owned and fail fast on collision.
- write via same-directory tempfile, mode `0600`, and atomic rename.

## TOML Encoding

Values must be properly escaped for TOML basic strings (double-quoted):

Apply TOML basic-string escaping to all string values: `command`, `url`, each
`args` element, and each `env` value. Server names in section headers must be
rendered through the helper in `sync.sh`; do not duplicate its quoting logic in
this reference.

## Existing config.toml Preservation

The canonical merge/write contract lives in `../SKILL.md` under
"계약 참고: user-scope `sync.sh` vs activation writer". Keep this reference
summary aligned with that section rather than duplicating implementation
pseudocode here.

## Merging Multiple Sources

When both project and plugin MCP configs exist, merge all servers into a single project target config.
If server names conflict, prefix plugin servers with `{plugin-name}--`.

User MCP (`--user-mcp`) is a separate user target operation. It is not combined
with project/plugin sources.
