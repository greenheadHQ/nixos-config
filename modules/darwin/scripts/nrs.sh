#!/usr/bin/env bash
# darwin-rebuild wrapper script
# 문제 예방: setupLaunchAgents 멈춤, Hammerspoon HOME 오염
#
# 사용법:
#   nrs           # 일반 rebuild
#   nrs --offline # 오프라인 rebuild (빠름)
#   nrs --force   # NO_CHANGES 스킵 우회 (activation scripts 강제 재실행)
#   nrs --help    # 사용법 출력

set -euo pipefail

# shellcheck disable=SC2034  # REBUILD_CMD는 source된 rebuild-common.sh에서 사용
REBUILD_CMD="darwin-rebuild"
# shellcheck disable=SC2034  # REBUILD_MODE는 source된 rebuild-common.sh의 usage 분기에서 사용
REBUILD_MODE="switch"
# shellcheck source=/dev/null  # 런타임에 ~/.local/lib/rebuild-common.sh 로딩
source "$HOME/.local/lib/rebuild-common.sh"
parse_args "$@"

# repo-local 최신 entrypoint가 이전 deployed helper tree와 조합돼도 동작하도록 유지.
install_rebuild_common_compat_shims() {
    declare -F rebuild_is_main_flake >/dev/null || rebuild_is_main_flake() {
        [[ "$FLAKE_PATH" == "$MAIN_FLAKE_PATH" ]]
    }
    declare -F prepare_worktree_symlinks_for_rebuild >/dev/null || prepare_worktree_symlinks_for_rebuild() {
        log_info "🔗 Removing worktree symlinks before rebuild..."
        _remove_worktree_symlinks "$FLAKE_PATH/" "worktree" || true
        "$HOME/.local/bin/nrs-relink" restore || log_warn "⚠️  nrs-relink restore failed (non-fatal)"
    }
    declare -F release_nrs_lock_after_no_changes >/dev/null || release_nrs_lock_after_no_changes() {
        if [[ "${NRS_LOCK_ACQUIRED:-false}" == true && "${NRS_LOCK_REENTRY:-false}" != true ]]; then
            release_nrs_lock
        fi
    }
    declare -F mark_nrs_lock_switch_success >/dev/null || mark_nrs_lock_switch_success() {
        # shellcheck disable=SC2034  # Older deployed helpers still read this global in failure cleanup.
        NRS_LOCK_SWITCH_SUCCESS=true
    }
    local codex_legacy_hooks_helper
    local -a codex_legacy_hooks_candidates=()
    if [[ -n "${REBUILD_COMMON_LIB_DIR:-}" ]]; then
        codex_legacy_hooks_candidates+=("$REBUILD_COMMON_LIB_DIR/codex-legacy-hooks.sh")
    fi
    codex_legacy_hooks_candidates+=("$FLAKE_PATH/modules/shared/scripts/lib/rebuild/codex-legacy-hooks.sh")

    for codex_legacy_hooks_helper in "${codex_legacy_hooks_candidates[@]}"; do
        [[ -n "$codex_legacy_hooks_helper" && -f "$codex_legacy_hooks_helper" ]] || continue
        # shellcheck source=/dev/null
        source "$codex_legacy_hooks_helper"
        declare -F codex_clear_retired_hook_artifacts >/dev/null && break
    done
    declare -F codex_clear_retired_hook_artifacts >/dev/null && _clear_retired_codex_hook_artifacts() {
        codex_clear_retired_hook_artifacts "$FLAKE_PATH" "$HOME"
    }
    # 구버전 rebuild-common.sh 는 codex helper 가 없어 이 함수도 없다. 그 조합에서는
    # NO_CHANGES 경로가 "command not found"로 죽지 않도록 no-op shim 을 둔다. 사용자가
    # 한 번 nrs --force 로 새 HM generation 을 활성화하면 shim 이 실 helper 로 교체된다.
    declare -F repair_codex_config_drift_no_changes >/dev/null || repair_codex_config_drift_no_changes() {
        return 0
    }
    declare -F codex_managed_artifacts_missing >/dev/null || codex_managed_artifacts_missing() {
        return 1
    }
    declare -F codex_log_managed_artifacts_missing >/dev/null || codex_log_managed_artifacts_missing() {
        return 0
    }
}

install_rebuild_common_compat_shims

