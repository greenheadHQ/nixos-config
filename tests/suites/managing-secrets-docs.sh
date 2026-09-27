# shellcheck shell=bash
# SC2154: REPO_ROOT·fail·assert_*는 aggregator가 test-common.sh를 먼저 source한 뒤 이 파일을
#   source해 정의한다(shellcheck는 이 순서를 모른다).
# SC2016: 작은따옴표 안의 백틱은 마크다운 inline code를 그대로 찾는 패턴이다(명령 치환 아님).
# shellcheck disable=SC2154,SC2016
# tests/suites/managing-secrets-docs.sh — managing-secrets 스킬 문서와 secrets/ 선언의 정합성 (#1396)
#
# 시크릿 내용은 읽지 않는다: secrets/*.age는 파일명만, secrets/secrets.nix는 선언 줄만 본다.

# secrets.nix의 `"<name>.age".publicKeys = <식>;` 선언을 "이름<TAB>그룹"으로 낸다. 그룹은 let
# 바인딩 이름(allHosts 등)이거나, `[ constants.sshKeys.<키> ]` 인라인 목록이면 그 키 이름이다.
# 다른 형태의 선언은 해석 실패로 멈춰 이 파서를 함께 고치게 한다(조용히 빠뜨리지 않는다).
_secrets_docs_declared_groups() {
  local rules="$1" line name expr
  local re_decl='^[[:space:]]*"([^"]+\.age)"\.publicKeys[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*;[[:space:]]*$'
  local re_inline='^\[[[:space:]]*constants\.sshKeys\.([A-Za-z0-9_]+)[[:space:]]*\]$'
  local re_group='^[A-Za-z0-9_]+$'
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" == *'.age"'* ]] || continue
    [[ "$line" =~ $re_decl ]] || fail "secrets.nix의 .age 선언 형식을 해석하지 못함: $line"
    name="${BASH_REMATCH[1]}"
    expr="${BASH_REMATCH[2]}"
    if [[ "$expr" =~ $re_inline ]]; then
      printf '%s\t%s\n' "$name" "${BASH_REMATCH[1]}"
    elif [[ "$expr" =~ $re_group ]]; then
      printf '%s\t%s\n' "$name" "$expr"
    else
      fail "secrets.nix의 $name publicKeys 식을 해석하지 못함: $expr"
    fi
  done < "$rules"
}

# SKILL.md 통합 Secret Inventory 표의 `.age` 행을 "이름<TAB>recipient 열의 첫 단어"로 낸다.
_secrets_docs_inventory_groups() {
  local skill="$1" line recipient
  local -a cols
  # 이름은 경로 없는 파일명만 받는다(설정 파일 구조 표의 `secrets/<name>.age` 같은 행 제외).
  local re_row='^\|[[:space:]]*`([A-Za-z0-9._-]+\.age)`[[:space:]]*\|'
  while IFS= read -r line; do
    [[ "$line" =~ $re_row ]] || continue
    IFS='|' read -r -a cols <<< "$line"
    recipient="${cols[${#cols[@]}-1]}"
    recipient="${recipient#"${recipient%%[![:space:]]*}"}"
    recipient="${recipient%%[[:space:](]*}"
    printf '%s\t%s\n' "${BASH_REMATCH[1]}" "$recipient"
  done < "$skill"
}

_secrets_docs_age_files() {
  local f
  for f in "$REPO_ROOT"/secrets/*.age; do
    [[ -e "$f" ]] && printf '%s\n' "${f##*/}"
  done | LC_ALL=C sort
}

# ── 인벤토리 대조: SKILL.md 표의 .age 행 = secrets/*.age 파일 = secrets.nix 선언이고, 각 행의
# recipient 열이 선언 그룹과 같으며, 서두의 개수가 파일 수와 같아야 한다.
test_managing_secrets_inventory_matches_age_files_and_rules() {
  local skill="$REPO_ROOT/.claude/skills/managing-secrets/SKILL.md"
  local rules="$REPO_ROOT/secrets/secrets.nix"
  local files declared documented stated
  files="$(_secrets_docs_age_files)"
  declared="$(_secrets_docs_declared_groups "$rules" | LC_ALL=C sort)"
  documented="$(_secrets_docs_inventory_groups "$skill" | LC_ALL=C sort)"
  [[ -n "$files" ]] || fail "secrets/*.age 파일을 찾지 못함"

  [[ "$(cut -f1 <<< "$declared")" == "$files" ]] \
    || fail "secrets.nix 선언과 secrets/*.age 파일 집합이 다름: $(diff <(cut -f1 <<< "$declared") <(printf '%s\n' "$files") || true)"
  [[ "$(cut -f1 <<< "$documented")" == "$files" ]] \
    || fail "SKILL.md 인벤토리의 .age 행과 secrets/*.age 파일 집합이 다름(< 문서, > 파일): $(diff <(cut -f1 <<< "$documented") <(printf '%s\n' "$files") || true)"
  [[ "$documented" == "$declared" ]] \
    || fail "SKILL.md recipient 열이 secrets.nix 선언 그룹과 다름(< 문서, > 선언): $(diff <(printf '%s\n' "$documented") <(printf '%s\n' "$declared") || true)"

  stated="$(grep -oE 'agenix `\.age` [0-9]+개' "$skill" | grep -oE '[0-9]+' || true)"
  [[ -n "$stated" && "$stated" != *$'\n'* ]] || fail "SKILL.md 서두의 .age 개수 문구를 하나로 찾지 못함: $stated"
  [[ "$stated" -eq "$(wc -l <<< "$files")" ]] \
    || fail "SKILL.md 서두의 .age 개수($stated)가 파일 수($(wc -l <<< "$files" | tr -d ' '))와 다름"
}

