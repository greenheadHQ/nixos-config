#!/usr/bin/env bash
# scripts/ai/lib/tomlkit-bootstrap.sh
#
# tomlkit 포함 Python interpreter 부트스트랩 helper. verifier/test runner가 source한 뒤
# `tomlkit_bootstrap_require` 를 호출한다. 같은 파일을 여러 진입점이 재사용하므로 재진입
# guard env var와 nix shell re-exec 정책을 한 곳에만 둔다.
#
# 정책:
#   1) 이미 `_TOMLKIT_BOOTSTRAP_READY=1` 이면 추가 검사 없이 즉시 반환한다.
#      lefthook pre-push가 `nix shell .#pythonWithTomlkit --command ...`로 이미 감쌌거나,
#      자체 스크립트가 이전에 self-wrap으로 재진입한 경우다.
#   2) 아니면 ambient `python3`가 tomlkit을 import할 수 있는지와 **무관하게** 항상
#      repo-pinned `nix shell .#pythonWithTomlkit --command bash "$0" ...`로 재실행한다.
#      host python에 우연히 tomlkit이 있더라도 pre-push와 동일한 store path의
#      interpreter를 쓰게 만들어 hermetic 속성을 유지한다.
#   3) nix가 없으면 마지막 fallback으로 ambient python3 tomlkit import를 체크해 있으면 그대로
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

  # (2) nix 가용 → repo-pinned runtime으로 재실행 (hermetic 강제). 스크립트 자체는 self_path
  #     (snapshot 경로 가능)에서 계속 실행하고, flake root 만 실제 repo 로 고정한다.
  if command -v nix >/dev/null 2>&1; then
    echo "  tomlkit bootstrap: nix shell ${flake_root}#pythonWithTomlkit --command bash $self_path" >&2
    export _TOMLKIT_BOOTSTRAP_READY=1
    exec nix shell "${flake_root}#pythonWithTomlkit" --command bash "$self_path" "$@"
  fi

  # (3) nix 부재 fallback — ambient python3에 tomlkit이 있으면 경고 후 진행
  if python3 -c 'import tomlkit' 2>/dev/null; then
    echo "  tomlkit bootstrap: nix 명령 미가용, ambient python3의 tomlkit을 사용한다 (non-hermetic)" >&2
    export _TOMLKIT_BOOTSTRAP_READY=1
    return 0
  fi

  echo "  [FAIL] tomlkit 미가용 + nix 명령도 없음 — 'nix develop' 또는 'nix shell .#pythonWithTomlkit' 환경이 필요합니다" >&2
  exit 1
}
