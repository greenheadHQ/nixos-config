# shellcheck shell=bash
#───────────────────────────────────────────────────────────────────────────────
# Pre-flight 소스 빌드 체크 (NixOS 전용, nrs.sh/nrp.sh에서 호출)
# nix build --dry-run으로 소스 빌드 대상을 사전 감지하고,
# non-trivial 패키지가 있으면 --force 없이는 abort
# 인수: --warn-only → abort 대신 경고만 출력 (nrp에서 사용)
#───────────────────────────────────────────────────────────────────────────────
preflight_source_build_check() {
    local warn_only=false
    [[ "${1:-}" == "--warn-only" ]] && warn_only=true

    # offline 모드에서는 dry-run 결과가 부정확하므로 스킵
    if [[ -n "$OFFLINE_FLAG" ]]; then
        log_info "🔍 Pre-flight skipped (offline mode)."
        return 0
    fi

    log_info "🔍 Checking for source builds..."

    local dry_run_output
    if ! dry_run_output=$(nix build \
        "${FLAKE_PATH}#nixosConfigurations.$(hostname).config.system.build.toplevel" \
        --dry-run 2>&1); then
        log_warn "⚠️  Pre-flight dry-run failed. Proceeding with build."
        return 0  # fallthrough — pre-flight 실패가 빌드를 차단하면 안 됨
    fi

    # .drv 라인 추출 — dry-run 출력에서 .drv로 끝나는 경로는
    # "will be built" 섹션에만 존재 (fetched 경로는 빌드 출력이므로 .drv 아님)
    # 참고: nix CLI 출력 형식은 unstable이나, .drv 확장자는 Nix 설계상 불변
    local build_drvs
    build_drvs=$(echo "$dry_run_output" | grep '\.drv$' || true)
    [[ -z "$build_drvs" ]] && { log_info "  ✓ All packages cached."; return 0; }

    # known-heavy: 소스 빌드 시 장시간 소요되는 패키지 (Rust 컴파일 등)
    # 각 항목은 패키지명 접두사. 매칭: ^<name>-[0-9]+\.[0-9]+ (semver 시작 필수)
    # 예: "anki" → anki-25.09.2, anki-25.09.2-vendor 매칭 (anki-addon-* 등은 제외)
    # 추가 방법: 배열에 패키지명만 추가 (예: "firefox")
    #
    # === Change Intent Record ===
    # v1 (b9cd235): known-heavy blocklist 구상 → 관리 부담 우려로 known-trivial allowlist 채택
    # v2 (f09a575): activation-script 등 false positive 발생, trivial 패턴 추가로 대응
    # v3 (이번 변경): allowlist 방식이 두더지 잡기(끝없는 패턴 추가)임을 확인,
    #    원래 구상대로 known-heavy blocklist로 회귀. 미등록 패키지는 무시(수동 관리).
    #    trade-off: 새 무거운 패키지 추가 시 수동 등록 필요하나,
    #              false positive를 크게 줄여 사용자 경험이 압도적으로 나음.
    local heavy_packages=(
        mise    # Rust 패키지 → flake update 후 캐시 미스 시 장시간 빌드
    )

    # 빈 배열 guard — heavy_packages가 비면 체크 자체를 비활성화
    if ((${#heavy_packages[@]} == 0)); then
        log_warn "⚠️  heavy_packages is empty; preflight detection disabled."
        return 0
    fi

    # 패키지명 추출 (해시 제거, .drv 제거)
    local pkg_names
    pkg_names=$(printf '%s\n' "$build_drvs" | sed 's|.*/[a-z0-9]\{32\}-||; s|\.drv$||' | sort -u)

    # heavy_packages 매칭 regex 생성: ^anki-[0-9]+\.[0-9]+|^mise-[0-9]+\.[0-9]+
    # semver 시작(X.Y)을 요구하여 anki-addon-*, mise-plugin-* 등 비패키지 제외
    local heavy_regex
    heavy_regex=$(printf '|^%s-[0-9]+\\.[0-9]+' "${heavy_packages[@]}")
    heavy_regex="${heavy_regex:1}"

    local matched_heavy=""
    local grep_rc=0
    matched_heavy=$(printf '%s\n' "$pkg_names" | grep -E -- "$heavy_regex") || grep_rc=$?
    case $grep_rc in
        0) ;;  # matches found
        1) ;;  # no matches (정상)
        *) log_error "  ✗ Invalid heavy regex: $heavy_regex"; return 1 ;;
    esac

    [[ -z "$matched_heavy" ]] && { log_info "  ✓ No known-heavy source builds."; return 0; }

    # 보고할 패키지명은 매칭된 heavy 패키지만
    pkg_names="$matched_heavy"

    # --force 또는 warn-only: 경고만 출력하고 진행
    if [[ "$FORCE_FLAG" == true || "$warn_only" == true ]]; then
        local reason=""
        [[ "$FORCE_FLAG" == true ]] && reason=" (--force로 진행)"
        log_warn "⚠️  소스 빌드 감지${reason}:"
        while IFS= read -r pkg; do echo "  - $pkg"; done <<< "$pkg_names"
        echo ""
        return 0
    fi

    # abort — 호출 스크립트명을 $0에서 추출
    local cmd_name
    cmd_name=$(basename "$0" .sh)

    log_warn "⚠️  다음 패키지가 소스에서 빌드됩니다 (Nix 캐시 없음):"
    while IFS= read -r pkg; do echo "  - $pkg"; done <<< "$pkg_names"
    echo ""
    echo "MiniPC에서 소스 빌드는 과열 및 장시간 소요될 수 있습니다."
    echo "  ${cmd_name} --force            # 경고 무시하고 진행"
    echo "  ${cmd_name} --force --cores 2  # 코어 제한으로 진행 (과열 방지)"
    echo ""
    echo "또는 Hydra 캐시가 준비될 때까지 대기하세요."
    exit 1
}

