#!/usr/bin/env bash
# warn-skill-stale-identifiers.sh
# 목적: 인프라 rename/migration diff에서 제거된 고유 식별자가 스킬 문서에 잔존하는지 경고
# 정책:
# - 항상 warning-only (exit 0)
# - 우회: SKIP_AI_SKILL_CHECK=1 (또는 true/yes)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GIT_ROOT="${STAGED_SNAPSHOT_SOURCE_ROOT:-$REPO_ROOT}"
DIFF_FILE_OVERRIDE="${SKILL_STALE_IDENTIFIERS_DIFF_FILE:-}"
TMP_DIR=""

cleanup() {
  if [ -n "${TMP_DIR:-}" ]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

warn() {
  echo "[WARN] $1" >&2
}

is_true() {
  local val="${1:-}"
  val="${val,,}"
  [ "$val" = "1" ] || [ "$val" = "true" ] || [ "$val" = "yes" ]
}

normalize_repo_path() {
  local path="$1"
  path="${path#./}"
  printf '%s\n' "$path"
}

write_staged_paths() {
  local output_file="$1"
  local path

  : > "$output_file"

  if [ -n "${STAGED_SNAPSHOT_STAGED_FILES_NUL_FILE:-}" ] && [ -f "$STAGED_SNAPSHOT_STAGED_FILES_NUL_FILE" ]; then
    while IFS= read -r -d '' path; do
      [ -n "$path" ] || continue
      normalize_repo_path "$path"
    done < "$STAGED_SNAPSHOT_STAGED_FILES_NUL_FILE" >> "$output_file"
  elif [ -n "${SKILL_STALE_IDENTIFIERS_STAGED_FILES_FILE:-}" ] && [ -f "$SKILL_STALE_IDENTIFIERS_STAGED_FILES_FILE" ]; then
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      normalize_repo_path "$path"
    done < "$SKILL_STALE_IDENTIFIERS_STAGED_FILES_FILE" >> "$output_file"
  elif git -C "$GIT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$GIT_ROOT" diff --name-only --cached | while IFS= read -r path; do
      [ -n "$path" ] || continue
      normalize_repo_path "$path"
    done >> "$output_file"
  fi

  sort -u -o "$output_file" "$output_file"
}

write_staged_diff() {
  local output_file="$1"

  if [ -n "$DIFF_FILE_OVERRIDE" ]; then
    if [ -f "$DIFF_FILE_OVERRIDE" ]; then
      cp "$DIFF_FILE_OVERRIDE" "$output_file"
    else
      warn "diff 입력 파일 없음: $DIFF_FILE_OVERRIDE"
      : > "$output_file"
    fi
    return 0
  fi

  if git -C "$GIT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$GIT_ROOT" diff --cached --no-ext-diff --unified=0 > "$output_file" || : > "$output_file"
  else
    : > "$output_file"
  fi
}

extract_candidates() {
  local diff_file="$1"
  local output_file="$2"

  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 없음: stale identifier 추출 생략"
    : > "$output_file"
    return 0
  fi

  if ! python3 - "$diff_file" > "$output_file" <<'PY'
import re
import sys
from pathlib import Path

diff_path = Path(sys.argv[1])
text = diff_path.read_text(encoding="utf-8", errors="replace")

reverse_dns_re = re.compile(
    r"(?<![A-Za-z0-9_-])(?:com|org)\.[A-Za-z0-9][A-Za-z0-9_-]*(?:\.[A-Za-z0-9][A-Za-z0-9_-]*)+(?![A-Za-z0-9_-])",
    re.IGNORECASE,
)
image_re = re.compile(
    r"(?<![A-Za-z0-9_./-])(?:[A-Za-z0-9][A-Za-z0-9._-]*(?::[0-9]+)?/)+[A-Za-z0-9][A-Za-z0-9._-]*:[A-Za-z0-9][A-Za-z0-9._-]*(?![A-Za-z0-9_./-])"
)
attr_re = re.compile(
    r"(?<![A-Za-z0-9_-])(?:constants|launchd|systemd|services|virtualisation|age|homeserver)\.[A-Za-z][A-Za-z0-9_-]*(?:\.[A-Za-z][A-Za-z0-9_-]*)+(?![A-Za-z0-9_-])"
)
func_res = [
    re.compile(r"^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*\)\s*(?:\{|$)"),
    re.compile(r"^\s*function\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:\{|$)"),
]

file_ext_re = re.compile(
    r"\.(?:age|bash|conf|json|log|md|nix|py|service|sh|sock|timer|toml|txt|yaml|yml|zsh)$",
    re.IGNORECASE,
)
generic_function_names = {
    "cleanup",
    "debug",
    "die",
    "err",
    "fail",
    "handler",
    "log_error",
    "log_info",
    "log_warn",
    "main",
    "pass",
    "usage",
    "warn",
}


def valid_common(token: str) -> bool:
    return len(token) >= 6 and not token.isdigit()


def clean_token(token: str) -> str:
    return token.strip("`\"'()[]{}<>.,;")


def add(out: dict[str, str], token: str, kind: str) -> None:
    token = clean_token(token)
    if not valid_common(token):
        return
    out.setdefault(token, kind)


def add_image(out: dict[str, str], token: str) -> None:
    token = clean_token(token)
    image_name = token.rsplit(":", 1)[0]
    image_base = image_name.rsplit("/", 1)[-1]
    if "/" not in image_name:
        return
    if "://" in token or file_ext_re.search(image_base):
        return
    add(out, token, "container-image")


def add_function(out: dict[str, str], name: str) -> None:
    if name in generic_function_names:
        return
    if "_" not in name and len(name) < 12:
        return
    add(out, name, "shell-function")


candidates: dict[str, str] = {}
for line in text.splitlines():
    if not line.startswith("-") or line.startswith("---"):
        continue
    deleted = line[1:]

    for match in reverse_dns_re.finditer(deleted):
        add(candidates, match.group(0), "reverse-dns")
    for match in image_re.finditer(deleted):
        add_image(candidates, match.group(0))
    for match in attr_re.finditer(deleted):
        add(candidates, match.group(0), "nix-attr-path")
    for func_re in func_res:
        match = func_re.match(deleted)
        if match:
            add_function(candidates, match.group(1))
            break

for identifier, kind in candidates.items():
    print(f"{identifier}\t{kind}")
PY
  then
    warn "stale identifier 추출 실패"
    : > "$output_file"
  fi
}

is_staged_path() {
  local path="$1"
  local staged_paths_file="$2"
  grep -Fxq -- "$path" "$staged_paths_file"
}

scan_identifier() {
  local identifier="$1"
  local staged_paths_file="$2"
  local matches_file="$3"
  local rel_dir match path rest line_no
  local skill_dirs=(
    ".claude/skills"
    "modules/shared/programs/claude/files/skills"
  )

  : > "$matches_file"

  for rel_dir in "${skill_dirs[@]}"; do
    [ -d "$REPO_ROOT/$rel_dir" ] || continue
    while IFS= read -r match; do
      path="${match%%:*}"
      rest="${match#*:}"
      line_no="${rest%%:*}"
      [[ "$line_no" =~ ^[0-9]+$ ]] || continue
      if is_staged_path "$path" "$staged_paths_file"; then
        continue
      fi
      printf '%s:%s\n' "$path" "$line_no" >> "$matches_file"
    done < <(cd "$REPO_ROOT" && LC_ALL=C grep -RInF -- "$identifier" "$rel_dir" 2>/dev/null || true)
  done

  sort -u -o "$matches_file" "$matches_file"
}

main() {
  local diff_file staged_paths_file candidates_file matches_file
  local identifier kind warnings

  if is_true "${SKIP_AI_SKILL_CHECK:-}"; then
    return 0
  fi

  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skill-stale-identifiers.XXXXXX")"
  diff_file="$TMP_DIR/staged.diff"
  staged_paths_file="$TMP_DIR/staged-paths.txt"
  candidates_file="$TMP_DIR/candidates.tsv"
  matches_file="$TMP_DIR/matches.txt"

  write_staged_diff "$diff_file"
  [ -s "$diff_file" ] || return 0

  extract_candidates "$diff_file" "$candidates_file"
  [ -s "$candidates_file" ] || return 0

  write_staged_paths "$staged_paths_file"

  warnings=0
  while IFS=$'\t' read -r identifier kind; do
    [ -n "$identifier" ] || continue
    scan_identifier "$identifier" "$staged_paths_file" "$matches_file"
    [ -s "$matches_file" ] || continue

    warn "스킬 문서 구 식별자 잔존 의심: $identifier ($kind)"
    while IFS= read -r match; do
      warn "  $match"
    done < "$matches_file"
    warn "  스킬 문서 갱신 필요 여부 확인"
    warnings=$((warnings + 1))
  done < "$candidates_file"

  if [ "$warnings" -gt 0 ]; then
    warn "stale skill identifier 경고 ${warnings}건 (warn-only)"
  fi
}

main "$@" || warn "stale skill identifier 검사 중 내부 오류 발생 (warn-only)"
exit 0
