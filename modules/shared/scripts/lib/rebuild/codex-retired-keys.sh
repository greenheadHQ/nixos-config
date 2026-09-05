# shellcheck shell=bash
#───────────────────────────────────────────────────────────────────────────────
# codex-retired-keys.sh — 퇴역 Codex config 키 로더 (sourced)
#
# SoT 파일: modules/shared/programs/codex/files/retired-config-keys.txt
#   한 줄에 TOML dotted key 하나. `#` 이후는 주석, 빈 줄 무시, 공백은 모두 제거.
#   (Nix 측 default.nix 의 파서와 같은 규칙 — 두 파서가 같은 파일에서 같은 목록을 낸다.)
#
# 이 로더는 파일 → 인자 배열 변환만 한다. "무엇을 어떻게 제거하는가"의 의미론은
# sync-codex-config.py 의 `--unset` 계약이 단독으로 소유한다.
#
# 소비자: modules/shared/scripts/lib/rebuild/codex.sh (nrs NO_CHANGES drift 복구),
#         scripts/ai/verify-ai-compat.sh (check 모드 감사).
#         activation 경로는 Nix 가 같은 파일을 직접 읽는다 (default.nix retiredConfigKeys).
#───────────────────────────────────────────────────────────────────────────────

CODEX_RETIRED_KEYS_REL_PATH="modules/shared/programs/codex/files/retired-config-keys.txt"

# 사용: codex_retired_config_unset_args <repo_root>
#   성공 시 CODEX_RETIRED_CONFIG_UNSET_ARGS 에 (--unset KEY)... 를 채우고 0을 반환한다.
#   SoT 파일이 없으면 배열을 비우고 1을 반환한다 (호출자가 정책에 맞게 처리).
codex_retired_config_unset_args() {
    local repo_root="${1:-}"
    local file="$repo_root/$CODEX_RETIRED_KEYS_REL_PATH"
    local line

    CODEX_RETIRED_CONFIG_UNSET_ARGS=()
    [[ -n "$repo_root" && -f "$file" ]] || return 1

    # 마지막 줄에 개행이 없어도 처리하도록 `|| [[ -n "$line" ]]`.
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line//[[:space:]]/}"
        [[ -n "$line" ]] || continue
        CODEX_RETIRED_CONFIG_UNSET_ARGS+=(--unset "$line")
    done <"$file"

    return 0
}