#───────────────────────────────────────────────────────────────────────────────
# Homebrew cask 충돌 사전 감지 (darwin 전용, nrs.sh에서 호출)
# preview_changes 이후 호출 — ./result/activate에서 새 Brewfile을 파싱하여
# 선언된 cask과 설치된 cask 간 conflicts_with 충돌을 감지.
# 충돌 발견 시 사용자 확인 후 이전 cask 제거, --force 시 프롬프트 없이 자동 해소.
# 감지/파싱 실패 시 fallthrough (빌드를 차단하지 않음)
#───────────────────────────────────────────────────────────────────────────────
preflight_cask_conflict_check() {
    command -v brew &>/dev/null || return 0
    command -v jq &>/dev/null || return 0

    # ./result/activate에서 Brewfile 경로 추출
    [[ -f ./result/activate ]] || return 0
    local brewfile_path
    brewfile_path=$(sed -n "s/.*brew bundle --file='\([^']*\)'.*/\1/p" ./result/activate) || return 0
    if [[ -z "$brewfile_path" || ! -f "$brewfile_path" ]]; then
        log_warn "⚠️  Cask conflict check: Brewfile path extraction failed. Skipping."
        return 0
    fi

    # Brewfile에서 선언된 cask 목록 파싱
    local declared_casks
    declared_casks=$(sed -n 's/^cask "\([^"]*\)".*/\1/p' "$brewfile_path") || return 0
    [[ -n "$declared_casks" ]] || return 0

    # 설치된 cask 목록 조회
    local installed_casks
    installed_casks=$(brew list --cask 2>/dev/null) || {
        log_warn "⚠️  Cask conflict check: brew list failed. Skipping."
        return 0
    }

    # 새로 설치할 cask 식별 (선언됨 - 설치됨)
    local new_casks=()
    while IFS= read -r cask; do
        [[ -z "$cask" ]] && continue
        if ! echo "$installed_casks" | grep -qx "$cask"; then
            new_casks+=("$cask")
        fi
    done <<< "$declared_casks"
    [[ ${#new_casks[@]} -gt 0 ]] || return 0

    # 각 새 cask의 conflicts_with 메타데이터 개별 조회
    # 배치 호출(brew info --cask A B)은 미지 cask 포함 시 전체 실패하므로 개별 호출
    log_info "🔍 Checking cask conflicts (${#new_casks[@]} new cask(s))..."
    local conflicts=()
    for new_cask in "${new_casks[@]}"; do
        local cask_json
        cask_json=$(brew info --json=v2 --cask "$new_cask" 2>/dev/null) || continue
        local conflict_casks
        conflict_casks=$(echo "$cask_json" | \
            jq -r '.casks[0].conflicts_with.cask // empty | .[]' \
            2>/dev/null) || continue
        while IFS= read -r conflict_cask; do
            [[ -z "$conflict_cask" ]] && continue
            if echo "$installed_casks" | grep -qx "$conflict_cask"; then
                conflicts+=("${conflict_cask}:${new_cask}")
            fi
        done <<< "$conflict_casks"
    done
    [[ ${#conflicts[@]} -gt 0 ]] || return 0

    # 충돌 발견 — 사용자에게 안내
    log_warn "🍺 Homebrew cask conflict detected:"
    for conflict in "${conflicts[@]}"; do
        local old_cask="${conflict%%:*}"
        local new_cask="${conflict##*:}"
        echo "  $old_cask (installed) conflicts with $new_cask (declared)"
    done
    echo ""

    # 동일 old_cask이 여러 new_cask과 충돌할 수 있으므로 중복 제거
    local uniq_old_casks=()
    local seen_casks=""
    for conflict in "${conflicts[@]}"; do
        local c="${conflict%%:*}"
        if ! echo "$seen_casks" | grep -qx "$c"; then
            uniq_old_casks+=("$c")
            seen_casks+="$c"$'\n'
        fi
    done

    # 충돌 해소 — uninstall
    local do_uninstall=false
    if [[ "$FORCE_FLAG" == true ]]; then
        do_uninstall=true
    else
        read -p "  Uninstall conflicting cask(s) to resolve? [y/N]: " -r
        [[ $REPLY =~ ^[Yy]$ ]] && do_uninstall=true
    fi

    if [[ "$do_uninstall" == true ]]; then
        for old_cask in "${uniq_old_casks[@]}"; do
            log_info "  Uninstalling $old_cask..."
            if ! brew uninstall --cask "$old_cask"; then
                log_error "❌ Failed to uninstall $old_cask"
                echo "  Resolve manually: brew uninstall --cask $old_cask"
                return 1
            fi
            log_info "  ✓ Uninstalled $old_cask"
            UNINSTALLED_CASKS+="$old_cask "
        done
        echo ""
    else
        log_error "❌ Cask conflict not resolved. Aborting."
        echo "  Resolve manually:"
        for old_cask in "${uniq_old_casks[@]}"; do
            echo "    brew uninstall --cask $old_cask"
        done
        exit 1
    fi
}
