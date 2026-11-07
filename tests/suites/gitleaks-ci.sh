# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164
# 기존 staged fixture의 합성 규칙과 입력만 재사용하며 실제 자격은 읽지 않는다.

_gitleaks_ci_git() {
  local repo="$1"
  shift
  HOME="$(dirname "$repo")/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -C "$repo" -c core.hooksPath=/dev/null -c commit.gpgSign=false -c init.templateDir= \
    -c user.name=Fixture -c user.email=fixture@example.invalid "$@"
}

_gitleaks_ci_repo() {
  local sandbox repo file
  sandbox=$(new_sandbox)
  repo="$sandbox/repo"
  mkdir -p "$repo/scripts/ai" "$sandbox/home"
  for file in run-gitleaks-ci.sh validate-gitleaks-staged-policy.py; do
    cp "$REPO_ROOT/scripts/ai/$file" "$repo/scripts/ai/$file"
  done
  python3 - "$REPO_ROOT" "$repo" "$sandbox/token" <<'PY'
from pathlib import Path
import re
import sys

source = (Path(sys.argv[1]) / "tests/test-precommit-staged-snapshot.sh").read_text()
config = source.split('cat > "$dir/.gitleaks.toml" <<\'EOF\'\n', 1)[1].split("\nEOF", 1)[0]
policy = (Path(sys.argv[1]) / ".gitleaks.toml").read_text()
allowlist = "[allowlist]" + policy.split("[allowlist]", 1)[1]
(Path(sys.argv[2]) / ".gitleaks.toml").write_text(config + "\n" + allowlist)
Path(sys.argv[3]).write_text(re.search(r"secret='([^']+)'", source).group(1))
PY
  : > "$repo/.gitleaksignore"
  printf 'fixture\n' > "$repo/README.md"
  _gitleaks_ci_git "$repo" init -q -b main
  _gitleaks_ci_commit "$repo"
  printf '%s\n' "$repo"
}

_gitleaks_ci_commit() {
  _gitleaks_ci_git "$1" add -A
  _gitleaks_ci_git "$1" commit -qm fixture
}

_gitleaks_ci_run() {
  local repo="$1" base="$2" head="$3" expected="$4" rc=0 output token
  output=$(HOME="$(dirname "$repo")/home" bash "$repo/scripts/ai/run-gitleaks-ci.sh" "$base" "$head" 2>&1) || rc=$?
  [ "$rc" -eq "$expected" ] || fail "gitleaks CI returned $rc, expected $expected"
  token=$(cat "$(dirname "$repo")/token")
  [[ "$output" != *"$token"* ]] || fail "gitleaks CI exposed a detection or error value"
  case "$expected" in
    0) assert_contains "$output" '검사 통과' ;;
    10) assert_contains "$output" '탐지 대상' ;;
    *) assert_not_contains "$output" '검사 통과' ;;
  esac
}

test_gitleaks_ci_scans_commits_without_mutating_checkout() {
  local repo base head before after
  repo=$(_gitleaks_ci_repo)
  base=$(_gitleaks_ci_git "$repo" rev-parse HEAD)
  printf 'clean change\n' >> "$repo/README.md"
  _gitleaks_ci_commit "$repo"
  head=$(_gitleaks_ci_git "$repo" rev-parse HEAD)
  cat "$(dirname "$repo")/token" > "$repo/staged.txt"
  _gitleaks_ci_git "$repo" add staged.txt
  printf 'invalid TOML\n' > "$repo/.gitleaks.toml"
  cat "$(dirname "$repo")/token" > "$repo/untracked.txt"
  before=$(_gitleaks_ci_git "$repo" status --porcelain=v1)
  _gitleaks_ci_run "$repo" "$base" "$head" 0
  after=$(_gitleaks_ci_git "$repo" status --porcelain=v1)
  [ "$before" = "$after" ] || fail "CI scan modified checkout or index"
}

test_gitleaks_ci_detects_committed_content_with_empty_staging() {
  local repo base head
  repo=$(_gitleaks_ci_repo)
  base=$(_gitleaks_ci_git "$repo" rev-parse HEAD)
  cat "$(dirname "$repo")/token" > "$repo/submitted.txt"
  _gitleaks_ci_commit "$repo"
  head=$(_gitleaks_ci_git "$repo" rev-parse HEAD)
  # 깨끗한 CI index에서 기존 staged 호출은 검사 입력이 없어서 통과한다.
  (cd "$repo" && gitleaks protect --staged --source . --no-banner --redact=100 \
    --config .gitleaks.toml --gitleaks-ignore-path .gitleaksignore >/dev/null 2>&1)
  _gitleaks_ci_run "$repo" "$base" "$head" 10
}

