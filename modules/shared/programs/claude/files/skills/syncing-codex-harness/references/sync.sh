#!/usr/bin/env bash
# sync.sh — Claude Code → Codex CLI harness projection
# Usage:
#   sync.sh init              <project-root>
#   sync.sh project-skills    <source-skills-dir> <target-skills-dir>
#   sync.sh plugin-skills     <source-skills-dir> <target-skills-dir> [--plugin-name=NAME]
#   sync.sh agents            <source-agents-dir> <target-agents-dir>
#   sync.sh agents-md         <project-root> [plugin-claude-md-path]
#   sync.sh agents-override   <project-root> [--plugin-install-path=PATH:NAME]...
#   sync.sh mcp-config        <project-root> [--project-mcp=PATH] [--plugin-mcp=PATH:INSTALL_PATH:NAME]... [--user-mcp=PATH] [--user-codex-config=PATH]
#   sync.sh trust-project     <project-root>
#   sync.sh gitignore-check   <project-root>
#   sync.sh all               <project-root> [--local-skills-dir=DIR] [--plugin-install-path=PATH:NAME]... [--plugin-claude-md=PATH] [--user-mcp=PATH] [--user-codex-config=PATH]

set -euo pipefail

# Requires UTF-8 locale for correct multibyte handling (${var:0:N})

# ─── project-skills: project local skills projection ───
# Codex CLI는 디렉토리 심링크를 따라감 (PR #8801)
# 파일 심링크는 무시하므로 반드시 디렉토리 단위로 심링크
# Claude Code 전용 스킬은 Codex 프로젝션에서 제외 (자기 참조 방지, #212)
#
# NOTE (#486): 아래 변수는 repo-local `.claude/skills/` → `.agents/skills/` 투영 축 전용이다.
# shared global `~/.codex/skills/` exposure 정책(exposedCodexSkills / intentionallyNotExposed)과 별개의 축이며,
# shared 정책의 SoT는 `modules/shared/programs/codex/default.nix`의 exposedCodexSkills /
# intentionallyNotExposed 리스트다. 이 값은 동일 프로젝트의 default.nix activation script의
# CODEX_EXCLUDE_SKILLS와 정렬한다.
CODEX_EXCLUDE_SKILLS="using-codex-exec"

project_skills() {
  local source_dir="$1"
  local target_dir="$2"
  local count=0

  # 상대경로 계산: target_dir(.agents/skills) → source_dir(.claude/skills)
  local project_root
  project_root="$(cd "$target_dir/../.." && pwd)"
  local source_from_root="${source_dir#"$project_root"/}"

  for source_skill_dir in "$source_dir"/*/; do
    [ -d "$source_skill_dir" ] || continue
    [ -f "$source_skill_dir/SKILL.md" ] || continue

    local skill_name
    skill_name="$(basename "$source_skill_dir")"

    # Claude Code 전용 스킬 제외
    case " $CODEX_EXCLUDE_SKILLS " in
      *" $skill_name "*) continue ;;
    esac
    local target_link="$target_dir/$skill_name"
    local rel_target="../../$source_from_root/$skill_name"

    # 이미 올바른 심링크면 스킵
    if [ -L "$target_link" ] && [ "$(readlink "$target_link")" = "$rel_target" ]; then
      count=$((count + 1))
      continue
    fi

    # 레거시 실디렉토리 또는 잘못된 심링크 제거 후 생성
    rm -rf "$target_link"
    ln -sfn "$rel_target" "$target_link"

    count=$((count + 1))
  done

  echo "$count"
}

# ─── plugin-skills: plugin skills projection ───
# 플러그인은 프로젝트 외부에 있으므로 절대경로 디렉토리 심링크 사용
plugin_skills() {
  local source_dir="$1"
  local target_dir="$2"
  local plugin_name="${3:-}"

  if [ ! -d "$source_dir" ]; then
    echo "Warning: Plugin skills directory not found: $source_dir" >&2
    echo "0"
    return
  fi

  local count=0

  for source_skill_dir in "$source_dir"/*/; do
    [ -d "$source_skill_dir" ] || continue
    [ -f "$source_skill_dir/SKILL.md" ] || continue

    local skill_name
    skill_name="$(basename "$source_skill_dir")"

    # Check for name collision with existing skills
    local final_name="$skill_name"
    if [ -n "$plugin_name" ] && { [ -d "$target_dir/$skill_name" ] || [ -L "$target_dir/$skill_name" ]; }; then
      final_name="${plugin_name}--${skill_name}"
    fi
    local target_link="$target_dir/$final_name"

    # 절대경로 디렉토리 심링크
    local abs_target
    abs_target="$(cd "$source_skill_dir" && pwd)"

    # 이미 올바른 심링크면 스킵
    if [ -L "$target_link" ] && [ "$(readlink "$target_link")" = "$abs_target" ]; then
      count=$((count + 1))
      continue
    fi

    rm -rf "$target_link"
    ln -sfn "$abs_target" "$target_link"

    count=$((count + 1))
  done

  echo "$count"
}

