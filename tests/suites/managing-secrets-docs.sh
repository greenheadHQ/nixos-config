# shellcheck shell=bash
# SC2154: REPO_ROOT·fail·assert_*는 aggregator가 test-common.sh를 먼저 source한 뒤 이 파일을
#   source해 정의한다(shellcheck는 이 순서를 모른다).
# SC2016: 작은따옴표 안의 백틱은 마크다운 inline code를 그대로 찾는 패턴이다(명령 치환 아님).
# shellcheck disable=SC2154,SC2016
# tests/suites/managing-secrets-docs.sh — managing-secrets 스킬 문서와 secrets/ 선언의 정합성 (#1396)
#
# 시크릿 내용은 읽지 않는다: secrets/*.age는 파일명만, secrets/secrets.nix는 선언 줄만 본다.

# publicKeys 식을 그룹 표기로 바꾼다. 문서(SKILL.md recipient 열의 첫 단어, workflows.md 그룹 표의
# 첫 열)도 이 표기를 쓴다.
#   - let 바인딩 이름(allHosts 등): 그 이름
#   - 인라인 목록 `[ constants.sshKeys.<k> … constants.hostKeys.<h> … ]`: 원소를 `+`로 잇는다. sshKeys
#     원소는 키 이름만(`[ constants.sshKeys.macbook ]` → macbook), hostKeys 원소는 `hostKeys.<h>`로 쓴다.
# 그 밖의 식(`++` 결합, 문자열 리터럴, 빈 목록 등)은 해석 실패로 멈춰 이 파서를 함께 고치게 한다.
_secrets_docs_group_label() {
  local expr="$1" elem part label=""
  local -a elems
  local re_group='^[A-Za-z0-9_]+$'
  local re_list='^\[[[:space:]]*(.*[^[:space:]])[[:space:]]*\]$'
  local re_elem='^constants\.(sshKeys|hostKeys)\.([A-Za-z0-9_]+)$'
  if [[ "$expr" =~ $re_group ]]; then
    printf '%s\n' "$expr"
    return 0
  fi
  [[ "$expr" =~ $re_list ]] || fail "publicKeys 식을 해석하지 못함: $expr"
  read -r -a elems <<< "${BASH_REMATCH[1]}"
  for elem in "${elems[@]}"; do
    [[ "$elem" =~ $re_elem ]] || fail "인라인 publicKeys 원소를 해석하지 못함: $elem"
    if [[ "${BASH_REMATCH[1]}" == sshKeys ]]; then
      part="${BASH_REMATCH[2]}"
    else
      part="hostKeys.${BASH_REMATCH[2]}"
    fi
    label="${label:+$label+}$part"
  done
  printf '%s\n' "$label"
}

# secrets.nix의 `"<name>.age".publicKeys = <식>;` 선언을 "이름<TAB>그룹 표기"로 낸다. 해석할 수 없는
# 선언은 조용히 빠뜨리지 않고 실패한다.
_secrets_docs_declared_groups() {
  local rules="$1" line name label
  local re_decl='^[[:space:]]*"([^"]+\.age)"\.publicKeys[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*;[[:space:]]*$'
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" == *'.age"'* ]] || continue
    [[ "$line" =~ $re_decl ]] || fail "secrets.nix의 .age 선언 형식을 해석하지 못함: $line"
    name="${BASH_REMATCH[1]}"
    # 명령 치환 안에서는 errexit가 꺼지므로 실패를 명시적으로 잇는다.
    label="$(_secrets_docs_group_label "${BASH_REMATCH[2]}")" \
      || fail "secrets.nix의 $name publicKeys를 해석하지 못함"
    printf '%s\t%s\n' "$name" "$label"
  done < "$rules"
}

