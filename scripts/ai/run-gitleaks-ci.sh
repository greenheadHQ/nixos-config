#!/usr/bin/env bash
# PR base..head의 commit diff만 검사한다. 전체 과거 이력·빈 staged index 검사가 아니다.
# 정책은 제출 head의 Git 객체에서 고정하며 작업 파일과 실제 index를 바꾸지 않는다.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VALIDATOR_PATH="scripts/ai/validate-gitleaks-staged-policy.py"

fail() {
  printf 'gitleaks CI: %s\n' "$*" >&2
  exit 2
}

[ "$#" -eq 2 ] || fail "base와 head의 전체 commit ID가 필요합니다."
base="$1"
head="$2"
for commit in "$base" "$head"; do
  [[ "$commit" =~ ^[0-9a-fA-F]{40}$|^[0-9a-fA-F]{64}$ ]] \
    || fail "commit ID 형식이 올바르지 않습니다."
done

# 외부 Git context가 검사 저장소·index를 다른 대상으로 돌리지 못하게 한다.
while IFS= read -r name; do
  case "$name" in GIT_*) unset "$name" ;; esac
done < <(compgen -e)

command -v gitleaks >/dev/null 2>&1 || fail "고정된 개발 환경의 gitleaks가 필요합니다."
command -v python3 >/dev/null 2>&1 || fail "정책 검증용 Python이 필요합니다."
git_dir=$(git -C "$REPO_ROOT" rev-parse --absolute-git-dir 2>/dev/null) \
  || fail "검사 저장소를 확인할 수 없습니다."
for commit in "$base" "$head"; do
  git -C "$REPO_ROOT" cat-file -e "${commit}^{commit}" 2>/dev/null \
    || fail "검사 commit 객체가 없습니다. checkout 이력 준비를 확인하세요."
done
git -C "$REPO_ROOT" merge-base "$base" "$head" >/dev/null 2>&1 \
  || fail "base와 head의 공통 이력을 확인할 수 없습니다."

umask 077
scratch=$(mktemp -d "${TMPDIR:-/tmp}/gitleaks-ci.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
snapshot="$scratch/tree"
index="$scratch/index"
mkdir "$snapshot"

scan_git() {
  GIT_DIR="$git_dir" GIT_WORK_TREE="$snapshot" GIT_INDEX_FILE="$index" \
    git "$@"
}

scan_git read-tree "$head" 2>/dev/null || fail "정책 index를 준비하지 못했습니다."
# symlink 대상은 따라가지 않는다. 정책 symlink는 아래 index mode 검사에서 거부한다.
scan_git -c core.symlinks=false checkout-index --all --prefix="$snapshot/" 2>/dev/null \
  || fail "제출 head의 정책 snapshot을 준비하지 못했습니다."

index_mode() {
  scan_git ls-files -s -- "$1" | awk 'NF { print $1 ":" $3 }'
}

[ "$(index_mode .gitleaks.toml)" = "100644:0" ] \
  || fail "탐지 정책은 제출된 일반 파일이어야 합니다."
ignore="$scratch/empty-ignore"
: > "$ignore"
ignore_mode=$(index_mode .gitleaksignore) || fail "예외 정책을 확인하지 못했습니다."
if [ -n "$ignore_mode" ]; then
  [ "$ignore_mode" = "100644:0" ] || fail "예외 정책은 제출된 일반 파일이어야 합니다."
  ignore="$snapshot/.gitleaksignore"
fi
case "$(index_mode "$VALIDATOR_PATH")" in
  100644:0 | 100755:0) ;;
  *) fail "정책 검증기는 제출된 일반 파일이어야 합니다." ;;
esac

# 기존 staged 정책의 extend 경로·순환·파일 종류 검증을 그대로 재사용한다.
# 파싱 오류에 원문이 포함될 수 있으므로 도구 출력을 게시 로그로 전달하지 않는다.
python3 "$snapshot/$VALIDATOR_PATH" --snapshot "$snapshot" --git-dir "$git_dir" --index "$index" \
  >/dev/null 2>&1 || fail "제출된 탐지 정책 검증에 실패했습니다."

# -m은 merge가 추가한 diff, --no-renames는 이름 변경의 새 경로 내용도 검사한다.
# 외부 diff/textconv를 실행하지 않는다. 정책의 commit fingerprint 예외도 유지한다.
# 탐지값뿐 아니라 오류 원문·commit 메타데이터도 CI 로그에 새로 노출하지 않는다.
# 내부 git log 오류를 gitleaks가 exit 0으로 반환할 수 있어 error 출력도 확인한다.
scan_status=0
scan_output=$(
  cd "$snapshot" 2>/dev/null || exit 2
  gitleaks git "$REPO_ROOT" --no-banner --no-color --log-level error --redact=100 --exit-code 10 \
    --config ./.gitleaks.toml --gitleaks-ignore-path "$ignore" \
    --log-opts="--full-history -m --no-renames --no-ext-diff --no-textconv ${base}..${head}" 2>&1
) || scan_status=$?
[ -z "$scan_output" ] || fail "검사 도구가 오류를 보고했습니다. 원문은 출력하지 않습니다."
case "$scan_status" in
  0) printf 'gitleaks CI: PR commit 범위 검사 통과.\n' ;;
  10) printf 'gitleaks CI: PR commit 범위에서 탐지 대상이 발견되었습니다. 원문은 출력하지 않습니다.\n' >&2; exit 10 ;;
  *) fail "검사 도구가 실패했습니다. 탐지 성공으로 처리하지 않습니다." ;;
esac