#───────────────────────────────────────────────────────────────────────────────
# launchd 에이전트 정리
#───────────────────────────────────────────────────────────────────────────────
cleanup_launchd_agents() {
    log_info "🧹 Cleaning up launchd agents..."

    local uid cleaned=0 exit_code agent_list
    # failed_agents가 실패 사실의 단일 소스다 (별도 카운터를 두면 갱신 누락으로 어긋난다).
    local -a failed_agents=()
    uid=$(id -u)

    # `launchctl list` 출력을 먼저 변수로 받는다. 아래 while에 process substitution으로 바로
    # 흘려보내면 이 명령의 실패가 set -e에도 잡히지 않고 루프가 0회 도는 것으로 끝난다.
    # 그러면 failed_agents가 빈 채로 아래 삭제 루프가 돌아, 실제로는 booted인 agent의 plist까지
    # 전량 삭제된다 — 이 함수가 막으려는 부분 활성화를 정확히 유발하는 경로다.
    # 목록을 못 얻으면 어느 것이 살아 있는지 알 수 없으므로 정리를 건너뛴다. cleanup 효과는
    # 잃지만(setupLaunchAgents 멈춤 가능성은 관측 가능하고 복구 절차가 있다), 조용한 손상은 막는다.
    if ! agent_list=$(launchctl list 2>/dev/null); then
        log_warn "  ⚠️  launchctl list 실패 — 어떤 agent가 로드됐는지 알 수 없어 정리를 건너뜁니다."
        log_warn "     rebuild가 setupLaunchAgents에서 멈추면 Ctrl+C 후 수동 정리하세요."
        return 0
    fi

    # 동적으로 com.green.*/com.greenhead.* 에이전트 찾아서 정리 (username 마이그레이션 전환기: dual-namespace)
    # 주의: ((++var)) 사용 필수. ((var++))는 var=0일 때 exit code 1 반환 → set -e로 스크립트 종료됨
    while IFS= read -r agent; do
        [[ -z "$agent" ]] && continue

        if launchctl bootout "gui/${uid}/${agent}" 2>/dev/null; then
            ((++cleaned))
        else
            # 에이전트가 이미 없는 경우는 무시, 다른 에러는 기록
            exit_code=$?
            if [[ $exit_code -ne 3 ]]; then  # 3 = No such process (정상)
                log_warn "  ⚠️  Failed to bootout: $agent (exit: $exit_code)"
                failed_agents+=("$agent")
            fi
        fi
    done < <(printf '%s\n' "$agent_list" | awk '/com\.(green|greenhead)\./ {print $3}')

    # plist 파일 삭제 — 단, bootout에 실패한 agent의 plist는 남긴다.
    #
    # plist를 지우면 home-manager의 processAgent가 `[[ -f "$dstPath" ]]` 게이트에서 빠져
    # bootout을 건너뛰고, 여전히 booted 상태인 label에 bootstrap을 시도해 실패한다.
    # 현재 home-manager는 그 실패를 삼키지 않는다 — setupLaunchAgents의 상태코드를 받아
    # 명시적으로 exit하므로 뒤따르는 linkGeneration 등이 통째로 스킵되고, 새 plist는
    # 설치됐는데 home 파일 심링크는 구 세대를 가리키는 부분 활성화 상태가 된다.
    #
    # 근거 좌표 (home-manager 업데이트 후 재확인용): home-manager `modules/launchd/default.nix`의
    # processAgent — `[[ -f "$dstPath" ]]` bootout 게이트와, 활성 세대 activate 스크립트 말미의
    # `setupLaunchAgents || launchdStatus=$?` → `exit "$launchdStatus"`.
    # 두 지점이 사라졌다면 이 보존 로직의 전제도 다시 검토한다.
    #
    # 보존이 곧 자동 복구는 아니다. processAgent에는 bootout 게이트보다 앞서
    # "Skip if unchanged" 게이트(`cmp -s "$srcPath" "$dstPath"` + `agentIsLoaded`)가 있어,
    # plist 내용이 그대로이고 agent가 여전히 loaded면 bootout에 도달하지 않고 return 0 한다.
    # bootout 실패는 대개 loaded 상태이므로, plist가 바뀌지 않으면 activation은 no-op이다.
    # 즉 보존의 효과는 "복구"가 아니라 "이번 rebuild를 깨뜨리지 않음"이다.
    #
    # trade-off: 두 실패 모드의 성질이 다르다. 삭제 시에는 activation이 중단되어 home 심링크가
    # 구 세대를 가리키는 부분 활성화가 조용히 남는다 — 이후 모든 작업이 어긋난다. 보존 시에는
    # 해당 agent만 구 상태로 남고 나머지 activation은 정상 완료된다. 피해 범위가 좁은 쪽을 택했다.
    # (보존한 plist가 bootoutAgent 경로로 가는 경우 macOS 26 이상에서는 `launchctl bootout --wait`라
    #  멈출 수 있다. 그때는 Ctrl+C 후 managing-macos/references/troubleshooting.md의 절차를 따른다.)
    local removed=0 plist label f is_failed
    while IFS= read -r plist; do
        [[ -z "$plist" ]] && continue
        label=$(basename "$plist" .plist)

        # 배열 멤버십 판정: 공백 포함 label에도 안전하도록 명시적 비교를 쓴다.
        # `${arr[@]+"${arr[@]}"}`는 set -u에서 빈 배열 확장이 unbound로 죽는 것을 막는
        # 관용구다 (bash 4.4 미만 호환). 이 스크립트는 set -euo pipefail 아래에서 돈다.
        is_failed=false
        for f in ${failed_agents[@]+"${failed_agents[@]}"}; do
            [[ "$f" == "$label" ]] && { is_failed=true; break; }
        done

        if [[ "$is_failed" == true ]]; then
            log_warn "  ⚠️  Kept plist for $label (bootout 실패 — 삭제 시 activation 중단을 피함)"
            continue
        fi
        rm -f "$plist"
        ((++removed))
        # -maxdepth 1: 기존 top-level glob(`~/Library/LaunchAgents/com.green*.plist`)의 범위를
        # 유지한다. 빼면 하위 디렉토리 항목까지 rm 대상이 된다.
        # -type f: glob에는 없던 추가 제약이다. home-manager는 plist를 `install -Dm444`로
        # 일반 파일로 설치하므로 정상 상태에서는 결과가 같고, 심링크나 디렉토리가 이 이름으로
        # 있다면 우리가 만든 것이 아니므로 건드리지 않는다.
    done < <(find ~/Library/LaunchAgents -maxdepth 1 -type f -name 'com.green*.plist' 2>/dev/null)

    if [[ "$removed" -gt 0 ]]; then
        log_info "  ✓ Removed $removed plist file(s)"
    fi

    if [[ $cleaned -gt 0 ]]; then
        log_info "  ✓ Cleaned up $cleaned agent(s)"
    fi
    if [[ ${#failed_agents[@]} -gt 0 ]]; then
        log_warn "  ⚠️  ${#failed_agents[@]} agent(s) failed to bootout — plist를 남겨 두었습니다."
        log_warn "     rebuild 후에도 이 agent가 구 상태로 남아 있으면 아래로 언로드하세요."
        log_warn "     (plist는 남겨둡니다 — 다음 rebuild가 재적재를 시도할 수 있도록)"
        local fa
        for fa in "${failed_agents[@]}"; do
            log_warn "       launchctl bootout gui/${uid}/${fa}"
        done
    fi

    # launchd 내부 상태 정리 대기
    sleep 1
}

#───────────────────────────────────────────────────────────────────────────────
# darwin-rebuild switch 실행
#───────────────────────────────────────────────────────────────────────────────
run_darwin_rebuild() {
    if [[ -n "$OFFLINE_FLAG" ]]; then
        log_info "🔨 Applying changes (offline)..."
    else
        log_info "🔨 Applying changes..."
    fi

    local rc=0
    # 비TTY(에이전트·자동화)에서는 sudo 인증 프롬프트에 응답할 수 없다. -n으로 호출해
    # NOPASSWD 규칙(modules/darwin/configuration.nix의 security.sudo.extraConfig,
    # darwin-rebuild 한정) 미매칭 시 무한 대기 대신 즉시 실패시킨다.
    local -a sudo_flags=()
    [[ -t 0 ]] || sudo_flags=(-n)
    # shellcheck disable=SC2086
    sudo ${sudo_flags[@]+"${sudo_flags[@]}"} "$REBUILD_CMD" switch --flake "$FLAKE_PATH" $OFFLINE_FLAG $CORES_FLAG || rc=$?

    if [[ "$rc" -ne 0 ]]; then
        log_error "❌ darwin-rebuild switch failed (exit code: $rc)"
        # 비대화형 sudo 인증 실패와 darwin-rebuild 자체 실패를 구분해 안내.
        # 판정은 -ll 출력의 !authenticate 파싱 — rc 기반(sudo -n -l <cmd>) 판정은
        # admin (ALL) ALL 규칙 때문에 인증이 필요한 명령에도 rc 0이라 성립하지 않는다.
        if [[ ${#sudo_flags[@]} -gt 0 ]] \
           && ! sudo -n -ll "$REBUILD_CMD" switch 2>/dev/null | grep -q '!authenticate'; then
            log_warn "⚠️  원인: 비대화형 sudo 인증 실패 — NOPASSWD 규칙이 darwin-rebuild에 매칭되지 않았습니다."
            log_warn "   확인: sudo -n -ll $REBUILD_CMD switch 출력에 'Options: !authenticate'가 있어야 정상"
            log_warn "   규칙: modules/darwin/configuration.nix의 security.sudo.extraConfig"
        fi
        if [[ -n "${UNINSTALLED_CASKS:-}" ]]; then
            echo ""
            log_warn "⚠️  The following cask(s) were uninstalled before rebuild:"
            # shellcheck disable=SC2086  # 의도적 word splitting — 공백 구분 cask 목록
            for cask in $UNINSTALLED_CASKS; do
                echo "    brew install --cask $cask"
            done
            echo "  Run the above to restore if needed."
        fi
        exit "$rc"
    fi
}

#───────────────────────────────────────────────────────────────────────────────
# Hammerspoon 재시작
#───────────────────────────────────────────────────────────────────────────────
restart_hammerspoon() {
    log_info "🔄 Restarting Hammerspoon..."

    # Hammerspoon이 실행 중인 경우에만 재시작
    if pgrep -x "Hammerspoon" > /dev/null; then
        killall Hammerspoon 2>/dev/null || true
        sleep 1
    fi

    open -a Hammerspoon
    log_info "  ✓ Hammerspoon restarted"
}

#───────────────────────────────────────────────────────────────────────────────
# 메인
#───────────────────────────────────────────────────────────────────────────────
main() {
    # darwin-rebuild build가 pwd에 ./result를 생성하므로 디렉토리 이동 필수
    cd "$FLAKE_PATH" || exit 1
    trap 'cleanup_build_artifacts; release_rebuild_lock_on_failure; release_nrs_lock_on_failure' EXIT

    _clear_retired_codex_hook_artifacts
    echo ""
    acquire_nrs_lock
    preview_changes "preview" "Changes to be applied:"
    if [[ "$NO_CHANGES" == true && "$FORCE_FLAG" != true ]]; then
        if codex_managed_artifacts_missing; then
            echo ""
            codex_log_managed_artifacts_missing
        else
            echo ""
            log_info "✅ No changes to apply. Skipping rebuild."
            log_info "  (Use 'nrs --force' to force full rebuild including activation scripts)"
            # Safety: HM gcroot가 유효할 때만 실행 — gcroot 파손 시 Phase 1(rm)만 되고
            # Phase 2(restore) 실패하여 심링크 유실 방지. 이 경로는 rebuild 없이
            # 종료되므로 HM activation이 심링크를 재생성할 기회도 없다.
            if [[ -e "$HOME/.local/state/home-manager/gcroots/current-home" ]]; then
                maybe_relink_or_restore
            fi
            repair_codex_config_drift_no_changes
            release_nrs_lock_after_no_changes
            return 0
        fi
    fi
    worktree_symlink_guard

    # Critical section: cask conflict resolve + cleanup + restore + switch를 serialize
    # cleanup이 lock 밖에 있으면 다른 프로세스의 switch와 겹칠 수 있으므로 lock 안에서 실행하고,
    # preflight_cask_conflict_check의 brew uninstall도 같은 이유로 lock 안에 둔다.
    acquire_rebuild_lock
    preflight_cask_conflict_check
    cleanup_launchd_agents
    # Pre-rebuild restore:
    # HM activation의 checkLinkTargets가 non-HMF 심링크(worktree 타깃)를
    # "would be clobbered"로 거부하므로, rebuild 전에 먼저 복원한다.
    # - main: maybe_relink_or_restore() → stale worktree symlink 제거 + nix store 복원
    # - worktree: worktree 심링크 직접 제거 + nrs-relink restore로 기존 entry 복원
    #   (activation 성공 후 maybe_relink_or_restore()가 다시 worktree로 relink)
    # Safety: HM gcroot가 유효할 때만 실행 — gcroot 파손 시 Phase 1(rm)만 되고
    # Phase 2(restore) 실패하여 심링크 유실 방지 (NixOS wrapper와 동일 guard)
    if rebuild_is_main_flake \
       && [[ -e "$HOME/.local/state/home-manager/gcroots/current-home" ]]; then
        maybe_relink_or_restore
    elif ! rebuild_is_main_flake; then
        prepare_worktree_symlinks_for_rebuild
    fi
    run_darwin_rebuild
    mark_nrs_lock_switch_success
    maybe_relink_or_restore
    release_rebuild_lock
    restart_hammerspoon
    cleanup_build_artifacts
    echo ""
    log_info "✅ Done! (${SECONDS}s)"
}

main
