#!/usr/bin/env bash
# Focused tests for run-da manual sync contracts across skill docs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"
python3 tests/skill-doc-sync.py