# 그룹 표기가 가리키는 키 참조를 "sshKeys.<k>"/"hostKeys.<h>" 한 줄씩 낸다. let 바인딩이 있으면 그
# 본문(첫 `;`까지)에서 찾고, 없으면 인라인 표기를 되돌린다. 본문 각 줄의 `#` 이후(Nix 주석)는 먼저
# 지운다 — 주석 속 키 참조를 세거나 주석 속 `;`에서 본문이 끝나지 않게 한다. 키를 하나도 찾지 못하면 실패한다.
_secrets_docs_group_keys() {
  local rules="$1" group="$2" binding part
  local -a parts refs=()
  binding="$(awk -v g="$group" '{ sub(/#.*/, "") } $1 == g && $2 == "=" { on = 1 } on { print } on && /;/ { exit }' "$rules")"
  if [[ -n "$binding" ]]; then
    while IFS= read -r part; do
      [[ -n "$part" ]] && refs+=("$part")
    done < <(grep -oE '(sshKeys|hostKeys)\.[A-Za-z0-9_]+' <<< "$binding" || true)
  else
    IFS='+' read -r -a parts <<< "$group"
    for part in "${parts[@]}"; do
      if [[ "$part" == hostKeys.* ]]; then
        refs+=("$part")
      else
        refs+=("sshKeys.$part")
      fi
    done
  fi
  [[ "${#refs[@]}" -gt 0 ]] || fail "그룹 ${group}의 키 참조를 찾지 못함"
  printf '%s\n' "${refs[@]}"
}

# constants.nix 키 이름의 호스트 표기. 새 호스트 키를 추가하면 이 표와 workflows.md 그룹 표를 함께 갱신한다.
_secrets_docs_host_label() {
  case "$1" in
    macbook) printf 'Mac\n' ;;
    minipc) printf 'MiniPC\n' ;;
    *) fail "키 이름 ${1}의 호스트 표기를 모름 — _secrets_docs_host_label을 갱신한다" ;;
  esac
}

_secrets_docs_known_hosts() {
  printf '%s\n' Mac MiniPC
}

# 표준입력에서 전체 재암호화(agenix의 -r/--rekey) 명령이 나오는 줄을 낸다. identity 같은 인자가 붙거나
# 순서가 바뀐 변형(`-- -r -i <키>`, `-- -i <키> -r`)과 목록·문장 안의 inline code도 잡는다.
# tests/suites/add-host.sh도 이 헬퍼로 마법사 출력을 검사한다.
_secrets_docs_rekey_all_lines() {
  grep -nE 'agenix --([[:space:]]+[^[:space:]`]+)*[[:space:]]+(-r|--rekey)([[:space:]`]|$)' || true
}

# 전체 재암호화 명령은 사용 조건("…때만") 문장 한 곳에만 둘 수 있다. 입력은 표준입력으로 받는다.
_secrets_docs_assert_rekey_all_conditional() {
  local where="$1" lines count
  lines="$(_secrets_docs_rekey_all_lines)"
  [[ -n "$lines" ]] || return 0
  count="$(wc -l <<< "$lines" | tr -d ' ')"
  [[ "$count" -le 1 ]] \
    || fail "$where: 전체 재암호화(-r) 명령이 ${count}곳에 있음 — 조건 문장 한 곳만 허용한다: $lines"
  [[ "$lines" == *때만* ]] || fail "$where: 전체 재암호화(-r) 명령을 조건 없이 안내함: $lines"
}