# ─── agents: agent files projection ───
copy_agents() {
  local source_dir="$1"
  local target_dir="$2"
  local count=0

  if [ ! -d "$source_dir" ]; then
    echo "Warning: Agents directory not found: $source_dir" >&2
    echo "0"
    return
  fi

  for agent_file in "$source_dir"/*.md; do
    [ -f "$agent_file" ] || continue
    local fname
    fname="$(basename "$agent_file")"
    cp "$agent_file" "$target_dir/$fname"
    count=$((count + 1))
  done

  echo "$count"
}

# ─── init: clean .agents/ and prepare ───
init_agents_dir() {
  local project_root="$1"
  rm -rf "$project_root/.agents/"
  mkdir -p "$project_root/.agents/skills"
  mkdir -p "$project_root/.codex"
  # CIR: clear stale repo-local hook artifacts left behind by the retired
  # Claude-to-Codex projection path so old worktrees cannot invoke removed hooks.
  rm -f "$project_root/.codex/hooks.json" "$project_root/.codex/hooks.compatibility.json"
}

# ─── gitignore-check: check entries ───
# All Codex projection artifacts (.agents/, .codex/, AGENTS.md, AGENTS.override.md)
# are expected in global gitignore (see git/default.nix).
# This function verifies they are actually ignored (via global or project gitignore).
gitignore_check() {
  local project_root="$1"
  local missing=()
  local entries=(".agents/" ".codex/" "AGENTS.md" "AGENTS.override.md")

  if git -C "$project_root" rev-parse --git-dir >/dev/null 2>&1; then
    for entry in "${entries[@]}"; do
      if ! git -C "$project_root" check-ignore -q "$entry" 2>/dev/null; then
        missing+=("$entry")
      fi
    done
  else
    # Fallback for non-git directories
    local gitignore="$project_root/.gitignore"
    if [ ! -f "$gitignore" ]; then
      printf '%s\n' "${entries[@]}"
      return
    fi
    for entry in "${entries[@]}"; do
      if ! grep -qxF "$entry" "$gitignore" 2>/dev/null; then
        missing+=("$entry")
      fi
    done
  fi

  if [ ${#missing[@]} -gt 0 ]; then
    printf '%s\n' "${missing[@]}"
  fi
}

# ─── agents-md: create AGENTS.md ───
agents_md() {
  local project_root="$1"
  local plugin_claude_md="${2:-}"

  if [ -e "$project_root/CLAUDE.md" ]; then
    # Project has CLAUDE.md (or valid symlink) -> symlink
    ln -sfn "CLAUDE.md" "$project_root/AGENTS.md"
    echo "symlinked"
  elif [ -n "$plugin_claude_md" ] && [ -f "$plugin_claude_md" ]; then
    # Plugin provides CLAUDE.md -> copy
    cp "$plugin_claude_md" "$project_root/AGENTS.md"
    echo "copied"
  else
    echo "Warning: No CLAUDE.md found. AGENTS.md not created." >&2
    echo "skipped"
  fi
}

# ─── agents-override: generate AGENTS.override.md ───
agents_override() {
  local project_root="$1"
  shift
  local override_file="$project_root/AGENTS.override.md"

  # Parse --plugin-install-path=PATH:NAME arguments
  local plugin_paths=()
  local plugin_names=()
  for arg in "$@"; do
    case "$arg" in
      --plugin-install-path=*)
        local val="${arg#--plugin-install-path=}"
        plugin_paths+=("${val%%:*}")
        plugin_names+=("${val#*:}")
        ;;
    esac
  done

  # Build auto-generated content
  local auto_content=""
  local rule_count=0

  for i in "${!plugin_paths[@]}"; do
    local ipath="${plugin_paths[$i]}"

    # Rules from plugin
    if [ -d "$ipath/rules" ]; then
      for rule_file in "$ipath/rules/"*.md; do
        [ -f "$rule_file" ] || continue
        local rule_name
        rule_name="$(basename "$rule_file" .md)"
        # Strip YAML frontmatter
        local body
        body="$(awk '
          BEGIN { in_fm=0; past_fm=0 }
          /^---[[:space:]]*$/ {
            if (!past_fm && in_fm==0) { in_fm=1; next }
            if (in_fm==1) { past_fm=1; next }
          }
          past_fm || !in_fm { print }
        ' "$rule_file")"
        auto_content+="## Rule: ${rule_name}"$'\n\n'"${body}"$'\n'
        rule_count=$((rule_count + 1))
      done
    fi
  done

  # Codex common supplement
  auto_content+=$'\n'"## 스킬 사용"$'\n\n'
  auto_content+="- \`.agents/skills/\`에서 스킬이 자동 발견된다"$'\n'
  auto_content+="- \`/skill-name\`은 Codex에서 \`\$skill-name\`에 대응"$'\n'

  auto_content+=$'\n'"## 도구 차이"$'\n\n'
  auto_content+="- Claude Code 전용 plugin/MCP UI surface는 Codex에서 그대로 대응되지 않는다"$'\n'
  auto_content+="- 런타임 경로는 3-way: **Codex 세션**(native subagent) / **Claude Code 세션**(codex exec 기본 → Agent tool fallback) / **headless 세션**(codex exec). 상세는 run-da/references/runtime-mapping.md의 \`런타임 도구 매핑\` 참조"$'\n'
  auto_content+="- Codex 세션에서 review/audit/planning fan-out 시 nested \`codex exec\`보다 native subagent 경로를 우선한다"$'\n'
  auto_content+="- \`\$plan-with-questions\`, \`\$run-da\`, \`\$parallel-audit\` 등 fan-out 스킬 호출은 해당 스킬이 문서화한 범위의 내부 native subagent fan-out에 대한 explicit delegation으로 본다. \`codex-exec-supervised\` fallback은 native delegation 거부/미지원 시 별도 사용자 승인 후에만 사용한다."$'\n'
  auto_content+="- \`CODEX_CI=1\`만으로 세션 유형을 구분하지 않는다"$'\n'
  auto_content+="- current session의 open agent thread cap(\`agents.max_threads\`, unset 기본 6)을 넘기지 말고, completed agent thread는 다음 round/retry 전에 close한다"$'\n'
  auto_content+="- repository-specific Codex 세션 authority boundaries, write rules, and lock-sensitive command rules은 project-local skill docs 또는 \`AGENTS.override.md\` custom section에 둔다"$'\n'
  auto_content+="- SKILL.md의 \`allowed-tools\` frontmatter는 Codex에서 무시됨"$'\n'

  local start_marker="<!-- AUTO-GENERATED BY syncing-codex-harness -->"
  local end_marker="<!-- END AUTO-GENERATED BY syncing-codex-harness -->"

  if [ -f "$override_file" ]; then
    if grep -qxF "$start_marker" "$override_file" && grep -qxF "$end_marker" "$override_file"; then
      # Replace between markers, preserve content outside
      local new_content
      new_content="$(awk -v start="$start_marker" -v end="$end_marker" \
        -v replacement="$auto_content" '
        $0 == start { print; printf "%s", replacement; skip=1; next }
        $0 == end   { skip=0; print; next }
        !skip { print }
      ' "$override_file")"
      printf '%s\n' "$new_content" > "$override_file"
    else
      local legacy_preserved
      legacy_preserved="$(sed -E 's/^(#+)([[:space:]])/\1#\2/' "$override_file")"
      cat > "$override_file" <<OVERRIDE
# Codex CLI 보충 규칙

## 이 파일의 역할

AGENTS.md의 프로젝트 규칙을 모두 따르되, 아래는 Codex 전용 보충이다.

${start_marker}
${auto_content}${end_marker}

## 사용자 커스텀

### Legacy Markerless Content

아래는 markerless \`AGENTS.override.md\`에서 활성 custom content로 이행한 원문이다. 중복 규칙이 있으면 이후 수동으로 정리하라.

${legacy_preserved}
OVERRIDE
    fi
  else
    # Create new from template
    cat > "$override_file" <<OVERRIDE
# Codex CLI 보충 규칙

## 이 파일의 역할

AGENTS.md의 프로젝트 규칙을 모두 따르되, 아래는 Codex 전용 보충이다.

${start_marker}
${auto_content}${end_marker}

## 사용자 커스텀

(여기에 Codex 전용 사용자 규칙을 추가할 수 있습니다 — 동기화 시 보존됩니다)
OVERRIDE
  fi

  echo "$rule_count"
}

# ─── mcp-config: generate MCP sections in target config.toml ───
# default target: <project-root>/.codex/config.toml
# user target (--user-mcp): $HOME/.codex/config.toml or --user-codex-config=PATH
mcp_config() {
  local project_root="$1"
  shift
  local config_file="$project_root/.codex/config.toml"

  # Collect MCP source args
  local project_mcp=""
  local project_mcp_set=0
  local plugin_mcps=()
  local plugin_mcp_paths=()
  local plugin_mcp_installs=()
  local plugin_mcp_names=()
  local user_mcp=""
  local user_mcp_set=0
  local user_codex_config=""
  for arg in "$@"; do
    case "$arg" in
      --project-mcp=*) project_mcp="${arg#--project-mcp=}"; project_mcp_set=1 ;;
      --plugin-mcp=*)  plugin_mcps+=("${arg#--plugin-mcp=}") ;;
      --user-mcp=*) user_mcp="${arg#--user-mcp=}"; user_mcp_set=1 ;;
      --user-codex-config=*) user_codex_config="${arg#--user-codex-config=}" ;;
    esac
  done

  if [ "$project_mcp_set" -eq 0 ] && [ "$user_mcp_set" -eq 0 ] && [ "${#plugin_mcps[@]}" -eq 0 ]; then
    echo "sync.sh mcp-config: at least one source option (--project-mcp/--plugin-mcp/--user-mcp) required" >&2
    echo "Usage: sync.sh mcp-config <project-root> [--project-mcp=PATH] [--plugin-mcp=PATH:INSTALL_PATH:NAME]... [--user-mcp=PATH] [--user-codex-config=PATH]" >&2
    return 1
  fi
  if [ "$project_mcp_set" -eq 1 ] && [ ! -f "$project_mcp" ]; then
    echo "sync.sh mcp-config: --project-mcp source missing: ${project_mcp:-<empty>} (create the file or omit --project-mcp)" >&2
    return 1
  fi
  if [ "$user_mcp_set" -eq 1 ] && [ ! -f "$user_mcp" ]; then
    echo "sync.sh mcp-config: --user-mcp source missing: ${user_mcp:-<empty>} (create the file or omit --user-mcp)" >&2
    return 1
  fi
  for pm in "${plugin_mcps[@]}"; do
    local plugin_mcp_path="${pm%%:*}"
    local plugin_mcp_rest="${pm#*:}"
    local plugin_mcp_install="${plugin_mcp_rest%%:*}"
    local plugin_mcp_name="${plugin_mcp_rest#*:}"
    if [ "$plugin_mcp_rest" = "$pm" ] || [ "$plugin_mcp_name" = "$plugin_mcp_rest" ] \
      || [[ "$plugin_mcp_name" == *:* ]] \
      || [ -z "$plugin_mcp_path" ] || [ -z "$plugin_mcp_install" ] || [ -z "$plugin_mcp_name" ]; then
      echo "sync.sh mcp-config: malformed --plugin-mcp source: ${pm:-<empty>} (expected PATH:INSTALL_PATH:NAME)" >&2
      return 1
    fi
    if [ ! -f "$plugin_mcp_path" ]; then
      echo "sync.sh mcp-config: --plugin-mcp source missing: $plugin_mcp_path (create the file or omit --plugin-mcp)" >&2
      return 1
    fi
    plugin_mcp_paths+=("$plugin_mcp_path")
    plugin_mcp_installs+=("$plugin_mcp_install")
    plugin_mcp_names+=("$plugin_mcp_name")
  done

  if [ -n "$user_mcp" ]; then
    config_file="${user_codex_config:-${CODEX_HOME:-$HOME/.codex}/config.toml}"
  elif [ -n "$user_codex_config" ]; then
    config_file="$user_codex_config"
  fi

  mkdir -p "$(dirname "$config_file")"

  # Pass args via environment
  local env_args=()
  env_args+=("CONFIG_FILE=$config_file")
  [ -n "$project_mcp" ] && env_args+=("PROJECT_MCP=$project_mcp")
  [ -n "$user_mcp" ] && env_args+=("USER_MCP=$user_mcp")
  local idx=0
  while [ "$idx" -lt "${#plugin_mcp_paths[@]}" ]; do
    env_args+=("PLUGIN_MCP_PATH_${idx}=${plugin_mcp_paths[$idx]}")
    env_args+=("PLUGIN_MCP_INSTALL_${idx}=${plugin_mcp_installs[$idx]}")
    env_args+=("PLUGIN_MCP_NAME_${idx}=${plugin_mcp_names[$idx]}")
    idx=$((idx + 1))
  done

  local mcp_toml
  mcp_toml="$(env "${env_args[@]}" python3 << 'PYEOF'
import json, os, sys

def toml_escape_value(s):
    s = s.replace('\\', '\\\\')
    s = s.replace('"', '\\"')
    s = s.replace('\n', '\\n')
    s = s.replace('\r', '\\r')
    s = s.replace('\t', '\\t')
    return s

def toml_key(name):
    if '.' in name or '"' in name or ' ' in name:
        return '"' + name.replace('\\', '\\\\').replace('"', '\\"') + '"'
    return name

def load_mcp(path, install_path=None):
    with open(path) as f:
        payload = json.load(f)
    if isinstance(payload, dict) and isinstance(payload.get('mcpServers'), dict):
        servers = payload['mcpServers']
    elif isinstance(payload, dict):
        servers = payload
    else:
        return {}
    result = {}
    for name, cfg in servers.items():
        if not isinstance(cfg, dict):
            continue
        cfg_str = json.dumps(cfg)
        if install_path:
            cfg_str = cfg_str.replace('${CLAUDE_PLUGIN_ROOT}', install_path)
        result[name] = json.loads(cfg_str)
    return result

def server_to_toml(name, cfg):
    key = toml_key(name)
    lines = [f'\n[mcp_servers.{key}]']
    if cfg.get('type') == 'http' and 'url' in cfg:
        lines.append(f'url = "{toml_escape_value(cfg["url"])}"')
    elif 'command' in cfg:
        lines.append(f'command = "{toml_escape_value(cfg["command"])}"')
        if 'args' in cfg:
            args_str = ', '.join(f'"{toml_escape_value(a)}"' for a in cfg['args'])
            lines.append(f'args = [{args_str}]')
    if 'env' in cfg:
        lines.append(f'\n[mcp_servers.{key}.env]')
        for k, v in cfg['env'].items():
            lines.append(f'{k} = "{toml_escape_value(str(v))}"')
    return '\n'.join(lines)

def replace_mcp_sections(existing_toml, new_mcp_toml):
    lines = existing_toml.splitlines()
    result = []
    in_mcp = False  # True while inside [mcp_servers.*] section (skips lines)
    for line in lines:
        stripped = line.lstrip()
        if stripped.startswith('['):
            in_mcp = stripped.startswith('[mcp_servers.')
        if not in_mcp:
            result.append(line)
    cleaned = '\n'.join(result).rstrip()
    if new_mcp_toml.strip():
        return cleaned + '\n' + new_mcp_toml + '\n'
    return cleaned + '\n'

# Collect all servers: (name, cfg, prefix)
all_servers = []

project_mcp = os.environ.get('PROJECT_MCP', '')
if project_mcp and os.path.isfile(project_mcp):
    for name, cfg in load_mcp(project_mcp).items():
        all_servers.append((name, cfg, ''))

user_mcp = os.environ.get('USER_MCP', '')
if user_mcp and os.path.isfile(user_mcp):
    for name, cfg in load_mcp(user_mcp).items():
        all_servers.append((name, cfg, ''))

i = 0
while True:
    mcp_path = os.environ.get(f'PLUGIN_MCP_PATH_{i}', '')
    if not mcp_path:
        break
    ipath = os.environ.get(f'PLUGIN_MCP_INSTALL_{i}', '')
    pname = os.environ.get(f'PLUGIN_MCP_NAME_{i}', '')
    if not ipath or not pname:
        sys.exit(f"sync.sh mcp-config: malformed normalized plugin MCP source at index {i}")
    if not os.path.isfile(mcp_path):
        sys.exit(f"sync.sh mcp-config: --plugin-mcp source missing after validation: {mcp_path}")
    for name, cfg in load_mcp(mcp_path, ipath).items():
        all_servers.append((name, cfg, pname))
    i += 1

# Collision-based prefixing: only prefix when names collide
name_counts = {}
for name, _, _ in all_servers:
    name_counts[name] = name_counts.get(name, 0) + 1

toml_parts = []
# final_name 충돌 시 마지막 소스를 우선 적용하여 TOML 중복 섹션을 방지
resolved_servers = {}
for name, cfg, prefix in all_servers:
    final_name = (prefix + '--' + name) if (name_counts[name] > 1 and prefix) else name
    resolved_servers[final_name] = cfg

for final_name, cfg in resolved_servers.items():
    toml_parts.append(server_to_toml(final_name, cfg))

new_mcp = '\n'.join(toml_parts)

config_path = os.environ.get('CONFIG_FILE', '')
if config_path and os.path.isfile(config_path):
    with open(config_path) as f:
        existing = f.read()
    print(replace_mcp_sections(existing, new_mcp))
else:
    print(new_mcp)
PYEOF
  )"

  printf '%s\n' "$mcp_toml" > "$config_file"
}

# ─── trust-project: ensure project is trusted in global config.toml ───
ensure_project_trusted() {
  local project_root="$1"
  local codex_home="${CODEX_HOME:-$HOME/.codex}"
  local global_config="$codex_home/config.toml"
  mkdir -p "$codex_home"

  PROJECT_ROOT="$project_root" GLOBAL_CONFIG="$global_config" python3 << 'PYEOF'
import os, sys

project_path = os.environ["PROJECT_ROOT"].rstrip("/")
config_path = os.environ["GLOBAL_CONFIG"]

content = ""
if os.path.isfile(config_path):
    with open(config_path) as f:
        content = f.read()

if f'[projects."{project_path}"]' in content:
    print("already-trusted")
    sys.exit(0)

with open(config_path, "a") as f:
    f.write(f'\n[projects."{project_path}"]\ntrust_level = "trusted"\n')
print("trusted")
PYEOF
}

# ─── all: full sync pipeline ───
sync_all() {
  local project_root="$1"
  shift

  local local_skills_dir=""
  local plugin_args=()
  local plugin_claude_md=""
  local user_mcp=""
  local user_codex_config=""
  for arg in "$@"; do
    case "$arg" in
      --local-skills-dir=*)    local_skills_dir="${arg#--local-skills-dir=}" ;;
      --plugin-install-path=*) plugin_args+=("$arg") ;;
      --plugin-claude-md=*)    plugin_claude_md="${arg#--plugin-claude-md=}" ;;
      --user-mcp=*) user_mcp="${arg#--user-mcp=}" ;;
      --user-codex-config=*) user_codex_config="${arg#--user-codex-config=}" ;;
    esac
  done

  if [ -n "$user_mcp" ] && [ ! -f "$user_mcp" ]; then
    echo "sync.sh all: --user-mcp source missing: $user_mcp (create the file or omit --user-mcp)" >&2
    return 1
  fi

  echo "=== syncing-codex-harness: Full Sync ===" >&2

  # 1. Init
  init_agents_dir "$project_root"
  echo "[1/8] Initialized .agents/ and .codex/" >&2

  # 2. AGENTS.md
  local md_result
  md_result="$(agents_md "$project_root" "$plugin_claude_md")"
  echo "[2/8] AGENTS.md: $md_result" >&2

  # 3. Local skills
  local local_count=0
  if [ -n "$local_skills_dir" ] && [ -d "$project_root/$local_skills_dir" ]; then
    local_count=$(project_skills "$project_root/$local_skills_dir" "$project_root/.agents/skills")
  fi
  echo "[3/8] Local skills: $local_count" >&2

  # 4. Plugin skills + agents
  local plugin_skill_count=0
  local agent_count=0
  local mcp_args=()
  local override_args=()
  for parg in "${plugin_args[@]}"; do
    local val="${parg#--plugin-install-path=}"
    local ipath="${val%%:*}"
    local pname="${val#*:}"

    if [ ! -d "$ipath" ]; then
      echo "  Warning: Plugin path not found: $ipath" >&2
      continue
    fi

    if [ -d "$ipath/skills" ]; then
      local c
      c=$(plugin_skills "$ipath/skills" "$project_root/.agents/skills" "$pname")
      plugin_skill_count=$((plugin_skill_count + c))
    fi
    if [ -d "$ipath/agents" ]; then
      local a
      a=$(copy_agents "$ipath/agents" "$project_root/.agents")
      agent_count=$((agent_count + a))
    fi
    override_args+=("--plugin-install-path=$val")
    if [ -f "$ipath/.mcp.json" ]; then
      mcp_args+=("--plugin-mcp=$ipath/.mcp.json:$ipath:$pname")
    fi
  done
  echo "[4/8] Plugin skills: $plugin_skill_count, Agents: $agent_count" >&2

  # 5. AGENTS.override.md
  local rule_count
  rule_count=$(agents_override "$project_root" "${override_args[@]}")
  echo "[5/8] Rules -> AGENTS.override.md: $rule_count" >&2

  # 6. MCP config
  local project_mcp_arg=""
  if [ -f "$project_root/.mcp.json" ]; then
    project_mcp_arg="--project-mcp=$project_root/.mcp.json"
  fi

  local project_mcp_args=()
  [ -n "$project_mcp_arg" ] && project_mcp_args+=("$project_mcp_arg")
  project_mcp_args+=("${mcp_args[@]}")

  local did_mcp_update=0

  # project-scope sources -> <project>/.codex/config.toml
  if [ ${#project_mcp_args[@]} -gt 0 ]; then
    mcp_config "$project_root" "${project_mcp_args[@]}"
    echo "[6/8] MCP config updated (project)" >&2
    did_mcp_update=1
  fi

  # user-scope source -> ~/.codex/config.toml (or --user-codex-config target)
  if [ -n "$user_mcp" ]; then
    local user_mcp_args=("--user-mcp=$user_mcp")
    [ -n "$user_codex_config" ] && user_mcp_args+=("--user-codex-config=$user_codex_config")
    mcp_config "$project_root" "${user_mcp_args[@]}"
    if [ ${#project_mcp_args[@]} -gt 0 ]; then
      echo "[6b/8] MCP config updated (user)" >&2
    else
      echo "[6/8] MCP config updated (user)" >&2
    fi
    did_mcp_update=1
  fi

  if [ "$did_mcp_update" -eq 0 ]; then
    echo "[6/8] MCP config: no sources found" >&2
  fi

  # 7. Trust project in global config
  local trust_result
  trust_result="$(ensure_project_trusted "$project_root")"
  echo "[7/8] Trust: $trust_result" >&2

  # 8. Gitignore check
  local missing
  missing="$(gitignore_check "$project_root")"
  if [ -n "$missing" ]; then
    echo "[8/8] Missing .gitignore entries:" >&2
    echo "$missing" >&2
  else
    echo "[8/8] .gitignore OK" >&2
  fi

  echo "=== Sync complete ===" >&2
}

# ─── Main dispatch ───
case "${1:-}" in
  project-skills)
    project_skills "$2" "$3"
    ;;
  plugin-skills)
    # Parse --plugin-name=NAME
    local_plugin_name=""
    for arg in "${@:4}"; do
      case "$arg" in
        --plugin-name=*) local_plugin_name="${arg#--plugin-name=}" ;;
      esac
    done
    plugin_skills "$2" "$3" "$local_plugin_name"
    ;;
  agents)
    copy_agents "$2" "$3"
    ;;
  init)
    init_agents_dir "$2"
    ;;
  gitignore-check)
    gitignore_check "$2"
    ;;
  agents-md)
    agents_md "$2" "${3:-}"
    ;;
  agents-override)
    agents_override "$2" "${@:3}"
    ;;
  mcp-config)
    mcp_config "$2" "${@:3}"
    ;;
  trust-project)
    ensure_project_trusted "$2"
    ;;
  all)
    sync_all "$2" "${@:3}"
    ;;
  *)
    echo "Usage: sync.sh {project-skills|plugin-skills|agents|agents-md|agents-override|mcp-config|trust-project|init|gitignore-check|all} ..." >&2
    exit 1
    ;;
esac
