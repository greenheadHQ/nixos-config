#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTDATA_DIR="$SCRIPT_DIR/testdata/hooks"
COMPILER="$SCRIPT_DIR/compile-hooks.py"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_SETTINGS="$TESTDATA_DIR/project-settings.json"
EFFECTIVE_SAME="$TESTDATA_DIR/effective-settings-same.json"
EFFECTIVE_DRIFT="$TESTDATA_DIR/effective-settings-drift.json"

python3 "$COMPILER" \
  --project-settings "$PROJECT_SETTINGS" \
  --effective-settings "$EFFECTIVE_SAME" \
  --output-hooks "$TMPDIR/hooks.json" \
  --output-report "$TMPDIR/report.json"

jq -e '.hooks.SessionStart[0].matcher == "startup|resume"' "$TMPDIR/hooks.json" >/dev/null
jq -e '.hooks.PreToolUse[0].matcher == ""' "$TMPDIR/hooks.json" >/dev/null
jq -e '.summary.total == 6' "$TMPDIR/report.json" >/dev/null
jq -e '.summary.supported == 3' "$TMPDIR/report.json" >/dev/null
jq -e '.summary.lossy == 1' "$TMPDIR/report.json" >/dev/null
jq -e '.summary.unsupported == 2' "$TMPDIR/report.json" >/dev/null
jq -e '.drift_detected == false' "$TMPDIR/report.json" >/dev/null

python3 "$COMPILER" \
  --project-settings "$PROJECT_SETTINGS" \
  --effective-settings "$EFFECTIVE_DRIFT" \
  --output-hooks "$TMPDIR/hooks-drift.json" \
  --output-report "$TMPDIR/report-drift.json"

jq -e '.drift_detected == true' "$TMPDIR/report-drift.json" >/dev/null

EMPTY_EFFECTIVE="$TMPDIR/effective-empty.json"
cat > "$EMPTY_EFFECTIVE" <<'EOF'
{"hooks": {}}
EOF

python3 "$COMPILER" \
  --project-settings "$PROJECT_SETTINGS" \
  --effective-settings "$EMPTY_EFFECTIVE" \
  --output-hooks "$TMPDIR/hooks-empty.json" \
  --output-report "$TMPDIR/report-empty.json"

jq -e '.drift_detected == true' "$TMPDIR/report-empty.json" >/dev/null

INVALID_EFFECTIVE="$TMPDIR/effective-invalid.json"
printf '%s\n' '{"hooks":' > "$INVALID_EFFECTIVE"

python3 "$COMPILER" \
  --project-settings "$PROJECT_SETTINGS" \
  --effective-settings "$INVALID_EFFECTIVE" \
  --output-hooks "$TMPDIR/hooks-invalid.json" \
  --output-report "$TMPDIR/report-invalid.json"

jq -e '.drift_detected == true' "$TMPDIR/report-invalid.json" >/dev/null

SYNC_SH="$SCRIPT_DIR/sync.sh"
REPO_ROOT="$TMPDIR/repo"
HOME_ROOT="$TMPDIR/home"

mkdir -p "$REPO_ROOT/modules/shared/programs/claude/files" "$HOME_ROOT/.claude"
printf '# temp repo\n' > "$REPO_ROOT/CLAUDE.md"
cp "$PROJECT_SETTINGS" "$REPO_ROOT/modules/shared/programs/claude/files/settings.json"
cp "$EFFECTIVE_DRIFT" "$HOME_ROOT/.claude/settings.json"
git -C "$REPO_ROOT" init -q

HOME="$HOME_ROOT" CODEX_HOME="$HOME_ROOT/.codex" bash "$SYNC_SH" hooks-config "$REPO_ROOT"

jq -e '.hooks.SessionStart[0].matcher == "startup|resume"' "$REPO_ROOT/.codex/hooks.json" >/dev/null
jq -e '.summary.lossy == 1' "$REPO_ROOT/.codex/hooks.compatibility.json" >/dev/null
jq -e '.summary.supported == 3' "$REPO_ROOT/.codex/hooks.compatibility.json" >/dev/null

echo "test-hooks-sync: PASS"