# 재암호화 안내의 확인 명령 검사(add-host.sh 출력과 workflows.md 호스트 추가 절이 함께 쓴다). 입력은 표준입력.
#   - 재암호화 전 바이트 수 기록과 재암호화 뒤 비교: 사용자 키·호스트 키(sudo) 명령이 재암호화 명령의
#     앞뒤에 모두 있어야 한다. 빈 값 placeholder는 정상 재암호화 뒤에도 0바이트라, "0이면 되돌린다"는
#     안내는 새 recipient가 빠진 옛 암호문으로 되돌리게 한다 — 전후가 같은지로만 판정한다.
#   - 복호화 확인도 호스트 키 sudo 변형을 함께 낸다. 사용자 키 명령은 권한 상승 없이 둔다.
_secrets_docs_assert_value_check_steps() {
  local where="$1" text enc_line bytes_cmd compare_line first last
  local user_bytes_cmd='nix run github:ryantm/agenix -- -d <name>.age -i <identity> | wc -c'
  local host_bytes_cmd='sudo nix run github:ryantm/agenix -- -d <name>.age -i /etc/ssh/ssh_host_ed25519_key | wc -c'
  local host_dec_cmd='test -f <name>.age && sudo nix run github:ryantm/agenix -- -d <name>.age -i /etc/ssh/ssh_host_ed25519_key >/dev/null'
  text="$(cat)"
  enc_line="$(grep -nF -m1 -- '-e <name>.age -i <identity>' <<< "$text" | cut -d: -f1 || true)"
  [[ -n "$enc_line" ]] || fail "$where: 대상별 재암호화 명령이 없음"

  grep -qF -- "$host_dec_cmd" <<< "$text" || fail "$where: 복호화 확인에 호스트 키 sudo 변형이 없음"
  for bytes_cmd in "$user_bytes_cmd" "$host_bytes_cmd"; do
    first="$(grep -nF -m1 -- "$bytes_cmd" <<< "$text" | cut -d: -f1 || true)"
    last="$(grep -nF -- "$bytes_cmd" <<< "$text" | cut -d: -f1 | tail -1 || true)"
    [[ -n "$first" && "$first" -lt "$enc_line" ]] || fail "$where: 재암호화 전 바이트 수 기록 명령이 없음: $bytes_cmd"
    [[ -n "$last" && "$last" -gt "$enc_line" ]] || fail "$where: 재암호화 뒤 바이트 수 비교 명령이 없음: $bytes_cmd"
  done
  compare_line="$(sed -n "$enc_line,\$p" <<< "$text" | grep -F '재암호화 전과 같은지' || true)"
  [[ "$compare_line" == *'git restore <name>.age'* ]] \
    || fail "$where: 재암호화 뒤 바이트 수가 재암호화 전과 같은지 보고 다르면 되돌리는 안내가 없음"
  ! grep -F '0이면' <<< "$text" | grep -qF 'git restore' \
    || fail "$where: 바이트 수 0을 되돌림 기준으로 안내함 — 빈 값 placeholder가 옛 암호문으로 되돌려진다"
  ! grep -F -- '-i <identity>' <<< "$text" | grep -qF 'sudo' \
    || fail "$where: 사용자 키(-i <identity>) 명령에 sudo가 붙음"
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

# workflows.md 그룹 표의 행을 "그룹 표기<TAB>identity 열"로 낸다. 첫 열은 선언과 같은 규칙으로 표기한다.
_secrets_docs_workflow_group_rows() {
  local line label
  local -a cols
  local re_row='^\|[[:space:]]*`([^`]+)`'
  while IFS= read -r line; do
    [[ "$line" =~ $re_row ]] || continue
    label="$(_secrets_docs_group_label "${BASH_REMATCH[1]}")" \
      || fail "workflows.md 그룹 표의 첫 열을 해석하지 못함: $line"
    IFS='|' read -r -a cols <<< "$line"
    printf '%s\t%s\n' "$label" "${cols[${#cols[@]}-1]}"
  done
}

# 그룹 표 한 행의 identity 열이 그 그룹의 키 종류(사용자 키·호스트 키)와 호스트를 모두, 그리고 그것만
# 짚는지 본다. 예: minipcOnly 행에 Mac이 나오거나 사용자 키 그룹 행에 호스트 키 경로가 나오면 실패한다.
_secrets_docs_assert_group_row() {
  local rules="$1" group="$2" row="$3" keys ref host has_user=0 has_host=0 hosts=" "
  keys="$(_secrets_docs_group_keys "$rules" "$group")" || fail "그룹 ${group}의 키를 해석하지 못함"
  while IFS= read -r ref; do
    case "$ref" in
      sshKeys.*) has_user=1 ;;
      hostKeys.*) has_host=1 ;;
    esac
    host="$(_secrets_docs_host_label "${ref#*.}")" || fail "그룹 ${group}의 호스트 표기를 정하지 못함"
    hosts+="$host "
  done <<< "$keys"

  # shellcheck disable=SC2088  # 문서에 그대로 나오는 리터럴 경로다(확장하지 않음).
  if (( has_user )); then
    [[ "$row" == *'`~/.ssh/id_ed25519`'* ]] || fail "그룹 표 $group 행에 사용자 키 identity가 없음: $row"
  else
    [[ "$row" != *'~/.ssh/id_ed25519'* ]] || fail "그룹 표 $group 행에 그룹에 없는 사용자 키 identity가 있음: $row"
  fi
  if (( has_host )); then
    [[ "$row" == *'`/etc/ssh/ssh_host_ed25519_key`'* ]] || fail "그룹 표 $group 행에 호스트 키 identity가 없음: $row"
  else
    [[ "$row" != *'ssh_host_ed25519_key'* ]] || fail "그룹 표 $group 행에 그룹에 없는 호스트 키 identity가 있음: $row"
  fi
  while IFS= read -r host; do
    if [[ "$hosts" == *" $host "* ]]; then
      [[ "$row" == *"$host"* ]] || fail "그룹 표 $group 행에 호스트 ${host}가 없음: $row"
    else
      [[ "$row" != *"$host"* ]] || fail "그룹 표 $group 행에 그룹에 없는 호스트 ${host}가 있음: $row"
    fi
  done < <(_secrets_docs_known_hosts)
}

