#!/usr/bin/env bash
# codex-sync: Claude Code 하니스를 Codex CLI 구조로 재투영
# 사용법:
#   codex-sync [project-root]

set -euo pipefail

_die() {
  echo "error: $*" >&2
  exit 1
}

_warn() {
  echo "warning: $*" >&2
}

_usage() {
  cat <<'EOF'
사용법:
  codex-sync [project-root]

인자:
  project-root  동기화 대상 프로젝트 루트 (기본값: 현재 작업 디렉토리)
EOF
}

_resolve_sync_sh() {
  local candidates=(
    "$HOME/.claude/skills/syncing-codex-harness/references/sync.sh"
    "$HOME/.codex/skills/syncing-codex-harness/references/sync.sh"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

_canonical_project_root() {
  local input="${1:-$PWD}"
  [[ -d "$input" ]] || _die "프로젝트 디렉토리가 없습니다: $input"
  (cd "$input" && pwd -P)
}

main() {
  if (( $# > 1 )); then
    _die "인자는 최대 1개만 허용됩니다"
  fi

  case "${1:-}" in
    -h|--help)
      _usage
      exit 0
      ;;
  esac

  local project_root sync_sh
  project_root=$(_canonical_project_root "${1:-$PWD}")
  sync_sh=$(_resolve_sync_sh) || _die "sync.sh를 찾을 수 없습니다 (~/.claude 또는 ~/.codex)"

  local -a args=()

  if [[ -d "$project_root/.claude/skills" ]]; then
    args+=(--local-skills-dir=.claude/skills)
  fi

  if [[ -f "$HOME/.claude/mcp.json" ]]; then
    args+=(--user-mcp="$HOME/.claude/mcp.json")
  else
    _warn "$HOME/.claude/mcp.json 이 없어 user-scope MCP sync를 건너뜁니다"
  fi

  local plugin_lines
  plugin_lines="$(
    PROJECT_ROOT="$project_root" python3 <<'PY'
import json
import os
import sys
from pathlib import Path


def load_json(path: Path):
    try:
        with path.open() as f:
            return json.load(f)
    except Exception as exc:
        print(f"warning: JSON parse failed: {path}: {exc}", file=sys.stderr)
        return None


def enabled_plugins(payload):
    if not isinstance(payload, dict):
        return []
    plugins = payload.get("enabledPlugins", {})
    if not isinstance(plugins, dict):
        return []
    return [key for key, value in plugins.items() if value]


project_root = Path(os.environ["PROJECT_ROOT"]).resolve()
home = Path.home()

plugin_keys = []
local_settings = project_root / ".claude" / "settings.local.json"
if local_settings.is_file():
    payload = load_json(local_settings)
    plugin_keys = enabled_plugins(payload)

if not plugin_keys:
    user_settings = home / ".claude" / "settings.json"
    if user_settings.is_file():
        payload = load_json(user_settings)
        plugin_keys = enabled_plugins(payload)

manifest_path = home / ".claude" / "plugins" / "installed_plugins.json"
manifest = load_json(manifest_path) if manifest_path.is_file() else None
plugins = manifest.get("plugins", {}) if isinstance(manifest, dict) else {}

plugin_claude_md = None
for plugin_key in plugin_keys:
    entries = plugins.get(plugin_key, [])
    if not isinstance(entries, list):
        continue

    local_path = None
    user_path = None
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        install_path = entry.get("installPath")
        if not install_path:
            continue

        scope = entry.get("scope", "")
        if scope == "local":
            project_path = entry.get("projectPath", "")
            try:
                if project_path and Path(project_path).resolve() == project_root:
                    local_path = install_path
            except OSError:
                pass
        elif scope == "user" and user_path is None:
            user_path = install_path

    resolved = local_path or user_path
    if not resolved:
        print(f"warning: installPath 해석 실패: {plugin_key}", file=sys.stderr)
        continue

    resolved_path = Path(resolved)
    if not resolved_path.is_dir():
        print(f"warning: plugin path not found: {resolved_path}", file=sys.stderr)
        continue

    plugin_name = plugin_key.split("@", 1)[0]
    print(f"PLUGIN\t{resolved_path}\t{plugin_name}")

    plugin_md = resolved_path / "CLAUDE.md"
    if plugin_claude_md is None and not (project_root / "CLAUDE.md").exists() and plugin_md.is_file():
        plugin_claude_md = plugin_md

if plugin_claude_md is not None:
    print(f"CLAUDE_MD\t{plugin_claude_md}")
PY
  )"

  if [[ -n "$plugin_lines" ]]; then
    while IFS=$'\t' read -r kind first second; do
      [[ -n "$kind" ]] || continue
      case "$kind" in
        PLUGIN)
          args+=(--plugin-install-path="${first}:${second}")
          ;;
        CLAUDE_MD)
          args+=(--plugin-claude-md="${first}")
          ;;
      esac
    done <<< "$plugin_lines"
  fi

  (
    cd "$project_root"
    bash "$sync_sh" all "$project_root" "${args[@]}"
  )
}

main "$@"
