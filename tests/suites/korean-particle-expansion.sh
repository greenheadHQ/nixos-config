# tests/suites/korean-particle-expansion.sh — 한글 조사 앞 변수 확장 경계 가드 (sourced)
# shellcheck shell=bash
# SC2154: 공통 변수(REPO_ROOT 등)는 aggregator/test-common이 정의.
# shellcheck disable=SC2154
#
# 배경: writeShellApplication은 본문에 `set -u`를 건다. UTF-8 로케일의 bash는 한글을
# 식별자 문자로 취급하므로 "$var조사" 꼴은 조사까지 변수명으로 파싱돼 unbound variable로
# 죽는다. Mac의 opnix-rotate launchd agent가 이 경로에서 만료 알림을 통째로 잃었다
# (systemd 유닛은 C 로케일이라 같은 코드가 MiniPC에서는 정상 동작해 은폐됐다).
#
# 이 스위트는 실제 Pushover 발송이나 op 호출 없이, nix 문자열에서 셸 본문만 추출해
#   (1) bash -n 구문 검사
#   (2) 조사가 뒤따르는 unbraced 확장이 남아 있지 않은지 (로케일 무관 바이트 검사)
#   (3) UTF-8 로케일 + set -u에서 해당 줄들이 실제로 확장되는지
# 만 검증한다.

_kpe_nix_targets() {
  # "<nix 파일 상대경로>|<확장 성공 시 나와야 하는 문자열>"
  printf '%s\n' \
    "modules/darwin/programs/opnix-rotate.nix|2026-08-29에" \
    "modules/nixos/programs/opnix-rotate.nix|2026-08-29에" \
    "modules/nixos/programs/tailscale.nix|4200가"
}

# nix indented string(`    text = ''` … `    '';`)에서 셸 본문만 뽑아 파일로 쓴다.
# 치환 순서가 중요하다: escape된 셸 확장(''${...})을 sentinel로 먼저 지켜두고, 남은
# ${...}(진짜 nix 보간)를 자리표시자로 바꾼 뒤 sentinel을 셸 확장으로 되돌린다.
_kpe_extract_script() {
  local nix_file="$1" out="$2"

  awk -v start="    text = ''" -v stop="    '';" '
    $0 == start { in_body = 1; next }
    in_body && $0 == stop { in_body = 0; next }
    in_body { print }
  ' "$nix_file" \
    | sed -e "s/''\${/@@KPE_SHELL_EXPANSION@@/g" \
          -e "s/\${[^}]*}/NIXVAL/g" \
          -e "s/@@KPE_SHELL_EXPANSION@@/\${/g" \
    > "$out"

  [ -s "$out" ] || fail "failed to extract shell body from $nix_file"
}

# UTF-8 로케일에서만 재현되는 결함이므로, 검증 전에 "지금 이 셸이 결함을 재현하는가"를
# 먼저 확인한다. 재현되지 않는(C 로케일뿐인) 환경에서는 (3)을 건너뛰어야 거짓 통과를
# 성공으로 오해하지 않는다. 재현되는 첫 로케일 이름을 stdout으로 돌려준다.
_kpe_multibyte_locale() {
  local candidate
  for candidate in "${LC_ALL:-${LANG:-}}" en_US.UTF-8 C.UTF-8; do
    [ -n "$candidate" ] || continue
    # 아래 "$kpe_probe에"는 이 스위트가 금지하는 바로 그 위험 패턴을 일부러 쓴 것이다.
    # 중괄호를 씌우면 프로브가 항상 성공해 (3)이 영구히 조용히 skip된다 — 고치지 말 것.
    if ! LC_ALL="$candidate" bash -c 'set -u; kpe_probe=1; : "$kpe_probe에"' 2>/dev/null; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

test_korean_particle_expansion_is_brace_bounded() {
  local sandbox locale nix_rel expected script
  sandbox=$(new_sandbox)

  if locale=$(_kpe_multibyte_locale); then
    :
  else
    locale=""
    echo "SKIP(partial): 이 환경의 bash가 한글 식별자 결함을 재현하지 않음 — 실행 검증 생략" >&2
  fi

  while IFS='|' read -r nix_rel expected; do
    [ -n "$nix_rel" ] || continue
    script="$sandbox/$(printf '%s' "$nix_rel" | tr '/' '_').sh"
    _kpe_extract_script "$REPO_ROOT/$nix_rel" "$script"

    # (1) 추출 본문 구문 검사.
    bash -n "$script" || fail "extracted body of $nix_rel is not valid bash"

    # (2) unbraced 확장 뒤에 곧바로 멀티바이트 문자가 오는 자리가 없어야 한다.
    #     C 로케일에서 UTF-8 선두 바이트는 [:print:] 밖이므로 로케일과 무관하게 검출된다.
    local unbraced
    unbraced=$(LC_ALL=C grep -nE '\$[A-Za-z_][A-Za-z0-9_]*[^[:print:]]' "$script" || true)
    if [ -n "$unbraced" ]; then
      # 회귀를 되돌릴 사람이 어느 줄인지 바로 알 수 있게 매칭 줄을 함께 싣는다.
      fail "$nix_rel has an unbraced expansion followed by a multibyte char (set -u hazard):
$unbraced"
    fi

    [ -n "$locale" ] || continue

    # (3) 조사가 뒤따르는 braced 확장이 있는 줄만 골라 set -u에서 실제로 평가한다.
    #     발송·파일 IO가 없는 대입/echo 줄만 해당하므로 부작용이 없다.
    local hazard_lines line output snippet found=0
    hazard_lines=$(LC_ALL=C grep -E '\$\{[A-Za-z_][A-Za-z0-9_]*\}[^[:print:]]' "$script" || true)
    [ -n "$hazard_lines" ] || fail "$nix_rel has no particle-bound expansion left to verify"

    while IFS= read -r line; do
      [ -n "$line" ] || continue
      case "$line" in
        *'='*|*echo*) ;;
        *) fail "$nix_rel: selected line is neither an assignment nor an echo: $line" ;;
      esac
      snippet="set -u
expiry_date=2026-08-29
days_left=-7
port=4200
steps=STEPS
rotate_steps=STEPS
$line
printf '%s\n' \"\${msg-}\" \"\${message-}\""
      if ! output=$(LC_ALL="$locale" bash -c "$snippet" 2>&1); then
        fail "$nix_rel: particle-bound line failed under set -u: $line"
      fi
      case "$output" in
        *"$expected"*) found=1 ;;
      esac
    done <<< "$hazard_lines"

    [ "$found" = 1 ] || fail "$nix_rel: expected expanded output to contain '$expected'"
  done <<< "$(_kpe_nix_targets)"
}
