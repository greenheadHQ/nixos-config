# shellcheck shell=bash
# Codex hook command expectation builder.
#
# Runtime source of truth is modules/shared/programs/codex/files/config*.toml.
# This helper is the single generator for expected shim command byte strings used
# by tests and verifier-side expectations.

expected_codex_hook_command() {
  local policy="${1:-}"
  local target_rel_path="${2:-}"
  local target_home target_label

  case "$policy" in
    advisory|blocking) ;;
    *)
      printf 'expected_codex_hook_command: unknown policy: %s\n' "$policy" >&2
      return 2
      ;;
  esac

  case "$target_rel_path" in
    .codex/hooks/*.sh) ;;
    *)
      printf 'expected_codex_hook_command: invalid target path: %s\n' "$target_rel_path" >&2
      return 2
      ;;
  esac

  target_home="\$HOME/$target_rel_path"
  # shellcheck disable=SC2088  # 진단 메시지용 표시 라벨 — tilde는 의도적 리터럴 (확장 대상 아님)
  target_label="~/$target_rel_path"

  case "$policy" in
    advisory)
      printf '%s' "t=\"$target_home\"; if [ -x \"\$t\" ]; then exec \"\$t\"; fi; printf '%s\\n' '[codex-hook] target missing or not executable: $target_label. Impact: hook skipped to avoid raw 127.' 'Action: run nrs --force, then ./scripts/ai/verify-ai-compat.sh.' >&2; exit 0"
      ;;
    blocking)
      local reason json
      reason="Codex managed hook target is missing or not executable: $target_label. Impact: edit is denied until the hook is restored. Action: run nrs --force, then ./scripts/ai/verify-ai-compat.sh."
      json='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"'"$reason"'"}}'
      printf '%s' "t=\"$target_home\"; if [ -x \"\$t\" ]; then exec \"\$t\"; fi; printf '%s\\n' '$json'; exit 0"
      ;;
  esac
}