# ── 선언 파서: 문서가 권하는 인라인 목록(여러 키, 호스트 키)을 그룹 표기와 키 참조로 해석하고,
# 해석할 수 없는 식에서는 크게 실패해야 한다. 합성 규칙 파일만 쓴다.
test_managing_secrets_group_parser_accepts_inline_key_lists() {
  local sandbox rules expected out bad
  sandbox="$(new_sandbox)"
  rules="$sandbox/secrets.nix"
  cat > "$rules" <<'EOF'
let
  users = [
    constants.sshKeys.macbook
    # constants.sshKeys.retired; 주석 속 참조와 `;`는 무시한다
    constants.sshKeys.minipc # constants.hostKeys.retired
  ];
in
{
  "a.age".publicKeys = users;
  "b.age".publicKeys = [ constants.sshKeys.macbook ];
  "c.age".publicKeys = [ constants.sshKeys.macbook constants.sshKeys.minipc ];
  "d.age".publicKeys = [ constants.hostKeys.minipc ];
  "e.age".publicKeys = [ constants.sshKeys.minipc constants.hostKeys.minipc ];
}
EOF
  expected="$(printf '%s\t%s\n' a.age users b.age macbook c.age macbook+minipc d.age hostKeys.minipc e.age minipc+hostKeys.minipc)"
  out="$(_secrets_docs_declared_groups "$rules")"
  [[ "$out" == "$expected" ]] || fail "선언 그룹 표기가 기대와 다름: $(diff <(printf '%s\n' "$expected") <(printf '%s\n' "$out") || true)"

  [[ "$(_secrets_docs_group_keys "$rules" users)" == $'sshKeys.macbook\nsshKeys.minipc' ]] \
    || fail "let 바인딩 users의 키 참조가 기대와 다름(주석 속 참조 제외): $(_secrets_docs_group_keys "$rules" users | tr '\n' ' ')"
  [[ "$(_secrets_docs_group_keys "$rules" macbook+minipc)" == $'sshKeys.macbook\nsshKeys.minipc' ]] \
    || fail "여러 키 인라인 목록의 키 참조가 기대와 다름"
  [[ "$(_secrets_docs_group_keys "$rules" minipc+hostKeys.minipc)" == $'sshKeys.minipc\nhostKeys.minipc' ]] \
    || fail "사용자 키·호스트 키 혼합 인라인 목록의 키 참조가 기대와 다름"

  for bad in 'users ++ [ constants.hostKeys.minipc ]' '[ "ssh-ed25519 AAAAsynthetic" ]' '[ ]'; do
    printf '{\n  "x.age".publicKeys = %s;\n}\n' "$bad" > "$sandbox/bad.nix"
    if out="$(_secrets_docs_declared_groups "$sandbox/bad.nix" 2>&1)"; then
      fail "해석할 수 없는 publicKeys 식을 통과시킴: $bad"
    fi
    assert_contains "$out" "해석하지 못함"
  done
}

