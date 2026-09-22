# tests/suites/stdenv-platform-guard.sh — 플랫폼 판정 surface 회귀 가드 (sourced; aggregator가 lib/test-common.sh 후 source)
# shellcheck shell=bash
# SC2154: REPO_ROOT 등 공통 변수는 aggregator가 정의.
# shellcheck disable=SC2154

# nixpkgs는 stdenv의 플랫폼 별칭(stdenv.isDarwin 등)을 deprecate했다 (2026-05-09;
# pkgs/stdenv/generic/default.nix에서 config.allowAliases 하에 lib.warn으로 래핑).
# 별칭은 여전히 값을 돌려주고 평가를 막지도 않으며, lib.warn이 attribute thunk를 최초 1회만
# 평가하므로 사용처가 몇 곳이든 `nrs` 출력에는 별칭당 warning 한 줄만 남는다. 그래서 재도입은
# 빌드 성공과 함께 조용히 누적된다 — 실제로 22곳까지 쌓인 뒤에 발견됐다.
# 판정 surface는 stdenv.hostPlatform.is* 하나로 고정하고, 이 가드가 그 상태를 박제한다.
#
# 한계 둘. (1) 정적 문자열 검사라 `inherit (stdenv) isDarwin;` 같은 간접 접근은 잡지 못한다 —
# 이 저장소에 그 선례가 없어 주 패턴만 막으며, 새 우회 형태가 관측되면 패턴을 확장한다.
# (2) 코드와 주석을 구분하지 않으므로 .nix 주석에서 별칭을 언급할 때도 걸린다. 제외 목록은
# 그대로 우회 경로가 되므로 두지 않는다 — 대신 `stdenv.is*`처럼 판정자 이름을 끊어 적는다
# (tests/eval-tests.nix의 주석이 그 예다).
_DEPRECATED_STDENV_PREDICATE_RE='stdenv[A-Za-z]*\.is[A-Za-z]'

_scan_deprecated_stdenv_predicates() {
  # $1 = git repo 경로. tracked *.nix 만 본다 — 이 가드 자신과 스킬 문서는 .sh/.md 라 제외된다.
  # git grep rc: 0=매치 있음, 1=매치 없음, >1=스캔 자체가 실패. `|| true`로 뭉뚱그리면 스캔이
  # 깨진 순간이 "검출 0"과 구분되지 않아 가드가 공허하게 통과한다. 저장소의 기존 잔존참조
  # 스캔(scripts/ai/lib/host-state-checks.sh)과 같은 rc 규약을 따라 >1은 실패로 올린다.
  # stderr는 리다이렉트하지 않는다 — 실패 원인이 테스트 출력에 그대로 남아야 한다.
  local out rc=0
  out="$(git -C "$1" grep -nE "$_DEPRECATED_STDENV_PREDICATE_RE" -- '*.nix')" || rc=$?
  [ "$rc" -le 1 ] || fail "deprecated stdenv 별칭 스캔이 실패했다 (git grep rc=$rc, repo=$1)"
  printf '%s' "$out"
}

test_nix_sources_use_host_platform_predicates() {
  local hits
  hits="$(_scan_deprecated_stdenv_predicates "$REPO_ROOT")"
  [[ -z "$hits" ]] || fail "deprecated stdenv 플랫폼 별칭 사용 — stdenv.hostPlatform.is* 로 바꿀 것:
$hits"
}

test_deprecated_stdenv_predicate_scan_detects_regression() {
  # 가드 자기검증: 위 테스트는 "검출 0"으로 통과하므로 정규식이 무력화되면 조용히 통과한다.
  # 정탐(별칭 직접 접근)과 오탐 부재(hostPlatform 경유)를 fixture repo로 함께 박제한다.
  local sandbox repo hits
  sandbox="$(new_sandbox)"
  repo="$sandbox/repo"
  # 호스트 전역 git 설정(core.excludesFile·init.templateDir 등)이 fixture 결과를 흔들지
  # 않도록 저장소 공용 격리 헬퍼를 쓴다 — 격리 정책의 단일 출처는 tests/lib/test-common.sh다.
  create_git_fixture_repo "$repo"
  printf '{ pkgs, lib }: lib.optionals pkgs.stdenv.isLinux [ ]\n' > "$repo/deprecated-stdenv.nix"
  printf '{ stdenvNoCC }: stdenvNoCC.isDarwin\n' > "$repo/deprecated-stdenvnocc.nix"
  printf '{ pkgs, lib }: lib.optionals pkgs.stdenv.hostPlatform.isLinux [ ]\n' > "$repo/host-platform.nix"
  git -C "$repo" add deprecated-stdenv.nix deprecated-stdenvnocc.nix host-platform.nix
  hits="$(_scan_deprecated_stdenv_predicates "$repo")"
  assert_contains "$hits" "deprecated-stdenv.nix"
  assert_contains "$hits" "deprecated-stdenvnocc.nix"
  assert_not_contains "$hits" "host-platform.nix"
}
