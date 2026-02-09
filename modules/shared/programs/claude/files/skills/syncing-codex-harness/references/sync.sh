#!/usr/bin/env bash
# sync.sh — Claude Code → Codex CLI harness projection
# Usage:
#   sync.sh project-skills <source-skills-dir> <target-skills-dir>
#   sync.sh plugin-skills  <source-skills-dir> <target-skills-dir> [--plugin-name=NAME]
#   sync.sh agents         <source-agents-dir> <target-agents-dir>
#   sync.sh init           <project-root>
#   sync.sh gitignore-check <project-root>

set -euo pipefail

# ─── openai.yaml generation ───
# Ported from modules/shared/programs/codex/default.nix:86-139
generate_openai_yaml() {
  local skill_md="$1"
  local yaml_file="$2"
  local skill_name="$3"

  # Extract 'name' from frontmatter
  local declared_name
  declared_name="$(awk '
    BEGIN { in_fm = 0 }
    /^---[[:space:]]*$/ { if (in_fm == 0) { in_fm = 1; next } else { exit } }
    in_fm == 1 && /^name:[[:space:]]*/ {
      line = $0; sub(/^name:[[:space:]]*/, "", line);
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line);
      print line; exit
    }
  ' "$skill_md")"
  [ -z "$declared_name" ] && declared_name="$skill_name"

  # Extract description first line (64 char limit)
  local short_desc
  short_desc="$(awk '
    BEGIN { in_fm = 0; mode = ""; desc = "" }
    /^---[[:space:]]*$/ { if (in_fm == 0) { in_fm = 1; next } else { exit } }
    in_fm != 1 { next }
    mode == "" && /^description:[[:space:]]*\|[[:space:]]*$/ { mode = "block"; next }
    mode == "" && /^description:[[:space:]]*>[[:space:]]*-?[[:space:]]*$/ { mode = "block"; next }
    mode == "" && /^description:[[:space:]]*/ {
      line = $0; sub(/^description:[[:space:]]*/, "", line);
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line);
      print line; exit
    }
    mode == "block" {
      if ($0 ~ /^[A-Za-z0-9_-]+:[[:space:]]*/) { print desc; exit }
      line = $0; sub(/^[[:space:]]+/, "", line);
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line);
      if (line == "") next;
      if (desc == "") desc = line; else desc = desc " " line
    }
    END { if (mode == "block" && desc != "") print desc }
  ' "$skill_md")"
  short_desc="$(printf '%.64s' "$short_desc")"
  [ -z "$short_desc" ] && short_desc="Codex skill projected from Claude Code"

  # display_name: kebab-case -> Title Case
  local display_name
  display_name="$(echo "$declared_name" | tr '-' ' ' | awk '{
    for (i = 1; i <= NF; i++) $i = toupper(substr($i, 1, 1)) substr($i, 2)
    print
  }')"

  # Escape YAML special chars
  local escaped_display escaped_desc
  escaped_display="$(echo "$display_name" | sed 's/"/\\"/g')"
  escaped_desc="$(echo "$short_desc" | sed 's/"/\\"/g')"

  mkdir -p "$(dirname "$yaml_file")"
  cat > "$yaml_file" <<YAML
interface:
  display_name: "$escaped_display"
  short_description: "$escaped_desc"
  default_prompt: "Use \$$declared_name to help with this task."
YAML
}

# ─── project-skills: project local skills projection ───
project_skills() {
  local source_dir="$1"
  local target_dir="$2"
  local count=0

  for source_skill_dir in "$source_dir"/*/; do
    [ -d "$source_skill_dir" ] || continue
    [ -f "$source_skill_dir/SKILL.md" ] || continue

    local skill_name
    skill_name="$(basename "$source_skill_dir")"
    local target_skill_dir="$target_dir/$skill_name"

    mkdir -p "$target_skill_dir"

    # SKILL.md -> real file copy (NOT symlink — Codex compatibility)
    rm -f "$target_skill_dir/SKILL.md"
    cp "$source_skill_dir/SKILL.md" "$target_skill_dir/SKILL.md"

    # references, scripts, assets -> relative symlinks
    for child in references scripts assets; do
      if [ -e "$source_skill_dir/$child" ]; then
        # Compute relative path: .agents/skills/<name>/ -> .claude/skills/<name>/<child>
        # Relative: ../../../.claude/skills/<name>/<child>
        local rel_target="../../../.claude/skills/$skill_name/$child"
        rm -f "$target_skill_dir/$child"
        ln -sf "$rel_target" "$target_skill_dir/$child"
      fi
    done

    # agents/openai.yaml
    generate_openai_yaml "$source_skill_dir/SKILL.md" "$target_skill_dir/agents/openai.yaml" "$skill_name"

    count=$((count + 1))
  done

  echo "$count"
}

# ─── plugin-skills: plugin skills projection ───
plugin_skills() {
  local source_dir="$1"
  local target_dir="$2"
  local plugin_name="${3:-}"

  local count=0

  for source_skill_dir in "$source_dir"/*/; do
    [ -d "$source_skill_dir" ] || continue
    [ -f "$source_skill_dir/SKILL.md" ] || continue

    local skill_name
    skill_name="$(basename "$source_skill_dir")"

    # Check for name collision with existing skills
    local final_name="$skill_name"
    if [ -n "$plugin_name" ] && [ -d "$target_dir/$skill_name" ]; then
      final_name="${plugin_name}--${skill_name}"
    fi
    local target_skill_dir="$target_dir/$final_name"

    mkdir -p "$target_skill_dir"

    # SKILL.md -> real file copy (NOT symlink)
    rm -f "$target_skill_dir/SKILL.md"
    cp "$source_skill_dir/SKILL.md" "$target_skill_dir/SKILL.md"

    # references, scripts, assets -> absolute symlinks (plugin cache is outside project)
    for child in references scripts assets; do
      if [ -e "$source_skill_dir/$child" ]; then
        local abs_target
        abs_target="$(cd "$source_skill_dir" && pwd)/$child"
        rm -f "$target_skill_dir/$child"
        ln -sf "$abs_target" "$target_skill_dir/$child"
      fi
    done

    # agents/openai.yaml
    generate_openai_yaml "$source_skill_dir/SKILL.md" "$target_skill_dir/agents/openai.yaml" "$final_name"

    count=$((count + 1))
  done

  echo "$count"
}

# ─── agents: agent files projection ───
copy_agents() {
  local source_dir="$1"
  local target_dir="$2"
  local count=0

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
}

# ─── gitignore-check: check entries ───
gitignore_check() {
  local project_root="$1"
  local gitignore="$project_root/.gitignore"
  local missing=()

  local entries=(".agents/" ".codex/" "AGENTS.md" "AGENTS.override.md")

  if [ ! -f "$gitignore" ]; then
    printf '%s\n' "${entries[@]}"
    return
  fi

  for entry in "${entries[@]}"; do
    if ! grep -qxF "$entry" "$gitignore" 2>/dev/null; then
      missing+=("$entry")
    fi
  done

  if [ ${#missing[@]} -gt 0 ]; then
    printf '%s\n' "${missing[@]}"
  fi
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
  *)
    echo "Usage: sync.sh {project-skills|plugin-skills|agents|init|gitignore-check} ..." >&2
    exit 1
    ;;
esac