# 그룹의 복호화 identity: let 바인딩 본문(첫 `;`까지)에 hostKeys가 있으면 호스트 키, 아니면
# 사용자 키다. 인라인 목록은 _secrets_docs_declared_groups가 sshKeys만 받으므로 사용자 키다.
_secrets_docs_group_identity() {
  local rules="$1" group="$2" binding
  binding="$(awk -v g="$group" '$1 == g && $2 == "=" { on = 1 } on { print } on && /;/ { exit }' "$rules")"
  if [[ "$binding" == *hostKeys.* ]]; then
    printf '%s\n' '/etc/ssh/ssh_host_ed25519_key'
  else
    # shellcheck disable=SC2088  # 문서에 그대로 나오는 리터럴 경로다(확장하지 않음).
    printf '%s\n' '~/.ssh/id_ed25519'
  fi
}

# workflows.md 그룹 표의 행을 "그룹<TAB>identity 열"로 낸다. 첫 열의 인라인 목록
# `[ constants.sshKeys.<키> ]`은 선언 파서와 같게 키 이름으로 바꾼다.
_secrets_docs_workflow_group_rows() {
  local line group
  local -a cols
  local re_row='^\|[[:space:]]*`([^`]+)`'
  local re_inline='^\[[[:space:]]*constants\.sshKeys\.([A-Za-z0-9_]+)[[:space:]]*\]$'
  while IFS= read -r line; do
    [[ "$line" =~ $re_row ]] || continue
    group="${BASH_REMATCH[1]}"
    [[ "$group" =~ $re_inline ]] && group="${BASH_REMATCH[1]}"
    IFS='|' read -r -a cols <<< "$line"
    printf '%s\t%s\n' "$group" "${cols[${#cols[@]}-1]}"
  done
}

# ── 호스트 추가 절차: secrets.nix가 쓰는 recipient 그룹마다 표에 복호화 identity가 맞게 적혀
# 있고, 규칙 파일이 있는 secrets/에서 publicKeys 확인 → identity로 복호화 확인 → 대상별
# 재암호화 순서로 안내해야 한다. 전체 재암호화(-r)는 조건과 함께 설명만 하고, 공통 그룹을 모든
# 항목에 적용하라는 설명은 없어야 한다.
test_managing_secrets_host_add_workflow_checks_recipients_per_target() {
  local wf="$REPO_ROOT/.claude/skills/managing-secrets/references/workflows.md"
  local rules="$REPO_ROOT/secrets/secrets.nix"
  local section rows groups group identity row pub_line dec_line enc_line
  section="$(awk '/^## 호스트 추가/ { on = 1; print; next } on && /^## / { exit } on' "$wf")"
  [[ -n "$section" ]] || fail "workflows.md에 '## 호스트 추가' 절이 없음"

  if grep -qE '^[[:space:]]*(cd secrets && )?nix run github:ryantm/agenix -- -r[[:space:]]*$' <<< "$section"; then
    fail "호스트 추가 절이 조건 없는 전체 재암호화(-r) 명령 줄을 안내함"
  fi
  grep -F -- '-r`' <<< "$section" | grep -qF '때만' \
    || fail "호스트 추가 절에 전체 재암호화(-r)를 쓸 수 있는 조건이 없음"

  rows="$(_secrets_docs_workflow_group_rows <<< "$section")"
  groups="$(_secrets_docs_declared_groups "$rules" | cut -f2 | LC_ALL=C sort -u)"
  [[ -n "$groups" ]] || fail "secrets.nix에서 recipient 그룹을 찾지 못함"
  while IFS= read -r group; do
    identity="$(_secrets_docs_group_identity "$rules" "$group")"
    row="$(awk -F '\t' -v g="$group" '$1 == g { print $2 }' <<< "$rows")"
    [[ -n "$row" ]] || fail "호스트 추가 절의 그룹 표에 선언 그룹 $group 행이 없음"
    [[ "$row" == *"\`$identity\`"* ]] \
      || fail "호스트 추가 절의 그룹 표에서 $group 행의 복호화 identity가 ${identity}가 아님: $row"
  done <<< "$groups"

  assert_contains "$section" "cd secrets"
  # 줄 번호 조회는 못 찾아도 빈 값으로 두고 아래 단정이 이유를 출력하게 한다(pipefail로 조용히 끝나지 않게).
  pub_line="$(grep -nF -m1 '`publicKeys` 확인' <<< "$section" | cut -d: -f1 || true)"
  dec_line="$(grep -nF -m1 -- '-d <name>.age -i <identity>' <<< "$section" | cut -d: -f1 || true)"
  enc_line="$(grep -nF -m1 -- '-e <name>.age -i <identity>' <<< "$section" | cut -d: -f1 || true)"
  [[ -n "$pub_line" && -n "$dec_line" && -n "$enc_line" ]] \
    || fail "호스트 추가 절에 publicKeys 확인·복호화 확인·대상별 재암호화 중 빠진 단계가 있음 (pub=$pub_line dec=$dec_line enc=$enc_line)"
  [[ "$pub_line" -lt "$dec_line" && "$dec_line" -lt "$enc_line" ]] \
    || fail "호스트 추가 절의 순서가 publicKeys 확인 → 복호화 확인 → 재암호화가 아님 (pub=$pub_line dec=$dec_line enc=$enc_line)"

  assert_not_contains "$(cat "$wf")" '`allHosts`에 추가'
  assert_not_contains "$(cat "$wf")" '`allHosts` 목록에 있는 모든 공개키'
}
