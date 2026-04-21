# shellcheck shell=bash
#───────────────────────────────────────────────────────────────────────────────
# codex.sh — NO_CHANGES 경로 전용 ~/.codex/config.toml drift 자동 복구
#
# 호출 위치: modules/{darwin,nixos}/scripts/nrs.sh 의 NO_CHANGES 분기에서만.
#   post-rebuild 경로에서는 home.activation.syncCodexConfig 가 이미 같은
#   sync-codex-config.py 를 돌리므로 여기서 중복 호출하지 않는다.
#
# 부수효과:
#   - `nix shell "$FLAKE_PATH#pythonWithTomlkit" --command` 1회 평가 (~150ms 실측)
#   - `python3 sync-codex-config.py sync <template> $HOME/.codex/config.toml` 실행
#   - 실제 drift가 있을 때만 ~/.codex/config.toml 재작성.
#     no-op 계약(3조건)의 authoritative 서술은 sync-codex-config.py 의 docstring 참고.
#   - 실패는 log_warn 으로 다운그레이드 (non-fatal) — NO_CHANGES 흐름을 막지 않는다.
#
# Offline contract:
#   `nrs --offline`은 preview/switch 경로에 `OFFLINE_FLAG`를 전달해 NO_CHANGES 경로에서도
#   substituter 접근을 피한다. 이 helper도 동일 플래그를 `nix shell` 앞에 붙여 cold cache
#   또는 air-gapped 환경에서 online work를 새로 도입하지 않는다.
#
# 장기 수렴 경로(참고):
#   scripts/ai/lib/tomlkit-bootstrap.sh 가 `nix shell .#pythonWithTomlkit` self-wrap
#   (exec) 패턴을 관리한다. 이 helper 는 exec 이 아닌 subprocess 호출이 필요해
#   현재는 정책을 재기술한다. 향후 양쪽을 공용 bootstrap helper 로 통합할 여지가
#   있으나 이번 범위에서는 YAGNI.
#───────────────────────────────────────────────────────────────────────────────

repair_codex_config_drift_no_changes() {
    # FLAKE_PATH 는 rebuild-common.sh 가 caller 진입점에서 채우는 contract 변수다.
    # public helper 로 노출돼 있어 partial init 호출(set -u 등)에서도 hard crash 대신
    # log_warn 으로 다운그레이드해야 한다는 함수 계약과 어긋나지 않도록 가드.
    if [[ -z "${FLAKE_PATH:-}" ]]; then
        log_warn "⚠️  FLAKE_PATH 미설정 — codex config drift 복구 스킵"
        return 0
    fi
    local template
    if [[ "$(uname -s)" == "Darwin" ]]; then
        template="$FLAKE_PATH/modules/shared/programs/codex/files/config.darwin.toml"
    else
        template="$FLAKE_PATH/modules/shared/programs/codex/files/config.toml"
    fi
    local script="$FLAKE_PATH/modules/shared/programs/codex/files/sync-codex-config.py"

    if ! command -v nix >/dev/null 2>&1; then
        log_warn "⚠️  nix 명령 미가용 — codex config drift 복구 스킵"
        return 0
    fi
    if [[ ! -f "$template" || ! -f "$script" ]]; then
        log_warn "⚠️  codex template/script 부재 — drift 복구 스킵 ($template, $script)"
        return 0
    fi

    # $OFFLINE_FLAG 는 rebuild-common.sh 가 set 하며 "" 또는 "--offline". unquoted expansion 으로
    # 빈 문자열이면 자동 생략. --offline 이면 nix shell 도 substituter 접근을 시도하지 않는다.
    # shellcheck disable=SC2086
    nix shell ${OFFLINE_FLAG:-} "$FLAKE_PATH#pythonWithTomlkit" --command \
        python3 "$script" sync "$template" "$HOME/.codex/config.toml" \
        || log_warn "⚠️  codex config drift 복구 실패 (non-fatal) — 'verify-ai-compat.sh'로 진단"
}
