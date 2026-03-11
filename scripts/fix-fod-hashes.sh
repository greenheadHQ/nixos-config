#!/usr/bin/env bash
# scripts/fix-fod-hashes.sh
# Fixed-Output Derivation (FOD) hash mismatch 자동 감지 및 수정
#
# nixpkgs 등 input 업데이트 후 FOD hash가 깨지면
# 빌드 에러에서 올바른 hash를 추출해 .nix 파일을 자동 교체한다.
#
# ── 제한사항 ──
# 이 스크립트는 현재 실행 머신의 config만 빌드하여 검증한다.
#   - Mac에서 실행  → darwinConfigurations만 검증 (NixOS FOD 감지 불가)
#   - MiniPC에서 실행 → nixosConfigurations만 검증 (macOS FOD 감지 불가)
# 따라서 "예방"이 아니라 "빌드 실패 시 수동 hash 교체를 자동화"하는 도구다.
# 전체 플랫폼을 커버하려면 각 머신에서 개별 실행해야 한다.
#
# 사용법:
#   ./scripts/fix-fod-hashes.sh          # 독립 실행
#   nfu가 자동 호출하거나, nix flake update 후 수동 실행
set -euo pipefail

NO_CACHE_CHECK=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-cache-check) NO_CACHE_CHECK=true ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
  shift
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# 현재 시스템의 flake output attribute 결정
# nrs(nixos-rebuild/darwin-rebuild wrapper)와 동일한 hostname = flake attr 키 규칙 사용.
# nrs가 정상 동작하는 환경이면 이 스크립트도 동일하게 동작한다.
if [[ "$(uname)" == "Darwin" ]]; then
  HOST=$(scutil --get LocalHostName)
  ATTR="darwinConfigurations.\"${HOST}\".config.system.build.toplevel"
else
  HOST=$(hostname -s)
  ATTR="nixosConfigurations.\"${HOST}\".config.system.build.toplevel"
fi

