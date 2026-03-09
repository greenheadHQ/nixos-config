#!/usr/bin/env bash
# nfu - Nix Flake Update (원자적 업데이트 워크플로우)
# update → FOD hash fix (빌드 검증 포함) → nrs (switch + cleanup)
# Phase 1 실패 시 git checkout -- . 으로 자동 롤백
set -euo pipefail

FLAKE_PATH="@flakePath@"

# 색상
GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}$1${NC}"; }
log_warn()  { echo -e "${YELLOW}$1${NC}"; }
log_error() { echo -e "${RED}$1${NC}"; }

# ── 롤백 메커니즘 ──
NEED_ROLLBACK=true
rollback() {
  if [[ "$NEED_ROLLBACK" == true ]]; then
    log_warn "⚠️  실패 감지 — 모든 파일 변경을 롤백합니다."
    cd "$FLAKE_PATH"
    git checkout -- .
    log_info "✓ 롤백 완료 (working tree 복원)"
  fi
}

# ── 인수 파싱 ──
UPDATE_ALL=false
NRS_ARGS=()
FOD_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--all)    UPDATE_ALL=true ;;
    --cores)
      [[ -z "${2:-}" || ! "$2" =~ ^[1-9][0-9]*$ ]] && { log_error "--cores: positive integer required"; exit 1; }
      NRS_ARGS+=("--cores" "$2"); shift ;;
    --no-cache-check) FOD_ARGS+=(--no-cache-check) ;;
    -h|--help)
      echo "사용법: nfu [-a|--all] [--cores N] [--no-cache-check]"
      echo "  (기본)           fzf로 업데이트할 input 선택"
      echo "  -a, --all        모든 input 일괄 업데이트"
      echo "  --cores N        nrs에 --cores N 전달 (NixOS 과열 방지)"
      echo "  --no-cache-check 소스 빌드 사전 확인 건너뛰기"
      exit 0 ;;
    *) log_error "Unknown argument: $1"; exit 1 ;;
  esac
  shift
done

# ── 메인 ──
cd "$FLAKE_PATH"

# 1. 깨끗한 working tree 확인
if ! git diff --quiet || ! git diff --cached --quiet; then
  log_error "❌ Working tree에 커밋되지 않은 변경이 있습니다."
  log_error "   먼저 git stash 또는 git commit을 실행하세요."
  exit 1
fi

# 2. 롤백 트랩 설정
trap rollback EXIT

# 3. Input 선택 및 업데이트
if [[ "$UPDATE_ALL" == true ]]; then
  log_info "═══ 모든 input 업데이트 ═══"
  nix flake update
else
  log_info "═══ 업데이트할 input 선택 ═══"
  # flake.lock 파싱 검증 (process substitution 내부 에러 방지)
  if ! jq -e '.nodes.root.inputs' "$FLAKE_PATH/flake.lock" >/dev/null 2>&1; then
    log_error "❌ flake.lock 파싱 실패"
    exit 1
  fi
  selected=()
  while IFS= read -r item; do
    [[ -n "$item" ]] && selected+=("$item")
  done < <(
    jq -r '.nodes.root.inputs | keys[]' "$FLAKE_PATH/flake.lock" \
      | fzf --multi \
            --header="TAB: 선택/해제, Enter: 확정, ESC: 취소" \
            --bind 'tab:toggle+down,shift-tab:toggle+up'
  ) || true
  if [[ ${#selected[@]} -eq 0 ]]; then
    NEED_ROLLBACK=false
    echo "선택된 input이 없습니다."
    exit 0
  fi
  log_info "선택: ${selected[*]}"
  nix flake update "${selected[@]}"
fi

# 4. 변경 확인
if git diff --quiet flake.lock; then
  NEED_ROLLBACK=false
  log_info "✓ 모든 input이 이미 최신입니다."
  exit 0
fi

echo ""
log_info "═══ flake.lock 변경사항 ═══"
git diff flake.lock
echo ""

# 5. FOD hash 자동 수정 (내부적으로 nix build로 빌드 검증 포함)
log_info "═══ FOD hash 검증 ═══"
"$FLAKE_PATH/scripts/fix-fod-hashes.sh" "${FOD_ARGS[@]+${FOD_ARGS[@]}}"
echo ""

# ── Phase 2: 빌드 검증 완료, 롤백 비활성화 ──
NEED_ROLLBACK=false
log_info "═══ 시스템 적용 (nrs) ═══"
# --force 항상 전달: nfu는 명시적 업데이트이므로 preflight heavy package 체크 우회
# (fix-fod-hashes.sh가 이미 빌드 검증 완료)
~/.local/bin/nrs.sh --force "${NRS_ARGS[@]}"

echo ""
log_info "═══ 업데이트 완료 ═══"
log_warn "⚠️  FOD hash는 현재 호스트만 검증됨. 다른 머신에서도 nfu를 실행하세요."
echo "💡 변경사항을 커밋하세요:"
echo "   git add -u && git commit -m 'chore: update flake inputs'"
