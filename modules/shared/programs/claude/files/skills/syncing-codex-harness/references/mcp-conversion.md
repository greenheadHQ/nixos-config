# MCP Conversion: .mcp.json -> .codex/config.toml

## Overview

Claude Code uses `.mcp.json` (JSON) for MCP server configuration.
Codex CLI uses `.codex/config.toml` with `[mcp_servers.*]` sections (TOML).

Reference: https://developers.openai.com/codex/mcp/

## Two Sources

### 1. Project root `.mcp.json`

No `${CLAUDE_PLUGIN_ROOT}` substitution needed. Paths are already absolute or relative to project.

### 2. Plugin `.mcp.json` (`{installPath}/.mcp.json`)

`${CLAUDE_PLUGIN_ROOT}` must be replaced with the plugin's `installPath` absolute path.

## Conversion Rules

### stdio type (command + args)

```json
{
  "server-name": {
    "command": "node",
    "args": ["path/to/index.js", "--flag"]
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

Write to `.codex/config.toml`:
- If file exists: replace only `[mcp_servers.*]` sections, preserve other settings
- If file doesn't exist: create with MCP sections only

## Merging Multiple Sources

When both project and plugin MCP configs exist, merge all servers into a single `.codex/config.toml`.
If server names conflict, prefix plugin servers with `{plugin-name}--`.
