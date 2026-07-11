#!/usr/bin/env bash
# scripts/ai/lib/tomlkit-bootstrap.sh
#
# tomlkit 포함 Python interpreter + GNU coreutils/findutils + lsof + lefthook 테스트 런타임
# 부트스트랩 helper. verifier/test runner가 source한 뒤 `tomlkit_bootstrap_require` 를 호출한다.
# 같은 파일을 여러 진입점이 재사용하므로 재진입 guard env var와 nix shell re-exec 정책을 한 곳에만 둔다.
# (함수/파일명은 역사적 이유로 tomlkit_* 유지 — 실제 책임은 테스트 hermetic runtime 전반이다.)
#
# 정책:
#   1) 이미 `_TOMLKIT_BOOTSTRAP_READY=1` 이면 추가 검사 없이 즉시 반환한다.
#      prePushRuntime runner가 hermetic PATH를 이미 제공했거나, 자체
#      스크립트가 이전에 self-wrap으로 재진입한 경우다.
#   2) current worktree profile이 있으면 그 PATH를 활성화한다. profile은 flake.lock + runtime
#      정의 content stamp까지 일치해야 하며, staged snapshot은 검증된 source root의 profile을 쓴다.
#   3) profile이 없거나 stale이면 ambient `python3`/GNU 도구 유무와 **무관하게** repo-pinned `nix shell
#      --inputs-from . .#pythonWithTomlkit nixpkgs#coreutils nixpkgs#findutils nixpkgs#lsof
#      nixpkgs#lefthook --command bash "$0" ...`로 재실행한다. host 에 우연히 tomlkit 이 있거나
#      GNU 도구가 없더라도 pre-push 와 동일한 store path 의 interpreter + GNU coreutils/findutils
#      (karakeep/backup fixture 의 `touch -d`/`find -printf` 의존, #1009) + lsof(claude-rc #1052)
#      + lefthook(auto-sync end-to-end 테스트)을 쓰게 만들어 hermetic 속성을 유지한다.
#   4) nix가 없으면 마지막 fallback으로 ambient python3 tomlkit import를 체크해 있으면 그대로
#      진행(경고 출력), 없으면 hard fail. 개발자가 직접 nix shell을 띄운 상태라면 (1)으로 빠진다.
#
# 사용:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
#   # shellcheck disable=SC1091
#   . "$REPO_ROOT/scripts/ai/lib/tomlkit-bootstrap.sh"
#   tomlkit_bootstrap_require "$REPO_ROOT" "${BASH_SOURCE[0]}" "$@"
#
# tomlkit_bootstrap_require는 재실행이 필요하면 `exec`으로 교체되어 돌아오지 않는다.
# 교체 없이 반환됐다면 이후 코드에서 `python3 -c 'import tomlkit'`를 전제해도 안전하다.

