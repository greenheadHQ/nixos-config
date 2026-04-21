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

  # (2) nix 가용 → 무조건 repo-pinned runtime으로 재실행 (hermetic 강제)
  if command -v nix >/dev/null 2>&1; then
    echo "  tomlkit bootstrap: nix shell ${repo_root}#pythonWithTomlkit --command bash $self_path" >&2
    export _TOMLKIT_BOOTSTRAP_READY=1
    exec nix shell "${repo_root}#pythonWithTomlkit" --command bash "$self_path" "$@"
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