cache_precheck() {
  if [[ "$NO_CACHE_CHECK" == true ]]; then
    return 0
  fi

  echo "캐시 상태 확인 중..."
  local dry_output
  if ! dry_output=$(nix build ".#${ATTR}" --dry-run 2>&1); then
    echo "⚠️  dry-run 실패 — 캐시 확인을 건너뜁니다."
    return 0
  fi

  # .drv 경로 추출 (rebuild-common.sh preflight_source_build_check()와 동일 패턴)
  local build_drvs
  build_drvs=$(echo "$dry_output" | grep '\.drv$' || true)

  if [[ -z "$build_drvs" ]]; then
    echo "✓ 모든 패키지가 캐시에 있습니다."
    return 0
  fi

  # 패키지명 추출 (rebuild-common.sh preflight_source_build_check()와 동일 패턴)
  local pkg_names pkg_count
  pkg_names=$(printf '%s\n' "$build_drvs" | sed 's|.*/[a-z0-9]\{32\}-||; s|\.drv$||' | sort -u)
  pkg_count=$(printf '%s\n' "$pkg_names" | wc -l | tr -d ' ')

  # === Change Intent Record ===
  # Heavy 빌드 패키지 판별 — Multi-Signal Scoring
  #
  # v1 (95b4261): inputDrvs에 cargo/rustc/cmake/meson/go 존재 여부만 확인
  #   → false positive: fd, stylua, delta 등 소형 Rust 패키지가 heavy로 표시됨
  #     (Mac에서 <1분, MiniPC에서도 <5분에 빌드 완료)
  #
  # v2 (이번 변경): Multi-Signal Scoring — inputDrvs의 비인프라 라이브러리 수 +
  #   heavy framework(Qt/WebKit/Electron/LLVM) + 다중 언어 빌드 감지.
  #   2-tier 경고: HEAVY(빨강 ⚠️, score≥3) / MODERATE(노랑 🔶, Rust/C++ 빌드이나 소규모)
  #   20/20 검증 정확도 (Mac arm64 + MiniPC x86_64 실측). ~0.17s 오버헤드 (66 drvs 기준).
  #
  # trade-off: jq 스코어링 로직이 복잡해졌지만, false positive 제거 +
  #            severity 구분으로 사용자 판단력 향상이 더 가치 있음.
  #            nix show-derivation 1회 배치 호출이므로 성능 영향 미미.

  local drv_paths
  drv_paths=$(printf '%s\n' "$build_drvs" | sed 's/^[[:space:]]*//')

  # heavy_pkgs: "패키지명<TAB>HEAVY|MODERATE" 형식 (탭 구분)
  local heavy_pkgs=""
  # shellcheck disable=SC2086
  heavy_pkgs=$(nix show-derivation $drv_paths 2>/dev/null | jq -r '
    # Glue derivation 제외 (빌드 시간 무의미한 시스템 조립용 drv)
    def is_glue:
      test("^(activation-|activate$|home-manager-|darwin-system-|nixos-system-|etc-|etc$|set-environment|unit-script-|unit-|system-path|system-units|user-units|system-generators|user-generators|system-shutdown|shutdown-ramfs)");

    # 인프라 drv 필터링 (빌드 도구/wrapper/stdenv — 라이브러리 의존이 아님)
    def is_infra:
      test("^(hook-|.*-hook-|wrapper-|stdenv-|bash-|source-|vendor-|.*-setup-hook|patch-)");

    to_entries[] |
    (.key | sub("/nix/store/[a-z0-9]{32}-"; "") | sub("\\.drv$"; "")) as $pkg |
    select(($pkg | is_glue) | not) |

    # inputDrvs에서 dep 이름 추출
    (.value.inputDrvs | keys | map(
      capture("/nix/store/[a-z0-9]{32}-(?<name>.+)\\.drv").name // empty
    ) | map(select(. != ""))) as $all_deps |

    # 인프라 제외한 라이브러리 의존 수
    ($all_deps | map(select(is_infra | not)) | length) as $lib_count |

    # 빌드 도구 감지
    ($all_deps | map(select(test("^(auditable-cargo|cargo|rustc-wrapper)-[0-9]"))) | length > 0) as $has_rust |
    ($all_deps | map(select(test("^(cmake)-[0-9]"))) | length > 0) as $has_cmake |
    ($all_deps | map(select(test("^(meson)-[0-9]"))) | length > 0) as $has_meson |
    ($all_deps | map(select(test("^(python3|python3-minimal)-[0-9]"))) | length > 0) as $has_python |
    ($all_deps | map(select(test("^(go)-[0-9]"))) | length > 0) as $has_go |
    ($all_deps | map(select(test("^(nodejs|node)-[0-9]"))) | length > 0) as $has_node |

    # Heavy framework 감지 (단독으로 빌드 시간 지배적)
    ($all_deps | map(select(test("qtwebengine|webkit|electron|chromium"))) | length > 0) as $has_heavy_fw |
    ($all_deps | map(select(test("^(llvm|clang)-[0-9]"))) | length > 0) as $has_llvm |

    # 스코어링
    (0
      + (if $has_heavy_fw then 3 else 0 end)
      + (if $has_llvm then 3 else 0 end)
      + (if $lib_count >= 15 then 3 elif $lib_count >= 10 then 1 else 0 end)
      + (if ([$has_rust, $has_python, $has_node, $has_go] | map(select(.)) | length) >= 2 then 2 else 0 end)
      + (if ($has_cmake or $has_meson) and $lib_count >= 10 then 2 else 0 end)
    ) as $score |

    # 분류: HEAVY(score≥3), MODERATE(컴파일 언어 빌드 도구 있으나 소규모), 나머지 무시
    # Python/Node는 MODERATE 조건에서 의도적으로 제외:
    #   MODERATE는 "컴파일 언어 소규모 빌드"를 의미 — Python(setuptools)/Node(npm)은
    #   파일 복사 중심이라 단독으로는 빌드 시간 무시 가능.
    #   python3/nodejs-slim 자체 빌드는 무겁지만(MiniPC: 15분/2분), 이들은 lib_count≥15라
    #   score≥3 → HEAVY 경로를 타므로 MODERATE 조건과 무관.
    #   C extension Python 패키지는 cmake/meson 동반 → 이미 조건에 포함됨.
    #   Python/Node는 multi-lang scoring signal(+2)로만 활용.
    if $score >= 3 then "\($pkg)\tHEAVY"
    elif ($has_rust or $has_cmake or $has_meson or $has_go) and $score > 0 then "\($pkg)\tMODERATE"
    else empty
    end
  ' 2>/dev/null || true)

  echo ""
  echo "⚠️  ${pkg_count}개 패키지가 소스에서 빌드됩니다 (캐시 없음):"
  printf '%s\n' "$pkg_names" | while IFS= read -r pkg; do
    local tier=""
    if [[ -n "$heavy_pkgs" ]]; then
      tier=$(printf '%s\n' "$heavy_pkgs" | awk -F'\t' -v p="$pkg" '$1 == p { print $2; exit }')
    fi
    case "$tier" in
      HEAVY)    echo -e "  - \033[0;31m${pkg} ⚠️\033[0m" ;;
      MODERATE) echo -e "  - \033[0;33m${pkg} 🔶\033[0m" ;;
      *)        echo "  - $pkg" ;;
    esac
  done
  echo ""

  if [[ ! -t 0 ]]; then
    echo "(비대화형 환경 — 자동 진행)"
    return 0
  fi

  read -rp "계속하시겠습니까? [y/N] " answer
  case "$answer" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *)
      echo "빌드를 취소합니다. (flake.lock 변경은 롤백됩니다)"
      exit 1
      ;;
  esac
}

