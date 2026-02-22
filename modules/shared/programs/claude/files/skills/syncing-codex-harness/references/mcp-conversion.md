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

If file exists: replace only `[mcp_servers.*]` sections, preserve other settings.
If file doesn't exist: create with MCP sections only.

## TOML Encoding

Values must be properly escaped for TOML basic strings (double-quoted):

```python
def toml_escape_value(s):
    """Escape a string value for TOML basic string (double-quoted)."""
    s = s.replace('\\', '\\\\')   # backslash first
    s = s.replace('"', '\\"')
    s = s.replace('\n', '\\n')
    s = s.replace('\r', '\\r')
    s = s.replace('\t', '\\t')
    return s

def toml_key(name):
    """Quote a TOML key if it contains dots or special chars."""
    if '.' in name or '"' in name or ' ' in name:
        return '"' + name.replace('\\', '\\\\').replace('"', '\\"') + '"'
    return name
```

Apply `toml_escape_value()` to all string values: `command`, `url`, each `args` element, each `env` value.
Apply `toml_key()` to server names in section headers (e.g., `[mcp_servers.{toml_key(name)}]`).

## Existing config.toml Preservation

When `.codex/config.toml` already exists with non-MCP settings, only the `[mcp_servers.*]` sections should be replaced. Use Python regex to strip existing MCP sections, then append new ones:

```python
import re

def replace_mcp_sections(existing_toml: str, new_mcp_toml: str) -> str:
    cleaned = re.sub(r'\n?\[mcp_servers[^\]]*\][^\[]*', '', existing_toml)
    return cleaned.rstrip() + '\n' + new_mcp_toml + '\n'
```

## Merging Multiple Sources

When both project and plugin MCP configs exist, merge all servers into a single target config.
If server names conflict, prefix plugin servers with `{plugin-name}--`.

User MCP (`--user-mcp`) is merged the same way and can target user config directly.
