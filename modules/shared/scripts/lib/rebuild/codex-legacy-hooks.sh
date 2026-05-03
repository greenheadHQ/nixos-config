# shellcheck shell=bash

codex_legacy_user_hook_jq_defs() {
    cat <<'EOF'
def stale_names: [
    "session-init-icons.sh",
    "worktree-path-guard.sh",
    "fragile-hardcoding-guard.sh",
    "system-bash-guard.sh"
];
def normalize_command:
    gsub("^[[:space:]]+|[[:space:]]+$"; "")
    | if ((startswith("\"") and endswith("\"")) or (startswith("'") and endswith("'"))) then
        .[1:-1]
      else
        .
      end;
def stale_path($name):
    [
        "~/.codex/hooks/" + $name,
        "$HOME/.codex/hooks/" + $name,
        "${HOME}/.codex/hooks/" + $name,
        env.HOME + "/.codex/hooks/" + $name
    ];
def is_stale:
    ((.command? // "") | normalize_command) as $cmd
    | [stale_names[] | . as $name | select(stale_path($name) | index($cmd))]
    | length > 0;
EOF
}

codex_legacy_user_hook_count_jq_filter() {
    codex_legacy_user_hook_jq_defs
    cat <<'EOF'
[(.hooks // {}) | to_entries[]? | .value[]? | .hooks[]? | select(is_stale)] | length
EOF
}

codex_legacy_user_hook_prune_jq_filter() {
    codex_legacy_user_hook_jq_defs
    cat <<'EOF'
if (.hooks? | type) == "object" then
    .hooks |= with_entries(
        .value = (
            .value
            | map(
                if (.hooks? | type) == "array" then
                    .hooks = (.hooks | map(select(is_stale | not)))
                else
                    .
                end
            )
            | map(select((.hooks? | type != "array") or ((.hooks | length) > 0)))
        )
        | select(.value | length > 0)
    )
else
    .
end
EOF
}

codex_prune_legacy_user_hooks_json() {
    local hooks_json="$1"
    [[ -f "$hooks_json" ]] || return 0
    if [[ -L "$hooks_json" ]]; then
        log_warn "⚠️  $hooks_json is a symlink; leaving user-owned hook file unchanged. Remove stale Codex legacy entries manually."
        return 0
    fi

    if ! command -v jq >/dev/null 2>&1; then
        log_error "jq is required to safely inspect $hooks_json"
        return 1
    fi

    local stale_count count_filter
    count_filter="$(codex_legacy_user_hook_count_jq_filter)"
    if ! stale_count=$(jq -r "$count_filter" "$hooks_json"); then
        log_warn "⚠️  Could not parse $hooks_json; leaving user-owned hook file unchanged."
        return 0
    fi

    [[ "$stale_count" =~ ^[0-9]+$ ]] || {
        log_warn "⚠️  Could not count stale entries in $hooks_json; leaving it unchanged."
        return 0
    }
    (( stale_count > 0 )) || return 0

    local tmp prune_filter hooks_dir
    hooks_dir="$(dirname "$hooks_json")"
    tmp=$(mktemp "$hooks_dir/.codex-hooks-json.XXXXXX")
    prune_filter="$(codex_legacy_user_hook_prune_jq_filter)"
    if ! jq "$prune_filter" "$hooks_json" > "$tmp"; then
        rm -f "$tmp"
        log_error "Failed to prune stale Codex hook entries from $hooks_json"
        return 1
    fi

    if ! mv "$tmp" "$hooks_json"; then
        rm -f "$tmp"
        log_error "Failed to replace $hooks_json after pruning stale Codex hook entries"
        return 1
    fi
    log_info "🧹 Pruned $stale_count stale Codex hook entr$( (( stale_count == 1 )) && printf 'y' || printf 'ies' ) from user-level hooks.json."
}

codex_clear_retired_hook_artifacts() {
    local flake_path="$1"
    local home_dir="$2"
    local hooks_json="$flake_path/.codex/hooks.json"
    local hooks_report="$flake_path/.codex/hooks.compatibility.json"
    local user_hooks_report="$home_dir/.codex/hooks.compatibility.json"

    if [[ -e "$hooks_json" || -L "$hooks_json" || -e "$hooks_report" || -L "$hooks_report" ]]; then
        rm -f "$hooks_json" "$hooks_report"
        log_info "🧹 Removed retired Codex hook artifacts."
    fi

    if [[ -e "$user_hooks_report" || -L "$user_hooks_report" ]]; then
        rm -f "$user_hooks_report"
        log_info "🧹 Removed retired user-level Codex hooks.compatibility.json."
    fi

    codex_prune_legacy_user_hooks_json "$home_dir/.codex/hooks.json"
}
