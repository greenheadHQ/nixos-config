# libraries/python-runtimes.nix
# Python 런타임 derivation 단일 소스 (SoT).
#
# `pythonWithTomlkit`은 Home Manager activation(`modules/shared/programs/codex/default.nix`)의
# `sync-codex-config.py` 호출과 flake의 `packages.${system}.pythonWithTomlkit` output(test/verifier
# 래핑용) 두 경로에서 동일하게 필요하다. 두 경로가 같은 store path를 쓰도록 정의를 여기 한 곳에
# 둔다. Python 버전이나 패키지 추가가 생기면 이 파일만 고치면 된다.
{ pkgs }:

{
  # tomlkit(주석/순서 보존 TOML read/write)만 추가한 python3.
  # sync-codex-config.py가 `import tomlkit` 필수.
  # verify-ai-compat.sh가 `check` subcommand 호출 시 같은 interpreter를 PATH로 요구한다.
  pythonWithTomlkit = pkgs.python3.withPackages (ps: [ ps.tomlkit ]);
}