test_gitleaks_ci_keeps_deleted_commit_content_in_scope() {
  local repo base head
  repo=$(_gitleaks_ci_repo)
  base=$(_gitleaks_ci_git "$repo" rev-parse HEAD)
  cat "$(dirname "$repo")/token" > "$repo/removed.txt"
  _gitleaks_ci_commit "$repo"
  rm "$repo/removed.txt"
  _gitleaks_ci_commit "$repo"
  head=$(_gitleaks_ci_git "$repo" rev-parse HEAD)
  _gitleaks_ci_run "$repo" "$base" "$head" 10
}

test_gitleaks_ci_scans_renamed_paths_and_preserves_allowlist() {
  local repo base allowed renamed
  repo=$(_gitleaks_ci_repo)
  base=$(_gitleaks_ci_git "$repo" rev-parse HEAD)
  cat "$(dirname "$repo")/token" > "$repo/flake.lock"
  _gitleaks_ci_commit "$repo"
  allowed=$(_gitleaks_ci_git "$repo" rev-parse HEAD)
  _gitleaks_ci_run "$repo" "$base" "$allowed" 0
  _gitleaks_ci_git "$repo" mv flake.lock 'renamed file.txt'
  _gitleaks_ci_commit "$repo"
  renamed=$(_gitleaks_ci_git "$repo" rev-parse HEAD)
  _gitleaks_ci_run "$repo" "$allowed" "$renamed" 10
}

test_gitleaks_ci_scans_merge_only_additions() {
  local repo base head
  repo=$(_gitleaks_ci_repo)
  base=$(_gitleaks_ci_git "$repo" rev-parse HEAD)
  _gitleaks_ci_git "$repo" checkout -qb side
  printf 'side\n' > "$repo/side.txt"
  _gitleaks_ci_commit "$repo"
  _gitleaks_ci_git "$repo" checkout -q main
  printf 'main\n' > "$repo/main.txt"
  _gitleaks_ci_commit "$repo"
  _gitleaks_ci_git "$repo" merge --no-ff --no-commit side >/dev/null 2>&1
  cat "$(dirname "$repo")/token" > "$repo/merge-only.txt"
  _gitleaks_ci_commit "$repo"
  rm "$repo/merge-only.txt"
  _gitleaks_ci_commit "$repo"
  head=$(_gitleaks_ci_git "$repo" rev-parse HEAD)
  _gitleaks_ci_run "$repo" "$base" "$head" 10
}

test_gitleaks_ci_preserves_commit_fingerprint_exceptions() {
  local repo base head report
  repo=$(_gitleaks_ci_repo)
  base=$(_gitleaks_ci_git "$repo" rev-parse HEAD)
  cat "$(dirname "$repo")/token" > "$repo/accepted.txt"
  _gitleaks_ci_commit "$repo"
  head=$(_gitleaks_ci_git "$repo" rev-parse HEAD)
  report="$(dirname "$repo")/redacted.json"
  (cd "$repo" && gitleaks git . --no-banner --redact=100 --config .gitleaks.toml \
    --log-opts="${base}..${head}" --report-format json --report-path "$report" >/dev/null 2>&1) \
    && fail "fingerprint fixture did not detect its synthetic input"
  python3 - "$report" "$repo/.gitleaksignore" <<'PY'
import json
from pathlib import Path
import sys
findings = json.loads(Path(sys.argv[1]).read_text())
assert len(findings) == 1
Path(sys.argv[2]).write_text(findings[0]["Fingerprint"] + "\n")
PY
  _gitleaks_ci_commit "$repo"
  head=$(_gitleaks_ci_git "$repo" rev-parse HEAD)
  _gitleaks_ci_run "$repo" "$base" "$head" 0
  rm "$repo/accepted.txt"
  _gitleaks_ci_commit "$repo"
  cat "$(dirname "$repo")/token" > "$repo/accepted.txt"
  _gitleaks_ci_commit "$repo"
  head=$(_gitleaks_ci_git "$repo" rev-parse HEAD)
  _gitleaks_ci_run "$repo" "$base" "$head" 10
}