tomlkit_bootstrap_require() {
  local repo_root="$1"
  local self_path="$2"
  shift 2

  # (1) 이미 tomlkit-ready 환경이면 즉시 반환
  if [ -n "${_TOMLKIT_BOOTSTRAP_READY:-}" ]; then
    return 0
  fi

  # flake root 결정: staged-snapshot 안에서 실행되면 repo_root/self_path 가 임시 snapshot
  # 경로다. 그대로 `nix shell <snapshot>#pythonWithTomlkit` 하면 snapshot 트리 전체가 nix
  # store 로 복사·평가된다 (E2E 실측 ~42s). run-staged-snapshot.sh 가 STAGED_SNAPSHOT_SOURCE_ROOT
  # 로 실제 repo 경로를 넘기면 그 flake 를 쓴다.
  # pythonWithTomlkit 은 검사 대상이 아니라 tomlkit 포함 interpreter 일 뿐이라 안전하며,
  # flake.nix / libraries/python-runtimes.nix 의 staged 변경 검증은 eval-tests(glob: *.nix)가
  # 책임진다.
  # override 는 staged-snapshot consumer 안에서 실행될 때만 적용한다. run-staged-snapshot.sh 는
  # cwd 를 공유 캐시 worktree 로 바꾸면서 STAGED_SNAPSHOT_ROOT(worktree)와 STAGED_SNAPSHOT_SOURCE_ROOT
  # (실제 repo)를 generic context 로 함께 export 한다. 조건은 (a) STAGED_SNAPSHOT_SOURCE_ROOT 존재,
  # (b) repo_root == STAGED_SNAPSHOT_ROOT, (c) repo_root 가 실제 git repo 가 아님(materialized snapshot
  # 은 checkout-index 결과라 .git 이 없어 `rev-parse --git-dir` 가 실패) 을 모두 만족할 때만이다.
  # (c) 가드가 pre-push/실제 repo/임의 경로에서 ambient STAGED_SNAPSHOT_* env 로 외부 flake 를 주입하는
  # spoof 를 막는다. cache 경로 구현 세부나 runner 의 tomlkit 전용 변수에 의존하지 않는 명시적 계약이다.
  # (d) source root 가 실제 git checkout 일 때만 override. 환경변수가 stale/malformed 면
  #     `nix shell <bad>#pythonWithTomlkit` 으로 hard-fail 하는 대신 repo_root 로 안전 fallback.
  local flake_root="$repo_root"
  if [ -n "${STAGED_SNAPSHOT_SOURCE_ROOT:-}" ] && [ "$repo_root" = "${STAGED_SNAPSHOT_ROOT:-}" ] \
    && ! git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1 \
    && git -C "$STAGED_SNAPSHOT_SOURCE_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    flake_root="$STAGED_SNAPSHOT_SOURCE_ROOT"
  fi

  # (2) devShell이 사전 빌드한 current runtime profile을 우선 재사용한다. staged snapshot에서는
  # 위 spoof guard를 모두 통과한 source checkout의 profile을 찾으므로 snapshot마다 flake를 다시
  # store-copy/eval하지 않는다. helper가 없는 partial checkout은 기존 nix shell 경로로 폴백한다.
  local runtime_profile_module="$repo_root/scripts/ai/test-runtime-profile.sh"
  if [ -f "$runtime_profile_module" ]; then
    # shellcheck disable=SC1090  # repo 내부의 계산된 고정 경로
    . "$runtime_profile_module"
    if test_runtime_profile_activate "$flake_root"; then
      return 0
    fi
  fi

  # (3) nix 가용 → repo-pinned runtime으로 재실행 (hermetic 강제). 스크립트 자체는 self_path
  #     (snapshot 경로 가능)에서 계속 실행하고, flake root 만 실제 repo 로 고정한다.
  if command -v nix >/dev/null 2>&1; then
    echo "  test runtime bootstrap: nix shell --inputs-from ${flake_root} ${flake_root}#pythonWithTomlkit nixpkgs#coreutils nixpkgs#findutils nixpkgs#lsof nixpkgs#lefthook --command bash $self_path" >&2
    export _TOMLKIT_BOOTSTRAP_READY=1
    # pythonWithTomlkit(tomlkit) 외에 GNU coreutils/findutils 와 lsof 를 함께 얹어, 테스트 fixture 가
    # GNU 전용 확장(`touch -d '40 days ago'`, `find -printf`)에 의존해도 devShell 밖(BSD 시스템
    # 도구 우선) 셸에서 hermetic 하게 통과하도록 한다 (#1009). claude-rc(#1052)도 require_cmd lsof 를
    # 도입했고, lsof 는 NixOS 시스템 프로파일 PATH 에 항상 있지 않으므로 profile 미가용
    # pre-commit/bootstrap과 수동 실행도 이 self-wrap으로 같은 도구 집합을 유지한다.
    # lefthook auto-sync end-to-end 테스트는 stub 이 아닌 실제 lefthook 을 요구하는데, hook 이
    # lefthook 을 nix store 절대경로로 호출하면 자식 PATH 에 lefthook 이 없다 — nixpkgs#lefthook 도 얹는다.
    # `--inputs-from ${flake_root}` 로 nixpkgs# 를 repo flake.lock 의 nixpkgs 에 pin 하여 임시
    # registry fetch 를 피한다. 이 경로는 profile 부재/stale 시의 호환 fallback이다.
    exec nix shell --inputs-from "${flake_root}" "${flake_root}#pythonWithTomlkit" nixpkgs#coreutils nixpkgs#findutils nixpkgs#lsof nixpkgs#lefthook --command bash "$self_path" "$@"
  fi

  # (4) nix 부재 fallback — ambient python3에 tomlkit이 있으면 경고 후 진행
  if python3 -c 'import tomlkit' 2>/dev/null; then
    echo "  tomlkit bootstrap: nix 명령 미가용, ambient python3의 tomlkit을 사용한다 (non-hermetic)" >&2
    export _TOMLKIT_BOOTSTRAP_READY=1
    return 0
  fi

  echo "  [FAIL] tomlkit 미가용 + nix 명령도 없음 — 'nix develop' 또는 'nix shell .#pythonWithTomlkit' 환경이 필요합니다" >&2
  exit 1
}