MAX_ROUNDS=3
fixed=0
modified_files=()

echo "═══ FOD Hash 검증 ═══"
echo "대상: ${HOST}"

for (( round=1; round<=MAX_ROUNDS+1; round++ )); do
  echo ""
  if (( round <= MAX_ROUNDS )); then
    echo "빌드 검증 중... (${round}/${MAX_ROUNDS})"
    if (( round == 1 )); then
      cache_precheck
    fi
  else
    echo "최종 검증 빌드..."
  fi

  build_log=$(mktemp)
  set +e
  nix build ".#${ATTR}" --no-link 2>&1 | tee "$build_log"
  build_rc=${PIPESTATUS[0]}
  set -e
  build_output=$(cat "$build_log")
  rm -f "$build_log"

  # 사용자 중단 감지: SIGINT(130), SIGPIPE(141), SIGTERM(143)
  # SIGPIPE: tee가 먼저 SIGINT로 죽으면 nix build가 broken pipe로 141 받을 수 있음
  if (( build_rc == 130 || build_rc == 141 || build_rc == 143 )); then
    echo ""
    echo "⚠️  사용자가 빌드를 취소했습니다."
    exit 130
  fi

  if (( build_rc == 0 )); then
    break
  fi

  # 최대 수정 횟수 도달 — 더 이상 수정 없이 실패
  if (( round > MAX_ROUNDS )); then
    echo "❌ ${MAX_ROUNDS}회 수정 후에도 빌드 실패:"
    echo "$build_output" | tail -20
    exit 1
  fi

  # hash mismatch 블록 단위 파싱:
  #   "hash mismatch in fixed-output derivation" → specified → got 순서로 1쌍씩 추출
  #   SRI(sha256-xxx) 및 legacy(sha256:xxx) 양쪽 포맷 대응
  # Bash 3.2 호환을 위해 mapfile 대신 while-read 사용
  pairs=()
  while IFS= read -r pair; do
    [[ -n "$pair" ]] && pairs+=("$pair")
  done < <(awk '
    /hash mismatch in fixed-output derivation/ { in_block=1; old=""; next }
    in_block && /specified:/ {
      if (match($0, /sha[0-9]+[-:][A-Za-z0-9+\/=_-]+/)) old=substr($0, RSTART, RLENGTH)
      next
    }
    in_block && /got:/ {
      if (old != "" && match($0, /sha[0-9]+[-:][A-Za-z0-9+\/=_-]+/))
        print old, substr($0, RSTART, RLENGTH)
      in_block=0
    }
  ' <<< "$build_output" | sort -u)

  if (( ${#pairs[@]} == 0 )); then
    echo "❌ hash mismatch가 아닌 빌드 에러 (attr: ${ATTR}):"
    echo "$build_output" | tail -20
    exit 1
  fi

  # Phase 1: 모든 pair의 타깃 파일 검증 (치환 전 실패 시 워킹트리 오염 방지)
  # 평행 배열로 보관하여 파일 경로의 공백에도 안전
  r_olds=()
  r_news=()
  r_files=()
  # 동일 old hash에 서로 다른 new hash가 매핑되면 충돌 — 수동 확인 필요
  seen_olds=()
  for pair in "${pairs[@]}"; do
    old="${pair%% *}"
    new="${pair##* }"
    for seen in "${seen_olds[@]+"${seen_olds[@]}"}"; do
      if [[ "${seen%% *}" == "$old" && "${seen##* }" != "$new" ]]; then
        echo "❌ 동일 hash에 서로 다른 대체값이 매핑됨 — 수동 확인 필요: $old"
        exit 1
      fi
    done
    seen_olds+=("$old $new")

    # git grep: tracked + untracked 파일 대상 (gitignored 제외)
    # exit code: 0=매치, 1=미매치, 2+=실행 오류
    # 주의: process substitution은 exit code를 전파하지 않으므로 변수 캡처 사용
    grep_output=""
    grep_exit=0
    grep_output=$(git grep --untracked --exclude-standard -Fl -- "$old" -- '*.nix' 2>&1) || grep_exit=$?
    if (( grep_exit > 1 )); then
      echo "❌ git grep 실행 오류:"
      echo "$grep_output"
      exit 1
    fi
    matches=()
    while IFS= read -r f; do
      [[ -n "$f" ]] && matches+=("$f")
    done <<< "$grep_output"
    # grep exit 1 (미매치) 시 빈 줄이 들어올 수 있으므로 빈 요소 제거
    if [[ ${#matches[@]} -eq 1 && -z "${matches[0]}" ]]; then
      matches=()
    fi
    match_count=${#matches[@]}

    if (( match_count == 0 )); then
      echo "❌ hash를 포함하는 .nix 파일을 찾을 수 없음: $old"
      exit 1
    fi
    if (( match_count > 1 )); then
      # 안전장치: 동일 hash가 여러 파일에 있으면 의도치 않은 치환 방지를 위해 중단.
      # FOD hash는 derivation별로 고유하므로 multi-match는 비정상 상태를 의미함.
      echo "❌ hash가 ${match_count}개 파일에서 발견됨 — 수동 확인 필요: $old"
      printf '  %s\n' "${matches[@]}"
      exit 1
    fi

    r_olds+=("$old")
    r_news+=("$new")
    r_files+=("${matches[0]}")
  done

  # Phase 2: 검증 통과 후 일괄 치환
  for (( i=0; i<${#r_olds[@]}; i++ )); do
    old="${r_olds[$i]}"
    new="${r_news[$i]}"
    file="${r_files[$i]}"

    echo "  수정: ${file#./}"
    echo "    ${old} → ${new}"
    # Nix SRI hash는 [A-Za-z0-9+/=-]만 포함하여 sed 구분자 '|'와 충돌 없음.
    # macOS BSD sed 호환을 위해 tmpfile 패턴 사용. g 플래그로 파일 내 모든 매치 교체.
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' EXIT
    # sed와 mv를 분리하여 set -e가 각각에 적용되도록 함
    # (AND-list에서는 좌변 실패가 errexit을 트리거하지 않음)
    sed "s|${old}|${new}|g" "$file" > "$tmp"
    mv "$tmp" "$file"
    fixed=$((fixed + 1))
    modified_files+=("$file")
  done
done

echo ""
if (( fixed > 0 )); then
  echo "✓ ${fixed}개 FOD hash 자동 수정 완료"
  echo ""
  echo "변경 파일:"
  printf '  %s\n' "${modified_files[@]}"
else
  echo "✓ FOD hash mismatch 없음"
fi
