# tests/suites/codex-config.sh — 도메인 테스트 정의 (sourced; aggregator가 lib/test-common.sh 후 source)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# shellcheck disable=SC2154,SC2164
# ─── codex-config fixture helpers ───
# sync-codex-config.py의 sync/check 계약을 fixture 기반으로 고정.
# tomlkit 의존이 필요하므로 profile runner 밖 직접 실행 시에는 import 가능 여부에 따라
# 조건부로 돌린다. required CI의 run-all-tests는 repo-pinned `prePushRuntime` profile로
# wrap하므로 항상 가용하다.
CODEX_CONFIG_SCRIPT="$REPO_ROOT/modules/shared/programs/codex/files/sync-codex-config.py"
CODEX_CONFIG_FIXTURE_DIR="$FIXTURE_DIR/codex-config"

# fixture 디렉터리의 선택적 `unset_keys` 파일(한 줄 = TOML dotted key)을 `--unset <key>`
# 인자 배열 CODEX_CONFIG_UNSET_ARGS 로 변환한다. 파일이 없으면 빈 배열이라 기존 시나리오는
# 호출 형태가 그대로다. 주석 제거/공백 제거 규칙은 배포 경로의 로더
# (modules/shared/scripts/lib/rebuild/codex-retired-keys.sh)와 같다.
codex_config_unset_args() {
  local dir="$1" line
  CODEX_CONFIG_UNSET_ARGS=()
  [[ -f "$dir/unset_keys" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    [[ -n "$line" ]] || continue
    CODEX_CONFIG_UNSET_ARGS+=(--unset "$line")
  done <"$dir/unset_keys"
}
json_semantic_equal() {
  # $1 = actual JSON string, $2 = expected JSON path, $3 = expected template path, $4 = expected target path.
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys, json
try:
    actual = json.loads(sys.argv[1])
except Exception as e:
    print(f"actual JSON parse error: {e}", file=sys.stderr)
    sys.exit(2)
try:
    with open(sys.argv[2]) as f:
        expected = json.load(f)
except Exception as e:
    print(f"expected JSON read error: {e}", file=sys.stderr)
    sys.exit(2)
actual_keys = set(actual)
required_keys = {"template", "target", "target_state", "drift"}
if actual_keys != required_keys:
    print(f"actual top-level keys mismatch: expected={sorted(required_keys)!r} actual={sorted(actual_keys)!r}", file=sys.stderr)
    sys.exit(1)
expected_keys = set(expected)
fixture_keys = {"target_state", "drift"}
if expected_keys != fixture_keys:
    print(f"expected fixture keys mismatch: expected={sorted(fixture_keys)!r} actual={sorted(expected_keys)!r}", file=sys.stderr)
    sys.exit(2)
if actual["template"] != sys.argv[3]:
    print(f"template path mismatch: expected={sys.argv[3]!r} actual={actual['template']!r}", file=sys.stderr)
    sys.exit(1)
if actual["target"] != sys.argv[4]:
    print(f"target path mismatch: expected={sys.argv[4]!r} actual={actual['target']!r}", file=sys.stderr)
    sys.exit(1)
for key in ("target_state", "drift"):
    if actual.get(key) != expected[key]:
        print(f"mismatch on '{key}': expected={expected[key]!r} actual={actual.get(key)!r}", file=sys.stderr)
        sys.exit(1)
sys.exit(0)
PY
}

test_codex_config_merge_template_into_unit() {
  # sync-codex-config.py merge_template_into 함수 단위 characterization (이슈 #915).
  # 기존 sync-preservation(시나리오 A-G)은 sync 명령 subprocess 통합 검증이고, 본
  # 테스트는 함수를 직접 호출해 "template leaf override + template 미선언 키 보존 +
  # 변경 leaf 카운트 + 동일 값 no-op(0)" 계약을 단위로 박제한다. tomlkit 필요(등록부 게이팅).
  local output
  output=$(
    python3 - "$CODEX_CONFIG_SCRIPT" <<'PY' 2>&1
import importlib.util, sys, tomlkit
spec = importlib.util.spec_from_file_location("sync_codex_config", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

dest = tomlkit.parse('a = 1\nkeep = "user"\n\n[nested]\nx = 1\nuseronly = 2\n')
tmpl = tomlkit.parse('a = 2\n\n[nested]\nx = 9\n')
changed = m.merge_template_into(dest, tmpl)
assert changed == 2, f"changed={changed}"
assert dest["a"] == 2, "template overrides top-level scalar"
assert dest["keep"] == "user", "template-undeclared key preserved"
assert dest["nested"]["x"] == 9, "template overrides nested leaf"
assert dest["nested"]["useronly"] == 2, "nested undeclared key preserved"
assert m.merge_template_into(tomlkit.parse('a = 2\n'), tomlkit.parse('a = 2\n')) == 0, "equal value is no-op"
print("MERGE_OK")
PY
  )
  assert_contains "$output" "MERGE_OK"
}

test_codex_config_collect_drift_unit() {
  # sync-codex-config.py collect_drift 함수 단위 characterization (이슈 #915).
  # template이 선언한 leaf가 target에 없으면 missing_leaf, 값이 다르면 value_mismatch
  # reason을 내는 계약을 단위로 박제한다.
  local output
  output=$(
    python3 - "$CODEX_CONFIG_SCRIPT" <<'PY' 2>&1
import importlib.util, sys, tomlkit
spec = importlib.util.spec_from_file_location("sync_codex_config", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

# tmpl이 선언한 b.c가 target에 없음 → missing_leaf
d = m.collect_drift(tomlkit.parse('a = 1\n[b]\nc = 2\n'), tomlkit.parse('a = 1\n'))
assert ("b.c", "missing_leaf") in {(x["path"], x["reason"]) for x in d}, d
# 값 불일치 → value_mismatch
d2 = m.collect_drift(tomlkit.parse('a = 1\n'), tomlkit.parse('a = 2\n'))
assert ("a", "value_mismatch") in {(x["path"], x["reason"]) for x in d2}, d2
print("DRIFT_OK")
PY
  )
  assert_contains "$output" "DRIFT_OK"
}

test_codex_config_repair_semantic_parse_is_lazy_unit() {
  # tomllib semantic fallback은 tomlkit이 hooks 루트 접근에 실패하는 rare path에서만
  # 사용한다. 정상 target에서는 activation/check마다 이중 parse를 하지 않는다.
  local output
  output=$(
    python3 - "$CODEX_CONFIG_SCRIPT" <<'PY' 2>&1
import importlib.util, sys, tomlkit
spec = importlib.util.spec_from_file_location("sync_codex_config", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

def fail_parse(_text):
    raise AssertionError("semantic fallback parser should not run on accessible hooks root")

m._parse_plain_toml_best_effort = fail_parse
doc = tomlkit.parse('[hooks.state."runtime"]\nenabled = true\n')
m.repair_out_of_order_hooks_root(doc, None, log_message="unused")
assert doc["hooks"]["state"]["runtime"]["enabled"] is True
print("LAZY_REPAIR_OK")
PY
  )
  assert_contains "$output" "LAZY_REPAIR_OK"
}

test_codex_config_sync_fixtures() {
  local scenario sandbox template existing expected actual rc
  for scenario in sync_basic_merge sync_malformed_root sync_malformed_toml_quarantine \
                  sync_quoted_dotted_key sync_out_of_order_hooks_duplicate \
                  sync_target_absent sync_hooks_scalar_template_event \
                  sync_unset_removes_key sync_unset_absent_noop \
                  sync_unset_aot_path_preserved sync_unset_table_path_preserved; do
    local dir="$CODEX_CONFIG_FIXTURE_DIR/$scenario"
    [[ -d "$dir" ]] || fail "sync fixture missing: $dir"
    sandbox=$(new_sandbox)
    template="$dir/template.toml"
    existing="$dir/existing.toml"
    expected="$dir/expected.toml"
    actual="$sandbox/target.toml"

    [[ -f "$existing" ]] && cp "$existing" "$actual"
    codex_config_unset_args "$dir"

    # sync subcommand 호출
    if ! python3 "$CODEX_CONFIG_SCRIPT" sync "$template" "$actual" \
      ${CODEX_CONFIG_UNSET_ARGS[@]+"${CODEX_CONFIG_UNSET_ARGS[@]}"} 2>/dev/null; then
      fail "sync($scenario) exited non-zero"
    fi
    [[ -f "$actual" ]] || fail "sync($scenario) did not produce target"
    if ! toml_semantic_equal "$actual" "$expected"; then
      echo "--- actual ($scenario) ---" >&2
      cat "$actual" >&2
      echo "--- expected ($scenario) ---" >&2
      cat "$expected" >&2
      fail "sync($scenario) result ≠ expected"
    fi
  done
}
# ─── no-op 3조건 검증 helpers ───
# no-op invariant (regular file / mode 0o600 / byte-identical) 의 authoritative 서술은
# modules/shared/programs/codex/files/sync-codex-config.py docstring 의 "No-op suppression"
# 블록과 `_noop_probe_target` docstring 에 있다. 세 시나리오 모두 동일 fixture
# `sync_noop_baseline/` 을 공유하고, 테스트 함수 본문의 FS 셋업(`chmod 0644`, `ln -s`)이
# 어느 invariant 를 깨는지를 구분한다.

# GNU coreutils `sha256sum` 이 없는 macOS 에서도 동일 결과를 내기 위해 `shasum -a 256` 으로
# fallback. 둘 다 없는 환경은 shell-script-tests 전제를 만족하지 못하므로 여기서 fail.
_codex_config_hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    fail "neither sha256sum nor shasum available for codex-config test hashing"
  fi
}

test_codex_config_sync_noop_preserves_bytes() {
  # existing ==(첫 sync 후)== target stable state 이고 mode 0600 이면 두 번째 sync 는
  # stderr empty + bytes unchanged 여야 한다.
  local dir="$CODEX_CONFIG_FIXTURE_DIR/sync_noop_baseline"
  local sandbox target first_hash second_hash second_stderr mode_after
  sandbox=$(new_sandbox)
  target="$sandbox/target.toml"

  cp "$dir/existing.toml" "$target"
  chmod 0600 "$target"

  # 1차 sync: tomlkit round-trip 정규화를 반영해 stable bytes 를 만든다. stderr 는 관찰 안 함.
  python3 "$CODEX_CONFIG_SCRIPT" sync "$dir/template.toml" "$target" >/dev/null 2>&1 \
    || fail "sync_noop_preserves_bytes: first sync exited non-zero"
  first_hash=$(_codex_config_hash "$target")

  # 2차 sync: 3조건 모두 성립 → no-op. stderr 비어 있어야 한다.
  second_stderr=$(python3 "$CODEX_CONFIG_SCRIPT" sync "$dir/template.toml" "$target" 2>&1 >/dev/null)
  [[ -z "$second_stderr" ]] \
    || fail "sync_noop_preserves_bytes: expected empty stderr on second sync, got: $second_stderr"

  second_hash=$(_codex_config_hash "$target")
  [[ "$first_hash" == "$second_hash" ]] \
    || fail "sync_noop_preserves_bytes: bytes changed between first and second sync"

  mode_after=$(_portable_file_mode "$target")
  [[ "$mode_after" == "600" ]] \
    || fail "sync_noop_preserves_bytes: mode=$mode_after (expected 600)"
}

test_codex_config_sync_rejects_bad_mode() {
  # 내용은 byte-identical 이지만 mode 가 0644 이면 no-op 이 아니라 write 가 발생해
  # mode 0600 으로 복구되어야 한다.
  local dir="$CODEX_CONFIG_FIXTURE_DIR/sync_noop_baseline"
  local sandbox target second_stderr mode_after
  sandbox=$(new_sandbox)
  target="$sandbox/target.toml"

  cp "$dir/existing.toml" "$target"
  chmod 0600 "$target"
  # 1차 sync: stable bytes 확보.
  python3 "$CODEX_CONFIG_SCRIPT" sync "$dir/template.toml" "$target" >/dev/null 2>&1 \
    || fail "sync_rejects_bad_mode: first sync exited non-zero"

  chmod 0644 "$target"   # mode drift 유발. bytes 는 그대로.

  second_stderr=$(python3 "$CODEX_CONFIG_SCRIPT" sync "$dir/template.toml" "$target" 2>&1 >/dev/null)
  [[ -n "$second_stderr" ]] \
    || fail "sync_rejects_bad_mode: expected summary log on write, stderr empty"

  mode_after=$(_portable_file_mode "$target")
  [[ "$mode_after" == "600" ]] \
    || fail "sync_rejects_bad_mode: mode=$mode_after after sync (expected 600)"
}

test_codex_config_sync_rejects_symlink() {
  # target 이 symlink 면 byte-identical 여부와 무관하게 write 가 발생해 regular file 로
  # 교체되어야 한다. 내부적으로 os.replace 가 symlink 를 regular file 로 치환한다.
  local dir="$CODEX_CONFIG_FIXTURE_DIR/sync_noop_baseline"
  local sandbox target backing second_stderr mode_after
  sandbox=$(new_sandbox)
  target="$sandbox/target.toml"
  backing="$sandbox/backing.toml"

  cp "$dir/existing.toml" "$backing"
  chmod 0600 "$backing"
  # 1차 sync: stable bytes 확보 (backing 대상). symlink 로 인한 write 동작 자체를 본 테스트
  # 에서 검증하므로 1차 sync 는 backing 에 직접 호출한다.
  python3 "$CODEX_CONFIG_SCRIPT" sync "$dir/template.toml" "$backing" >/dev/null 2>&1 \
    || fail "sync_rejects_symlink: backing first sync exited non-zero"

  ln -s "$backing" "$target"
  [[ -L "$target" ]] || fail "sync_rejects_symlink: symlink setup failed"

  second_stderr=$(python3 "$CODEX_CONFIG_SCRIPT" sync "$dir/template.toml" "$target" 2>&1 >/dev/null)
  [[ -n "$second_stderr" ]] \
    || fail "sync_rejects_symlink: expected summary log on write, stderr empty"

  [[ -L "$target" ]] && fail "sync_rejects_symlink: target is still a symlink after sync"
  [[ -f "$target" ]] || fail "sync_rejects_symlink: target is not a regular file after sync"
  mode_after=$(_portable_file_mode "$target")
  [[ "$mode_after" == "600" ]] \
    || fail "sync_rejects_symlink: mode=$mode_after after sync (expected 600)"
}

test_codex_config_bare_sync_compat() {
  # bare 2-arg 호출 결과가 explicit sync subcommand 호출과 동일해야 한다.
  local dir="$CODEX_CONFIG_FIXTURE_DIR/bare_sync_compat"
  local sandbox sub_result bare_result
  sandbox=$(new_sandbox)
  sub_result="$sandbox/via_sub.toml"
  bare_result="$sandbox/via_bare.toml"

  cp "$dir/existing.toml" "$sub_result"
  cp "$dir/existing.toml" "$bare_result"

  python3 "$CODEX_CONFIG_SCRIPT" sync "$dir/template.toml" "$sub_result" 2>/dev/null \
    || fail "bare_sync_compat: sync subcommand exited non-zero"
  python3 "$CODEX_CONFIG_SCRIPT" "$dir/template.toml" "$bare_result" 2>/dev/null \
    || fail "bare_sync_compat: bare 2-arg exited non-zero"

  toml_semantic_equal "$sub_result" "$bare_result" \
    || fail "bare_sync_compat: bare 2-arg result ≠ sync subcommand result"
  toml_semantic_equal "$sub_result" "$dir/expected.toml" \
    || fail "bare_sync_compat: sync result ≠ expected"
}

test_codex_config_check_fixtures() {
  local scenario dir sandbox template target_path actual_stdout actual_stderr rc expected_exit
  for scenario in check_match check_value_mismatch check_missing_leaf check_type_mismatch \
                  check_target_missing check_template_missing check_template_parse_error \
                  check_quoted_dotted_key_match check_quoted_dotted_key_value_mismatch \
                  check_empty_template check_out_of_order_hooks_duplicate \
                  check_target_malformed_toml check_unset_present_drift \
                  check_unset_template_conflict check_unset_container_not_leaf \
                  check_unset_projects_rejected; do
    dir="$CODEX_CONFIG_FIXTURE_DIR/$scenario"
    [[ -d "$dir" ]] || fail "check fixture missing: $dir"
    sandbox=$(new_sandbox)
    actual_stdout="$sandbox/stdout"
    actual_stderr="$sandbox/stderr"

    if [[ -f "$dir/template.toml" ]]; then
      template="$dir/template.toml"
    else
      template="$sandbox/nonexistent-template.toml"
    fi
    if [[ -f "$dir/target.toml" ]]; then
      target_path="$sandbox/target.toml"
      cp "$dir/target.toml" "$target_path"
    else
      target_path="$sandbox/nonexistent-target.toml"
    fi
    codex_config_unset_args "$dir"

    rc=0
    python3 "$CODEX_CONFIG_SCRIPT" check "$template" "$target_path" \
      ${CODEX_CONFIG_UNSET_ARGS[@]+"${CODEX_CONFIG_UNSET_ARGS[@]}"} \
      >"$actual_stdout" 2>"$actual_stderr" || rc=$?

    expected_exit="$(cat "$dir/expected_exit" | tr -d '[:space:]')"
    [[ "$rc" == "$expected_exit" ]] \
      || fail "check($scenario): expected exit $expected_exit, got $rc. stderr: $(cat "$actual_stderr")"

    if [[ -f "$dir/expected_drift.json" ]]; then
      # stdout의 JSON을 기대치와 semantic 비교
      local stdout_content
      stdout_content="$(cat "$actual_stdout")"
      [[ -n "$stdout_content" ]] || fail "check($scenario): stdout empty (expected JSON)"
      json_semantic_equal "$stdout_content" "$dir/expected_drift.json" "$template" "$target_path" \
        || fail "check($scenario): JSON mismatch"
    fi

    if [[ -f "$dir/expected_stderr_substring" ]]; then
      local needle
      needle="$(cat "$dir/expected_stderr_substring" | tr -d '\n')"
      assert_contains "$(cat "$actual_stderr")" "$needle"
      [[ ! -s "$actual_stdout" ]] || fail "check($scenario): expected empty stdout on EXIT_ERROR, got: $(cat "$actual_stdout")"
    fi
  done
}

test_codex_config_retired_keys_loader() {
  # 퇴역 키 목록 파일은 Nix(default.nix)와 셸(codex-retired-keys.sh) 두 파서가 같이 읽는다.
  # 파일 형식 계약(주석 제거 → 공백 제거 → 빈 줄 무시)이 셸 쪽에서 깨지면 activation 과
  # nrs/verify 의 회수 목록이 갈라지므로, 형식 계약과 저장소 실제 목록을 함께 박제한다.
  local sandbox repo_dir
  sandbox=$(new_sandbox)
  repo_dir="$sandbox/repo"
  mkdir -p "$repo_dir/modules/shared/programs/codex/files"

  # shellcheck source=../../modules/shared/scripts/lib/rebuild/codex-retired-keys.sh
  source "$REPO_ROOT/modules/shared/scripts/lib/rebuild/codex-retired-keys.sh"

  # (1) 목록 파일이 없으면 실패를 알리고 배열은 빈 상태여야 한다.
  CODEX_RETIRED_CONFIG_UNSET_ARGS=(sentinel)
  if codex_retired_config_unset_args "$repo_dir"; then
    fail "retired keys loader: expected non-zero return for missing list file"
  fi
  [[ "${#CODEX_RETIRED_CONFIG_UNSET_ARGS[@]}" -eq 0 ]] \
    || fail "retired keys loader: expected empty args on missing file, got: ${CODEX_RETIRED_CONFIG_UNSET_ARGS[*]}"

  # (2) 주석/빈 줄/공백/개행 없는 마지막 줄 처리.
  {
    printf '# comment line\n'
    printf '\n'
    printf '  features.dead_flag   # trailing comment\n'
    printf 'plugins."x@y".enabled'
  } >"$repo_dir/$CODEX_RETIRED_KEYS_REL_PATH"
  codex_retired_config_unset_args "$repo_dir" \
    || fail "retired keys loader: expected success on readable list file"
  local expected='--unset features.dead_flag --unset plugins."x@y".enabled'
  [[ "${CODEX_RETIRED_CONFIG_UNSET_ARGS[*]}" == "$expected" ]] \
    || fail "retired keys loader: args=[${CODEX_RETIRED_CONFIG_UNSET_ARGS[*]}] expected=[$expected]"

  # (3) 저장소 실제 목록: 모든 항목이 공백 없는 dotted key 형태여야 한다.
  #     목록이 비는 것은 정당한 최종 상태(모든 호스트에서 회수 완료)라 개수는 단언하지 않는다.
  codex_retired_config_unset_args "$REPO_ROOT" \
    || fail "retired keys loader: repo list file missing at $REPO_ROOT/$CODEX_RETIRED_KEYS_REL_PATH"
  local i=0 token
  for token in "${CODEX_RETIRED_CONFIG_UNSET_ARGS[@]}"; do
    if (( i % 2 == 0 )); then
      [[ "$token" == "--unset" ]] || fail "retired keys loader: expected --unset flag, got: $token"
    else
      [[ "$token" == *.* && "$token" != *' '* ]] \
        || fail "retired keys loader: repo entry is not a whitespace-free dotted key: $token"
    fi
    i=$((i + 1))
  done
}

test_codex_config_sync_rejects_bad_unset_before_touching_target() {
  # 인자 오류(`--unset` 이 template 선언과 충돌)는 target 을 건드리기 전에 실패해야 한다.
  # sync 는 malformed target 을 `.bad-<ts>` 로 rename(quarantine)한 뒤 template 으로 재생성하므로,
  # 가드가 그 뒤에 돌면 quarantine 만 일어나고 재생성 전에 die 해서 config 파일이 아예 사라진다.
  local sandbox template target rc stderr_file
  sandbox=$(new_sandbox)
  template="$sandbox/template.toml"
  target="$sandbox/config.toml"
  stderr_file="$sandbox/stderr"
  printf '[features]\nmulti_agent = true\n' >"$template"
  printf 'this is not = = valid toml\n' >"$target"

  rc=0
  python3 "$CODEX_CONFIG_SCRIPT" sync "$template" "$target" --unset features.multi_agent \
    >/dev/null 2>"$stderr_file" || rc=$?
  [[ "$rc" == "2" ]] || fail "sync bad --unset: expected exit 2, got $rc"
  assert_contains "$(cat "$stderr_file")" "template still declares this path"
  [[ -f "$target" ]] || fail "sync bad --unset: target was removed before the argument error"
  assert_contains "$(cat "$target")" "this is not"
  local quarantined
  quarantined=$(find "$sandbox" -maxdepth 1 -name 'config.toml.bad-*' | wc -l | tr -d '[:space:]')
  [[ "$quarantined" == "0" ]] \
    || fail "sync bad --unset: target was quarantined before the argument error"
}

test_codex_config_retired_keys_match_both_templates() {
  # 회수 목록은 두 플랫폼 template 공용 SoT다. 한쪽 template 만 보고 등록하면 그 호스트에서는
  # 테스트·verify·CI 가 모두 통과하고 반대편 호스트의 home-manager activation 만 EXIT_ERROR 로
  # 죽는다 (activation script 는 `set -eu`). 두 template 모두에 대해 check 를 돌려 인자 오류
  # (EXIT_ERROR)가 없음을 커밋 전에 확인한다.
  local sandbox target stderr_file tmpl rc template_dir
  template_dir="$REPO_ROOT/modules/shared/programs/codex/files"

  # shellcheck source=../../modules/shared/scripts/lib/rebuild/codex-retired-keys.sh
  source "$REPO_ROOT/modules/shared/scripts/lib/rebuild/codex-retired-keys.sh"
  codex_retired_config_unset_args "$REPO_ROOT" \
    || fail "retired keys cross-template: repo list file missing"
  # 목록이 비면 교차 검증할 대상이 없다 (정당한 최종 상태).
  [[ "${#CODEX_RETIRED_CONFIG_UNSET_ARGS[@]}" -gt 0 ]] || return 0

  sandbox=$(new_sandbox)
  target="$sandbox/config.toml"
  stderr_file="$sandbox/stderr"
  : >"$target"

  for tmpl in config.toml config.darwin.toml; do
    [[ -f "$template_dir/$tmpl" ]] || fail "retired keys cross-template: template missing: $tmpl"
    rc=0
    python3 "$CODEX_CONFIG_SCRIPT" check "$template_dir/$tmpl" "$target" \
      "${CODEX_RETIRED_CONFIG_UNSET_ARGS[@]}" >/dev/null 2>"$stderr_file" || rc=$?
    # rc 1(drift)은 빈 target 이라 정상. rc 2 만이 잘못된 등록 신호다.
    [[ "$rc" != "2" ]] \
      || fail "retired keys cross-template: $tmpl 이 회수 대상 키를 아직 선언한다: $(cat "$stderr_file")"
  done
}

test_codex_config_check_rejects_invalid_utf8_target() {
  local template sandbox target_path actual_stdout actual_stderr rc
  template="$CODEX_CONFIG_FIXTURE_DIR/check_match/template.toml"
  sandbox=$(new_sandbox)
  target_path="$sandbox/target.toml"
  actual_stdout="$sandbox/stdout"
  actual_stderr="$sandbox/stderr"

  printf '\377' >"$target_path"

  rc=0
  python3 "$CODEX_CONFIG_SCRIPT" check "$template" "$target_path" \
    >"$actual_stdout" 2>"$actual_stderr" || rc=$?

  [[ "$rc" == "2" ]] \
    || fail "check invalid UTF-8: expected exit 2, got $rc. stderr: $(cat "$actual_stderr")"
  assert_contains "$(cat "$actual_stderr")" "target not valid UTF-8"
  [[ ! -s "$actual_stdout" ]] \
    || fail "check invalid UTF-8: expected empty stdout, got: $(cat "$actual_stdout")"
}

test_codex_config_check_rejects_nonregular_target() {
  local template kind sandbox target_path actual_stdout actual_stderr rc
  template="$CODEX_CONFIG_FIXTURE_DIR/check_match/template.toml"
  for kind in directory fifo; do
    sandbox=$(new_sandbox)
    target_path="$sandbox/target.toml"
    actual_stdout="$sandbox/stdout"
    actual_stderr="$sandbox/stderr"

    if [[ "$kind" == "directory" ]]; then
      mkdir "$target_path"
    else
      command -v mkfifo >/dev/null 2>&1 || continue
      mkfifo "$target_path"
    fi

    rc=0
    python3 "$CODEX_CONFIG_SCRIPT" check "$template" "$target_path" \
      >"$actual_stdout" 2>"$actual_stderr" || rc=$?

    [[ "$rc" == "2" ]] \
      || fail "check non-regular $kind: expected exit 2, got $rc. stderr: $(cat "$actual_stderr")"
    assert_contains "$(cat "$actual_stderr")" "target is not a regular file"
    [[ ! -s "$actual_stdout" ]] \
      || fail "check non-regular $kind: expected empty stdout, got: $(cat "$actual_stdout")"
  done
}