test_gitleaks_ci_rejects_invalid_policy_material() {
  local kind repo base head
  for kind in syntax regex escape missing cycle config-link ignore-link extend-link validator-link; do
    repo=$(_gitleaks_ci_repo)
    base=$(_gitleaks_ci_git "$repo" rev-parse HEAD)
    case "$kind" in
      syntax) cat "$(dirname "$repo")/token" > "$repo/.gitleaks.toml" ;;
      regex) printf '\n[[rules]]\nid="invalid"\nregex="("\n' >> "$repo/.gitleaks.toml" ;;
      escape) printf '[extend]\npath="../outside.toml"\n' > "$repo/.gitleaks.toml" ;;
      missing) printf '[extend]\npath="missing.toml"\n' > "$repo/.gitleaks.toml" ;;
      cycle) printf '[extend]\npath=".gitleaks.toml"\n' > "$repo/.gitleaks.toml" ;;
      config-link)
        mv "$repo/.gitleaks.toml" "$repo/policy.toml"
        ln -s policy.toml "$repo/.gitleaks.toml"
        ;;
      ignore-link)
        rm "$repo/.gitleaksignore"
        ln -s README.md "$repo/.gitleaksignore"
        ;;
      extend-link)
        mv "$repo/.gitleaks.toml" "$repo/policy.toml"
        ln -s policy.toml "$repo/linked.toml"
        printf '[extend]\npath="linked.toml"\n' > "$repo/.gitleaks.toml"
        ;;
      validator-link)
        mv "$repo/scripts/ai/validate-gitleaks-staged-policy.py" "$repo/validator.py"
        ln -s ../../validator.py "$repo/scripts/ai/validate-gitleaks-staged-policy.py"
        ;;
    esac
    _gitleaks_ci_commit "$repo"
    head=$(_gitleaks_ci_git "$repo" rev-parse HEAD)
    _gitleaks_ci_run "$repo" "$base" "$head" 2
  done
}

test_gitleaks_ci_rejects_scanner_errors_without_raw_output() {
  local repo base stub
  repo=$(_gitleaks_ci_repo)
  base=$(_gitleaks_ci_git "$repo" rev-parse HEAD)
  stub="$(dirname "$repo")/bin"
  mkdir "$stub"
  cat > "$stub/gitleaks" <<'EOF'
#!/usr/bin/env bash
cat "$FIXTURE_ERROR_VALUE" >&2
exit 17
EOF
  chmod +x "$stub/gitleaks"
  PATH="$stub:$PATH" FIXTURE_ERROR_VALUE="$(dirname "$repo")/token" \
    _gitleaks_ci_run "$repo" "$base" "$base" 2
}

test_gitleaks_ci_rejects_git_log_failure_reported_as_success() {
  local repo base head stub real_git marker
  repo=$(_gitleaks_ci_repo)
  base=$(_gitleaks_ci_git "$repo" rev-parse HEAD)
  printf 'clean change\n' >> "$repo/README.md"
  _gitleaks_ci_commit "$repo"
  head=$(_gitleaks_ci_git "$repo" rev-parse HEAD)
  real_git=$(command -v git)
  stub="$(dirname "$repo")/bin"
  marker="$(dirname "$repo")/git-log-called"
  mkdir "$stub"
  cat > "$stub/git" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = log ]; then
    printf 'called\n' > "$FIXTURE_GIT_LOG_MARKER"
    cat "$FIXTURE_ERROR_VALUE" >&2
    exit 29
  fi
done
exec "$FIXTURE_REAL_GIT" "$@"
EOF
  chmod +x "$stub/git"
  PATH="$stub:$PATH" FIXTURE_REAL_GIT="$real_git" FIXTURE_GIT_LOG_MARKER="$marker" \
    FIXTURE_ERROR_VALUE="$(dirname "$repo")/token" _gitleaks_ci_run "$repo" "$base" "$head" 2
  assert_file_contains "$marker" called
}

test_gitleaks_ci_rejects_bad_refs_and_limits_history() {
  local repo base head
  repo=$(_gitleaks_ci_repo)
  cat "$(dirname "$repo")/token" > "$repo/preexisting.txt"
  _gitleaks_ci_commit "$repo"
  _gitleaks_ci_git "$repo" checkout -qb feature
  printf 'feature\n' > "$repo/feature.txt"
  _gitleaks_ci_commit "$repo"
  head=$(_gitleaks_ci_git "$repo" rev-parse HEAD)
  _gitleaks_ci_git "$repo" checkout -q main
  printf 'new base\n' > "$repo/base.txt"
  _gitleaks_ci_commit "$repo"
  base=$(_gitleaks_ci_git "$repo" rev-parse HEAD)
  _gitleaks_ci_run "$repo" "$base" "$head" 0
  _gitleaks_ci_run "$repo" --all "$head" 2
  _gitleaks_ci_run "$repo" 0000000000000000000000000000000000000000 "$head" 2
}