# ── 호스트 추가 절차: secrets.nix가 쓰는 recipient 그룹마다 표에 복호화 identity와 호스트가 맞게 적혀
# 있고, 규칙 파일이 있는 secrets/에서 publicKeys 확인 → identity로 복호화 확인(test -f 선행) →
# 대상별 재암호화(root는 sudo 뒤에 EDITOR=:) → 빈 값 확인 순서로 안내해야 한다. 전체 재암호화(-r)는
# 조건 문장 한 곳에서만 설명하고, 공통 그룹을 모든 항목에 적용하라는 설명은 없어야 한다.
test_managing_secrets_host_add_workflow_checks_recipients_per_target() {
  local wf="$REPO_ROOT/.claude/skills/managing-secrets/references/workflows.md"
  local rules="$REPO_ROOT/secrets/secrets.nix"
  local section rows groups group row pub_line dec_line enc_line check_line
  section="$(awk '/^## 호스트 추가/ { on = 1; print; next } on && /^## / { exit } on' "$wf")"
  [[ -n "$section" ]] || fail "workflows.md에 '## 호스트 추가' 절이 없음"

  _secrets_docs_assert_rekey_all_conditional "workflows.md 호스트 추가 절" <<< "$section"
  grep -F -- '-r`' <<< "$section" | grep -qF '때만' \
    || fail "호스트 추가 절에 전체 재암호화(-r)를 쓸 수 있는 조건이 없음"

  rows="$(_secrets_docs_workflow_group_rows <<< "$section")"
  groups="$(_secrets_docs_declared_groups "$rules" | cut -f2 | LC_ALL=C sort -u)"
  [[ -n "$groups" ]] || fail "secrets.nix에서 recipient 그룹을 찾지 못함"
  while IFS= read -r group; do
    row="$(awk -F '\t' -v g="$group" '$1 == g { print $2 }' <<< "$rows")"
    [[ -n "$row" ]] || fail "호스트 추가 절의 그룹 표에 선언 그룹 $group 행이 없음"
    _secrets_docs_assert_group_row "$rules" "$group" "$row"
  done <<< "$groups"

  assert_contains "$section" "cd secrets"
  # 줄 번호 조회는 못 찾아도 빈 값으로 두고 아래 단정이 이유를 출력하게 한다(pipefail로 조용히 끝나지 않게).
  pub_line="$(grep -nF -m1 '`publicKeys` 확인' <<< "$section" | cut -d: -f1 || true)"
  dec_line="$(grep -nF -m1 -- '-d <name>.age -i <identity>' <<< "$section" | cut -d: -f1 || true)"
  enc_line="$(grep -nF -m1 -- '-e <name>.age -i <identity>' <<< "$section" | cut -d: -f1 || true)"
  check_line="$(grep -nF -- '-d <name>.age -i <identity> | wc -c' <<< "$section" | cut -d: -f1 | tail -1 || true)"
  [[ -n "$pub_line" && -n "$dec_line" && -n "$enc_line" && -n "$check_line" ]] \
    || fail "호스트 추가 절에 publicKeys 확인·복호화 확인·대상별 재암호화·빈 값 확인 중 빠진 단계가 있음 (pub=$pub_line dec=$dec_line enc=$enc_line check=$check_line)"
  [[ "$pub_line" -lt "$dec_line" && "$dec_line" -lt "$enc_line" && "$enc_line" -lt "$check_line" ]] \
    || fail "호스트 추가 절의 순서가 publicKeys 확인 → 복호화 확인 → 재암호화 → 빈 값 확인이 아님 (pub=$pub_line dec=$dec_line enc=$enc_line check=$check_line)"
  sed -n "${dec_line}p" <<< "$section" | grep -qF 'test -f <name>.age &&' \
    || fail "복호화 확인 명령 앞에 test -f <name>.age가 없음 — 파일 없는 항목이 복호화 가능으로 보인다"

  assert_contains "$section" 'sudo EDITOR=: nix run github:ryantm/agenix -- -e <name>.age -i /etc/ssh/ssh_host_ed25519_key'
  assert_not_contains "$section" 'EDITOR=: sudo'
  grep -F 'EDITOR=:' <<< "$section" | grep -qF '비워진다' \
    || fail "EDITOR=:가 전달되지 않으면 시크릿이 비워진다는 경고가 없음"
  _secrets_docs_assert_value_check_steps "workflows.md 호스트 추가 절" <<< "$section"

  assert_not_contains "$(cat "$wf")" '`allHosts`에 추가'
  assert_not_contains "$(cat "$wf")" '`allHosts` 목록에 있는 모든 공개키'
}
